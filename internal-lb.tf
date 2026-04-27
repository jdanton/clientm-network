# ---------------------------------------------------------------------------
# Internal (Back) Load Balancer - Standard SKU, private.
#
# >>> This LB is the linchpin of the asymmetric routing issue <<<
#
# - DMZ subnet's default route points here.
# - Webserver replies hit this LB, which 5-tuple-hashes to one of the NVAs.
# - That NVA may not be the one that owns the conntrack flow -> drop.
#
# To FIX (uncomment the HA Ports block below):
#   - HA Ports rule + floating IP + matching Standard LB on inbound side
#   - Or use Gateway Load Balancer (separate construct)
# ---------------------------------------------------------------------------

resource "azurerm_lb" "internal" {
  name                = "lb-${var.name_prefix}-back"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "frontend-internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address            = var.internal_lb_frontend_ip
    private_ip_address_allocation = "Static"
    zones                         = ["1"]
  }
}

resource "azurerm_lb_backend_address_pool" "internal" {
  name            = "bepool-nvas-int"
  loadbalancer_id = azurerm_lb.internal.id
}

resource "azurerm_network_interface_backend_address_pool_association" "internal" {
  for_each                = azurerm_network_interface.nva_internal
  network_interface_id    = each.value.id
  ip_configuration_name   = "ipconfig-int"
  backend_address_pool_id = azurerm_lb_backend_address_pool.internal.id
}

resource "azurerm_lb_probe" "internal" {
  name            = "probe-tcp-22"
  loadbalancer_id = azurerm_lb.internal.id
  protocol        = "Tcp"
  port            = 22
}

# ---------------------------------------------------------------------------
# BROKEN-BY-DESIGN rule (default): per-port LB, no floating IP.
# Reproduces asymmetric routing because return traffic doesn't lock to a
# particular NVA based on the original flow.
# ---------------------------------------------------------------------------
resource "azurerm_lb_rule" "internal_443" {
  name                           = "rule-tcp-443-broken"
  loadbalancer_id                = azurerm_lb.internal.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "frontend-internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal.id]
  probe_id                       = azurerm_lb_probe.internal.id
  floating_ip_enabled            = false
  idle_timeout_in_minutes        = 4
}

# ---------------------------------------------------------------------------
# >>> THE FIX <<< - uncomment this and comment out the rule above to test
# HA Ports rule with floating IP. Forwards ALL ports/protocols and preserves
# the original destination IP so the NVAs can do flow-symmetric NAT.
# ---------------------------------------------------------------------------
# resource "azurerm_lb_rule" "internal_haports" {
#   name                           = "rule-haports-fixed"
#   loadbalancer_id                = azurerm_lb.internal.id
#   protocol                       = "All"
#   frontend_port                  = 0   # 0 = HA Ports (all ports)
#   backend_port                   = 0
#   frontend_ip_configuration_name = "frontend-internal"
#   backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal.id]
#   probe_id                       = azurerm_lb_probe.internal.id
#   enable_floating_ip             = true
#   idle_timeout_in_minutes        = 4
# }
