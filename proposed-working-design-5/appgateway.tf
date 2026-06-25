# ---------------------------------------------------------------------------
# Application Gateway (WAF_v2) — public edge, same role as design-1/2/3.
#
# Backend pool = NVA TRUST NIC IP (not the webserver, not a load balancer).
# App GW connects to the NVA directly; the NVA's iptables PREROUTING DNATs
# :80 to the webserver. No UDR on the App GW subnet — App GW just sees a
# normal backend address, which sidesteps the App-Gateway-UDR-to-virtual-
# appliance routing fragility design-3 had to be careful about.
# ---------------------------------------------------------------------------

resource "tls_private_key" "listener" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "listener" {
  private_key_pem       = tls_private_key.listener.private_key_pem
  validity_period_hours = 8760
  early_renewal_hours   = 720

  subject {
    common_name  = "connect.clientmworkspace.com"
    organization = "Clientm Lab"
  }

  dns_names    = ["connect.clientmworkspace.com"]
  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "random_password" "pfx" {
  length  = 24
  special = false
}

resource "pkcs12_from_pem" "listener" {
  cert_pem        = tls_self_signed_cert.listener.cert_pem
  private_key_pem = tls_private_key.listener.private_key_pem
  password        = random_password.pfx.result
}

resource "azurerm_public_ip" "appgw" {
  name                = "pip-${var.name_prefix}-appgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_web_application_firewall_policy" "appgw" {
  name                = "waf-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = "Detection"
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

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.appgw.id
  }

  # Dual frontend: public (original client edge) AND a private IP in
  # snet-appgateway. WAF_v2 supports both at once with no feature flag.
  # The private listener is reachable only from inside the VNet (the test
  # client in snet-test) — this is the private-IP variant under test.
  # (Private-ONLY on WAF_v2 needs the EnableApplicationGatewayNetworkIsolation
  # subscription feature, which is not registered here.)
  frontend_ip_configuration {
    name                 = "frontend-public"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_ip_configuration {
    name                          = "frontend-private"
    subnet_id                     = azurerm_subnet.appgw.id
    private_ip_address            = var.appgw_private_ip
    private_ip_address_allocation = "Static"
  }

  frontend_port {
    name = "port_443"
    port = 443
  }

  ssl_certificate {
    name     = "connectmilbankworkspace"
    data     = pkcs12_from_pem.listener.result
    password = random_password.pfx.result
  }

  http_listener {
    name                           = "listener-https-public"
    frontend_ip_configuration_name = "frontend-public"
    frontend_port_name             = "port_443"
    protocol                       = "Https"
    ssl_certificate_name           = "connectmilbankworkspace"
    require_sni                    = false
  }

  http_listener {
    name                           = "listener-https-private"
    frontend_ip_configuration_name = "frontend-private"
    frontend_port_name             = "port_443"
    protocol                       = "Https"
    ssl_certificate_name           = "connectmilbankworkspace"
    require_sni                    = false
  }

  # Backend pool = NVA trust NIC. NVA DNATs :80 → webserver:80. Probe :80
  # rides the same path so /healthz proves the entire trust → DNAT → dmz →
  # webserver chain end-to-end.
  backend_address_pool {
    name         = "bepool-nva-trust"
    ip_addresses = [var.nva_trust_ip]
  }

  backend_http_settings {
    name                                = "settings-nva-trust"
    cookie_based_affinity               = "Disabled"
    port                                = 80
    protocol                            = "Http"
    request_timeout                     = 20
    pick_host_name_from_backend_address = false
    host_name                           = "connect.clientmworkspace.com"
    probe_name                          = "probe-healthz"
  }

  probe {
    name                                      = "probe-healthz"
    protocol                                  = "Http"
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
    name                       = "rule-https-to-nva-trust"
    priority                   = 1
    rule_type                  = "Basic"
    http_listener_name         = "listener-https-public"
    backend_address_pool_name  = "bepool-nva-trust"
    backend_http_settings_name = "settings-nva-trust"
  }

  request_routing_rule {
    name                       = "rule-https-private-to-nva-trust"
    priority                   = 2
    rule_type                  = "Basic"
    http_listener_name         = "listener-https-private"
    backend_address_pool_name  = "bepool-nva-trust"
    backend_http_settings_name = "settings-nva-trust"
  }
}
