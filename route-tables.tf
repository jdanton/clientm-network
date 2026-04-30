# ---------------------------------------------------------------------------
# User-defined routes (UDRs)
#
# DMZ subnet: webserver's default route → back LB DMZ frontend (10.0.3.10).
#   This is what creates the asymmetric routing condition: when the webserver
#   replies to App GW (its backend caller), the reply gets sent to the DMZ LB,
#   which hashes (SourceIP on webserver IP) to a NVA eth2 backend. That NVA
#   has no conntrack entry for the App-GW→webserver flow because App GW
#   reaches the webserver DIRECTLY via VNet peering (no NVA on the way in)
#   → INVALID → DROP. App GW backend health probe fails. Front LB then
#   marks its NVA backends unhealthy because their probe (DNAT'd to App GW)
#   also fails.
#
# AppGW subnet: NO UDR for the firewall VNet. App GW reaches the webserver
#   directly via VNet peering. This is exactly what makes the routing
#   asymmetric — the inbound App-GW-to-webserver leg bypasses the NVAs while
#   the return leg goes through them.
#
# Internal subnet: empty route table (BGP propagation enabled, no overrides).
# ---------------------------------------------------------------------------

# DMZ default route → back LB DMZ frontend (asymmetric return path)
resource "azurerm_route_table" "dmz" {
  name                = "rt-dmz"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  route {
    name                   = "default-via-dmz-lb"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.dmz_lb_frontend_ip
  }
}

resource "azurerm_subnet_route_table_association" "dmz" {
  subnet_id      = azurerm_subnet.dmz.id
  route_table_id = azurerm_route_table.dmz.id
}

# Internal subnet: empty table, BGP propagation on
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
