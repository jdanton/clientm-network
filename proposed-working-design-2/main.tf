# ---------------------------------------------------------------------------
# Resource group + single VNet + four subnets
#
#   snet-appgateway   10.0.1.0/24   — App Gateway dedicated
#   snet-trust        10.0.2.0/24   — Internal LB frontend + NVA trust NICs
#   snet-dmz          10.0.3.0/24   — NVA DMZ NICs + webserver
#   AzureFirewallSubnet 10.0.4.0/26 — Azure Firewall (NEW vs design-1)
#
# INBOUND is identical to proposed-working-design-1: Internet → AppGW →
# InternalLB → Linux NVA → webserver, all via VnetLocal. NVAs SNAT on the
# DMZ NIC so webserver replies come back to the same NVA without LB hashing.
#
# OUTBOUND (new here): the DMZ subnet carries a 0.0.0.0/0 UDR to the Azure
# Firewall's private IP (see firewall.tf). Azure Firewall is a managed PaaS
# whose instances share session state, so it stays symmetric on the return
# path WITHOUT the asymmetric-routing failure that an LB-fronted NVA pair
# would hit on egress. That asymmetry is exactly why design-1 left egress
# un-firewalled; see EXPLANATION.md.
#
# The firewall subnet MUST be named "AzureFirewallSubnet" (Azure requirement)
# and be at least /26.
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

# Azure Firewall requires a dedicated subnet named exactly "AzureFirewallSubnet"
# (min /26). No NSG and no UDR may be attached to it.
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_firewall_cidr]
}
