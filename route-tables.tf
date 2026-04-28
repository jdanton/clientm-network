# ---------------------------------------------------------------------------
# User-defined routes (UDRs)
#
# DMZ subnet: webserver's default route → back LB DMZ frontend (10.0.3.10).
#   The DMZ LB hashes return traffic (SourceIP) to a NVA DMZ NIC (eth2).
#   That NVA may not own the conntrack flow for the inbound direction → DROP.
#   This is the asymmetric routing bug.
#
# AppGW subnet: route for the firewall VNet CIDR → back LB internal frontend
#   (10.0.4.4). Forces App GW → webserver through NVA eth1 path.
#
# Internal subnet: empty route table (BGP propagation enabled, no overrides).
# ---------------------------------------------------------------------------

# DMZ default route → back LB DMZ frontend (webserver return path through NVAs)
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

# AppGW subnet route → back LB internal frontend (forces App GW → webserver via NVA eth1)
# This route is in VNet 2 (appgw VNet) but the next hop (10.0.4.4) is reachable
# via VNet peering with allow_forwarded_traffic = true.
resource "azurerm_route_table" "appgw" {
  name                = "rt-appgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  route {
    name                   = "fw-vnet-via-internal-lb"
    address_prefix         = var.vnet_address_space[0]
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.internal_lb_frontend_ip
  }
}

resource "azurerm_subnet_route_table_association" "appgw" {
  subnet_id      = azurerm_subnet.appgw.id
  route_table_id = azurerm_route_table.appgw.id
}

# Internal subnet: empty table, BGP propagation on (no forced routing overrides needed)
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
