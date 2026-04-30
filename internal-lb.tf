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

# Lab-specific: probe TCP:22 (sshd) instead of TCP:443. The NVAs DNAT 443 to the
# webserver, so a 443 probe ends up depending on the webserver being healthy AND
# on a symmetric reply path (which doesn't exist in this topology — the
# webserver's reply to 168.63.129.16 goes via the UDR through the DMZ LB to
# potentially a different NVA, and nothing reverse-NATs it). Probing 22 lets the
# NVA itself answer the probe via sshd, breaking the chicken-and-egg at boot.
# Production Palo Altos answer 443 directly via PAN-OS, so this isn't an issue
# for them.
resource "azurerm_lb_probe" "internal" {
  name                = "probe-back-lb"
  loadbalancer_id     = azurerm_lb.internal.id
  protocol            = "Tcp"
  port                = 22
  interval_in_seconds = 10
  number_of_probes    = 1

  lifecycle {
    create_before_destroy = true
  }
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
#
# Lab-specific: floating_ip_enabled = true (production uses false). With false,
# the LB rewrites destination to backend NVA eth2 IP, packet hits the NVA's
# INPUT chain as local-destined and gets RST'd (kernel default for unbound port).
# Palo Alto firewalls in production handle this via session-table forwarding
# regardless of destination IP — Linux netfilter does not. With floating IP on,
# the destination (original client IP) is preserved, conntrack matches the
# original DNAT'd flow, and reverse-NAT works through the FORWARD chain.
# The asymmetric routing bug still reproduces: SourceIP hash on src=webserver_IP
# can land on a different NVA than the one that owns the conntrack entry.
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
  floating_ip_enabled            = true
}
