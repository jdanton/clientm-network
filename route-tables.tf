# ---------------------------------------------------------------------------
# User-defined routes (UDRs)
#
# This is the heart of the asymmetric routing reproduction.
#
# DMZ subnet: webserver's default route points at the INTERNAL LB.
# The internal LB (5-tuple hash, no HA Ports / floating IP) load-balances return
# traffic to one of the two NVAs - which is NOT necessarily the same NVA that
# handled the inbound SYN. The "wrong" NVA has no conntrack state -> drops.
#
# Toggle the LB rule in internal-lb.tf (broken-by-default vs HA Ports fix) to test.
# ---------------------------------------------------------------------------

# DMZ default route -> internal LB (forces webserver replies through the firewall path)
resource "azurerm_route_table" "dmz" {
  name                = "rt-dmz"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  route {
    name                   = "default-via-internal-lb"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.internal_lb_frontend_ip
  }
}

resource "azurerm_subnet_route_table_association" "dmz" {
  subnet_id      = azurerm_subnet.dmz.id
  route_table_id = azurerm_route_table.dmz.id
}

# AppGw subnet: traffic to the DMZ webserver should also go via the firewalls
# (so AppGW -> firewall -> webserver, not AppGW -> webserver direct).
# This matches the "NAT behind Active/Active behind the firewall" requirement.
resource "azurerm_route_table" "appgw" {
  name                = "rt-appgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  # Only override the DMZ route so we don't break AppGW's required Internet egress
  # for control plane (AppGW v2 needs outbound internet to AzureGatewayManager etc.)
  route {
    name                   = "dmz-via-internal-lb"
    address_prefix         = var.subnet_dmz_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.internal_lb_frontend_ip
  }
}

resource "azurerm_subnet_route_table_association" "appgw" {
  subnet_id      = azurerm_subnet.appgw.id
  route_table_id = azurerm_route_table.appgw.id
}

# Internal subnet (where NVA "trust" NICs live): explicit route for the AppGW
# subnet pointing back at the internal LB so return traffic stays symmetric on
# the firewall side. (Useful once you start playing with the fixes.)
resource "azurerm_route_table" "internal" {
  name                          = "rt-internal"
  location                      = azurerm_resource_group.lab.location
  resource_group_name           = azurerm_resource_group.lab.name
  bgp_route_propagation_enabled = true
  tags                          = var.tags
}

resource "azurerm_subnet_route_table_association" "internal" {
  subnet_id      = azurerm_subnet.internal.id
  route_table_id = azurerm_route_table.internal.id
}
