# ---------------------------------------------------------------------------
# DMZ subnet UDR: 0.0.0.0/0 → NVA dmz NIC private IP.
#
# Forces the webserver's Internet-bound traffic through the NVA's iptables
# (where the egress L4 allow-list lives). Intra-VNet traffic stays on the
# VnetLocal system route (more specific), so inbound return paths from
# webserver back to the NVA are unaffected by this UDR.
#
# We intentionally do NOT add a UDR on the App Gateway subnet. App GW
# connects to its backend pool (the NVA trust IP) by ordinary VNet routing;
# routing App GW's backend traffic through a UDR-to-NVA is the path that
# bit design-3 with first-boot races and is unnecessary here since the
# backend already IS the NVA.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "dmz" {
  name                = "rt-${var.name_prefix}-dmz"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  route {
    name                   = "default-to-nva-dmz"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.nva_dmz_ip
  }
}

resource "azurerm_subnet_route_table_association" "dmz" {
  subnet_id      = azurerm_subnet.dmz.id
  route_table_id = azurerm_route_table.dmz.id
}
