# ---------------------------------------------------------------------------
# Back (Internal) Load Balancer — Standard SKU, private, zone-redundant.
#
# Mirrors production lb-backend-edge-prod-eastus-001:
#
#   Frontend 1 (vip-internal, 10.0.4.4 in snet-internal):
#     App GW → webserver inbound path via NVA internal NICs (eth1)
#
#   Frontend 2 (vip-dmz, 10.0.3.10 in snet-dmz):
#     Webserver return path via NVA DMZ NICs (eth2)
#
# Both rules: HA Ports (All/0), no floating IP, SourceIP distribution.
#
# >>> This is where the asymmetric routing bug lives <<<
#
# SourceIP hashes on source IP only. Inbound (src = App GW IP) hashes to
# NVA-A. Return (src = webserver IP) hashes to NVA-B. NVA-B has no conntrack
# entry for the flow → nf_conntrack_tcp_loose=0 marks it INVALID → DROP.
# ---------------------------------------------------------------------------

resource "azurerm_lb" "internal" {
  name                = "lb-${var.name_prefix}-back"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "vip-internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address            = var.internal_lb_frontend_ip
    private_ip_address_allocation = "Static"
    zones                         = ["1", "2", "3"]
  }

  frontend_ip_configuration {
    name                          = "vip-dmz"
    subnet_id                     = azurerm_subnet.dmz.id
    private_ip_address            = var.dmz_lb_frontend_ip
    private_ip_address_allocation = "Static"
    zones                         = ["1", "2", "3"]
  }
}

# Backend pool: NVA internal NICs (eth1)
resource "azurerm_lb_backend_address_pool" "internal" {
  name            = "pool-nvas-internal"
  loadbalancer_id = azurerm_lb.internal.id
}

# Backend pool: NVA DMZ NICs (eth2)
resource "azurerm_lb_backend_address_pool" "internal_dmz" {
  name            = "pool-nvas-dmz"
  loadbalancer_id = azurerm_lb.internal.id
}

resource "azurerm_network_interface_backend_address_pool_association" "internal" {
  for_each                = azurerm_network_interface.nva_internal
  network_interface_id    = each.value.id
  ip_configuration_name   = "ipconfig-int"
  backend_address_pool_id = azurerm_lb_backend_address_pool.internal.id
}

resource "azurerm_network_interface_backend_address_pool_association" "internal_dmz" {
  for_each                = azurerm_network_interface.nva_dmz
  network_interface_id    = each.value.id
  ip_configuration_name   = "ipconfig-dmz"
  backend_address_pool_id = azurerm_lb_backend_address_pool.internal_dmz.id
}

resource "azurerm_lb_probe" "internal" {
  name                = "probe-tcp-443"
  loadbalancer_id     = azurerm_lb.internal.id
  protocol            = "Tcp"
  port                = 443
  interval_in_seconds = 10
  number_of_probes    = 1
}

# HA Ports rule — internal frontend (App GW → webserver inbound via NVA eth1)
resource "azurerm_lb_rule" "internal_haports" {
  name                           = "rule-haports-internal"
  loadbalancer_id                = azurerm_lb.internal.id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "vip-internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal.id]
  probe_id                       = azurerm_lb_probe.internal.id
  load_distribution              = "SourceIP"
  idle_timeout_in_minutes        = 4
  disable_outbound_snat          = true
}

# HA Ports rule — DMZ frontend (webserver return via NVA eth2)
resource "azurerm_lb_rule" "internal_dmz_haports" {
  name                           = "rule-haports-dmz"
  loadbalancer_id                = azurerm_lb.internal.id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "vip-dmz"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal_dmz.id]
  probe_id                       = azurerm_lb_probe.internal.id
  load_distribution              = "SourceIP"
  idle_timeout_in_minutes        = 4
  disable_outbound_snat          = true
}
