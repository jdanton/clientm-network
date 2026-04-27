# ---------------------------------------------------------------------------
# External (Front) Load Balancer - Standard SKU, public.
# Distributes inbound 443 across both NVAs (active/active simulation).
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "external_lb" {
  name                = "pip-${var.name_prefix}-front-lb"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1"]
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
  name            = "bepool-nvas-ext"
  loadbalancer_id = azurerm_lb.external.id
}

# Attach NVA external NICs to the backend pool
resource "azurerm_network_interface_backend_address_pool_association" "external" {
  for_each                = azurerm_network_interface.nva_external
  network_interface_id    = each.value.id
  ip_configuration_name   = "ipconfig-ext"
  backend_address_pool_id = azurerm_lb_backend_address_pool.external.id
}

# Health probe: TCP 22 (any port the NVAs respond on works for a routing lab).
# In prod you'd point this at a real health endpoint on the firewall.
resource "azurerm_lb_probe" "external" {
  name            = "probe-tcp-22"
  loadbalancer_id = azurerm_lb.external.id
  protocol        = "Tcp"
  port            = 22
}

# 443 inbound rule.
# disable_outbound_snat = true because the NVAs have their own public IPs for
# egress (cheaper/simpler than configuring an explicit outbound rule on Standard LB).
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
  floating_ip_enabled            = false
  idle_timeout_in_minutes        = 4
}
