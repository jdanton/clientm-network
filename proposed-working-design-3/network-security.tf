# ---------------------------------------------------------------------------
# NSG — only the web subnet needs one in design-3.
#
# All traffic that reaches the webserver arrives from inside the VNet:
#   - inbound web   : App GW → Azure Firewall → webserver (src = App GW IP)
#   - management SSH: admin → firewall DNAT → webserver (src = firewall IP,
#     because Azure Firewall SNATs DNAT'd traffic)
# so a single "allow from VirtualNetwork" inbound rule covers both. The
# admin-IP restriction for SSH lives on the firewall DNAT rule, not here.
#
# The App Gateway subnet is managed by App Gateway and is left without an NSG
# (as in design-1/2). AzureFirewallSubnet must not have an NSG.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  security_rule {
    name                       = "AllowVNetInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}
