# ---------------------------------------------------------------------------
# Internal Load Balancer (Standard SKU, private)
#
# Sits between App Gateway and the NVA pool. App GW's backend pool member
# is this LB's frontend IP (10.0.2.4). The LB rewrites dst to the chosen
# NVA's trust NIC IP (floating_ip=false), and on return traffic rewrites
# the NVA's source IP back to the LB IP — so App GW sees replies from the
# LB IP it originally connected to.
#
# Probe: TCP:22 (sshd is always up; using :443 here would fight with the
# DNAT chain on the NVA, since :443 traffic gets DNAT'd to the webserver
# and the probe response wouldn't have the right source IP).
# ---------------------------------------------------------------------------

resource "azurerm_lb" "internal" {
  name                = "lb-${var.name_prefix}-internal"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "vip-internal"
    subnet_id                     = azurerm_subnet.trust.id
    private_ip_address            = var.internal_lb_frontend_ip
    private_ip_address_allocation = "Static"
    zones                         = ["1", "2", "3"]
  }
}

resource "azurerm_lb_backend_address_pool" "nvas" {
  name            = "pool-nvas"
  loadbalancer_id = azurerm_lb.internal.id
}

resource "azurerm_network_interface_backend_address_pool_association" "nvas" {
  for_each                = azurerm_network_interface.nva_trust
  network_interface_id    = each.value.id
  ip_configuration_name   = "ipconfig-trust"
  backend_address_pool_id = azurerm_lb_backend_address_pool.nvas.id
}

resource "azurerm_lb_probe" "tcp22" {
  name                = "probe-tcp-22"
  loadbalancer_id     = azurerm_lb.internal.id
  protocol            = "Tcp"
  port                = 22
  interval_in_seconds = 10
  number_of_probes    = 1
}

resource "azurerm_lb_rule" "https" {
  name                           = "rule-https-443"
  loadbalancer_id                = azurerm_lb.internal.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "vip-internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nvas.id]
  probe_id                       = azurerm_lb_probe.tcp22.id
  load_distribution              = "SourceIP"
  idle_timeout_in_minutes        = 4
}

resource "azurerm_lb_rule" "http" {
  name                           = "rule-http-80"
  loadbalancer_id                = azurerm_lb.internal.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "vip-internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nvas.id]
  probe_id                       = azurerm_lb_probe.tcp22.id
  load_distribution              = "SourceIP"
  idle_timeout_in_minutes        = 4
}
