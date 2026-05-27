# ---------------------------------------------------------------------------
# Resource group + single VNet + three subnets
#
#   snet-appgateway     10.0.1.0/24  — App Gateway WAF (public edge)
#   snet-web            10.0.3.0/24  — webserver (no NVAs, no Internal LB)
#   AzureFirewallSubnet 10.0.4.0/26  — Azure Firewall (both directions)
#
# design-3 vs design-1/2: the active/active Linux NVA pair AND the Internal
# Load Balancer are GONE. Azure Firewall replaces them and inspects BOTH
# directions:
#
#   INBOUND:  Internet → App GW WAF → (UDR) → Azure Firewall → webserver
#   OUTBOUND: webserver → (UDR 0.0.0.0/0) → Azure Firewall → Internet
#
# Azure Firewall shares session state across its instances behind one private
# IP, so both legs of every flow are symmetric without a load balancer hashing
# independent stateful devices — the failure mode design-1 fought. UDRs on the
# App Gateway and web subnets force the cross-subnet (inbound) traffic through
# the firewall; the firewall does NOT SNAT private-to-private traffic, so the
# return path follows the web subnet's UDR back through the firewall.
#
# The firewall subnet MUST be named "AzureFirewallSubnet" and be >= /26.
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

resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_web_cidr]
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_firewall_cidr]
}
