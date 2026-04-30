# ---------------------------------------------------------------------------
# User-defined routes (UDRs) — Option B applied
#
# AppGW subnet: 10.0.0.0/16 → back LB internal frontend (10.0.4.4).
#   Forces App-GW → webserver inbound through the NVAs (eth1 path), creating
#   conntrack on the inbound NVA so the webserver's reply (which still goes
#   via the DMZ LB) can match an existing flow IF the SourceIP hashes pick
#   the same NVA on both legs. With only 2 NVAs, that's a coin-flip per
#   distinct (AppGW_IP, webserver_IP) pair — fine for a deterministic test
#   client; not a guaranteed fix.
#
# DMZ subnet: webserver's default route → back LB DMZ frontend (10.0.3.10).
#   Webserver replies to App GW go to NVA eth2 via SourceIP hash on
#   src=10.0.3.100. If that NVA matches the inbound NVA, ESTABLISHED hit and
#   reverse-NAT works. If not, INVALID → DROP (the residual bug Option B
#   doesn't solve on its own — would need eth2 SNAT to webserver, GWLB, or
#   floating IP to fully eliminate).
#
# Internal subnet: empty route table (BGP propagation on).
# ---------------------------------------------------------------------------

# AppGW subnet UDR → forces App-GW→webserver through NVAs (Option B)
resource "azurerm_route_table" "appgw" {
  name                = "rt-appgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  # Only route DMZ subnet (where the webserver lives) through the firewalls.
  # Using vnet_address_space (10.0.0.0/16) was too broad — it also caught
  # App-GW replies to NVA internal NIC IPs, sending them through the back LB
  # which hashes by SourceIP and may pick a *different* NVA than the one that
  # initiated the flow → asymmetric routing on the App-GW-to-NVA reply leg.
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

# DMZ default route → back LB DMZ frontend
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
