# ---------------------------------------------------------------------------
# DMZ subnet UDR: 0.0.0.0/0 → Azure Firewall private IP.
#
# Webserver-initiated egress hits the firewall directly — it does NOT traverse
# the NVA on the way out. The NVA only sees inbound App-GW-derived traffic
# (DNAT'd to webserver) and the symmetric return.
#
# Intra-VNet traffic uses the more-specific VnetLocal system route, so the
# inbound return path (webserver → NVA dmz IP) is unaffected by this UDR.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "dmz" {
  name                = "rt-${var.name_prefix}-dmz"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.main.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "dmz" {
  subnet_id      = azurerm_subnet.dmz.id
  route_table_id = azurerm_route_table.dmz.id
}
