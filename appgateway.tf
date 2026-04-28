# ---------------------------------------------------------------------------
# Application Gateway (WAF_v2)
#
# Mirrors the prod JSON (appgw-kiteworks-waf-prod-eastus-001):
#   - WAF_v2 SKU, autoscale 0-10
#   - Both public and private frontend IPs
#   - Listener bound to PRIVATE IP 10.28.255.150, HTTPS:443
#   - Backend pool = webserver IP 10.29.254.250
#   - HTTPS health probe to /healthz on host connect.clientmworkspace.com
#   - Cert validation on backend (validateCertChainAndExpiry: true)
#
# COST WARNING: WAF_v2 has a fixed gateway charge (~$0.443/hr ≈ $323/mo)
# regardless of min capacity. Destroy when not actively testing.
# ---------------------------------------------------------------------------

# ----- Self-signed cert for the AppGW listener (frontend HTTPS) -----
resource "tls_private_key" "listener" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "listener" {
  private_key_pem = tls_private_key.listener.private_key_pem

  subject {
    common_name  = "connect.clientmworkspace.com"
    organization = "Clientm Lab"
  }

  validity_period_hours = 8760 # 1 year
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = ["connect.clientmworkspace.com"]
}

resource "random_password" "pfx" {
  length  = 24
  special = false
}

# AppGW listener requires PFX format, not PEM
resource "pkcs12_from_pem" "listener" {
  cert_pem        = tls_self_signed_cert.listener.cert_pem
  private_key_pem = tls_private_key.listener.private_key_pem
  password        = random_password.pfx.result
}

# Public IP for AppGW (Standard SKU required for v2). Zone-redundant to match AppGW.
resource "azurerm_public_ip" "appgw" {
  name                = "pip-${var.name_prefix}-appgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

# WAF policy (lab: detection mode = cheaper to debug, no false positives blocking)
resource "azurerm_web_application_firewall_policy" "appgw" {
  name                = "waf-pol-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = "Detection" # Switch to Prevention to mirror prod
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

resource "azurerm_application_gateway" "main" {
  name                = "appgw-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  zones               = ["1", "2", "3"]
  tags                = var.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = var.appgw_min_capacity
    max_capacity = var.appgw_max_capacity
  }

  firewall_policy_id = azurerm_web_application_firewall_policy.appgw.id

  # Required gateway IP config — subnet is in the App GW VNet (vnet-appgw-*)
  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.appgw.id
  }

  # Both public and private frontend IPs - matches the prod JSON shape
  frontend_ip_configuration {
    name                 = "appGwPublicFrontendIpIPv4"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_ip_configuration {
    name                          = "appgw-private-ip"
    subnet_id                     = azurerm_subnet.appgw.id
    private_ip_address            = var.appgw_private_ip
    private_ip_address_allocation = "Static"
  }

  frontend_port {
    name = "port_443"
    port = 443
  }

  ssl_certificate {
    name     = "connectclientmworkspace2026"
    data     = pkcs12_from_pem.listener.result
    password = random_password.pfx.result
  }

  # HTTPS listener bound to PRIVATE frontend IP (per prod config)
  http_listener {
    name                           = "listener-appgw-https-prod"
    frontend_ip_configuration_name = "appgw-private-ip"
    frontend_port_name             = "port_443"
    protocol                       = "Https"
    ssl_certificate_name           = "connectclientmworkspace2026"
    require_sni                    = false
  }

  backend_address_pool {
    name         = "bepool-webserver"
    ip_addresses = [var.webserver_ip]
  }

  # Trusted root cert for backend HTTPS (matches the self-signed on webserver)
  # In a real environment you'd upload the actual backend cert chain.
  # For lab simplicity we point AppGW at the webserver over HTTP to avoid the
  # cert-chain dance. Toggle protocol below if you want to test HTTPS->HTTPS.
  backend_http_settings {
    name                                = "settings-webserver"
    cookie_based_affinity               = "Disabled"
    port                                = 80
    protocol                            = "Http"
    request_timeout                     = 20
    pick_host_name_from_backend_address = false
    host_name                           = "connect.clientmworkspace.com"
    probe_name                          = "probe-healthz"
  }

  # Probe matches the prod JSON: /healthz on connect.clientmworkspace.com
  probe {
    name                                      = "probe-healthz"
    protocol                                  = "Http" # Match backend_http_settings protocol
    host                                      = "connect.clientmworkspace.com"
    path                                      = "/healthz"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = false

    match {
      status_code = ["200-299"]
    }
  }

  request_routing_rule {
    name                       = "rule-https-to-webserver"
    priority                   = 1
    rule_type                  = "Basic"
    http_listener_name         = "listener-appgw-https-prod"
    backend_address_pool_name  = "bepool-webserver"
    backend_http_settings_name = "settings-webserver"
  }

  # Don't fight with the user-defined route on the AppGW subnet during apply
  depends_on = [
    azurerm_subnet_route_table_association.appgw,
  ]
}
