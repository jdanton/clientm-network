# ---------------------------------------------------------------------------
# Resource group + single VNet + three subnets
#
#   snet-appgateway 10.0.1.0/24  — App Gateway dedicated
#   snet-trust      10.0.2.0/24  — Internal LB frontend + NVA trust NICs
#   snet-dmz        10.0.3.0/24  — NVA DMZ NICs + webserver
#
# No UDRs needed — traffic flow is Internet → AppGW → InternalLB → NVA →
# webserver, all via VnetLocal. NVAs SNAT on the DMZ NIC so webserver
# replies come back to the same NVA without LB hashing.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgateway"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_appgw_cidr]
}

resource "azurerm_subnet" "trust" {
  name                 = "snet-trust"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_trust_cidr]
}

resource "azurerm_subnet" "dmz" {
  name                 = "snet-dmz"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_dmz_cidr]
}
