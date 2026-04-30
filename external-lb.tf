# ---------------------------------------------------------------------------
# Front (External) Load Balancer — Standard SKU, public.
# Mirrors production lb-frontend-edge-prod-eastus-001.
#
# Distributes inbound VPN/HTTPS traffic across both NVAs (active/active).
# Floating IP preserves the original destination so NVAs can apply policy.
# SourceIP distribution keeps a given client pinned to one NVA.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "external_lb" {
  name                = "pip-${var.name_prefix}-front-lb"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["2"]
  tags                = var.tags
}

resource "azurerm_lb" "external" {
  name                = "lb-${var.name_prefix}-front"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "frontend-public"
    public_ip_address_id = azurerm_public_ip.external_lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "external" {
  name            = "pool-nvas-ext"
  loadbalancer_id = azurerm_lb.external.id
}

resource "azurerm_network_interface_backend_address_pool_association" "external" {
  for_each                = azurerm_network_interface.nva_external
  network_interface_id    = each.value.id
  ip_configuration_name   = "ipconfig-ext"
  backend_address_pool_id = azurerm_lb_backend_address_pool.external.id
}

# Health probe on TCP:443 — matches production probe-lb-frontend-edge-prod-eastus-001
resource "azurerm_lb_probe" "external" {
  name                = "probe-tcp-443"
  loadbalancer_id     = azurerm_lb.external.id
  protocol            = "Tcp"
  port                = 443
  interval_in_seconds = 15
  number_of_probes    = 1
}

# HTTPS inbound rule.
# Floating IP enabled + SourceIP distribution matches production:
#   enableFloatingIP: true, loadDistribution: SourceIP, disableOutboundSnat: true
resource "azurerm_lb_rule" "external_443" {
  name                           = "rule-https-443"
  loadbalancer_id                = azurerm_lb.external.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "frontend-public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.external.id]
  probe_id                       = azurerm_lb_probe.external.id
  disable_outbound_snat          = true
  floating_ip_enabled            = true
  load_distribution              = "SourceIP"
  idle_timeout_in_minutes        = 4
}
