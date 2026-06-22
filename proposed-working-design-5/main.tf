# ---------------------------------------------------------------------------
# design-5 — two-firewall solution: Linux NVA (inbound) + Azure Firewall (egress)
#
#   snet-appgateway     10.0.1.0/24 — App Gateway only
#   snet-trust          10.0.2.0/24 — NVA trust NIC (App Gateway backend)
#   snet-dmz            10.0.3.0/24 — NVA dmz NIC + webserver (protected zone)
#   snet-untrust        10.0.4.0/24 — NVA untrust NIC (carries mgmt PIP)
#   AzureFirewallSubnet 10.0.5.0/26 — Azure Firewall (egress)
#
# This is design-4's 3-NIC NVA (Patrick's NGFW-shape zone separation, single
# instance → no LB asymmetry) with Azure Firewall added back for egress —
# answering the "client needs a two firewall solution" requirement. The NVA
# owns inbound DNAT/SNAT; the firewall owns egress FQDN allow-listing.
#
# Flow:
#   inbound  : client → App GW → NVA trust → DNAT → NVA dmz → webserver
#   egress   : webserver → snet-dmz UDR → Azure Firewall → Internet
#              (bypasses the NVA on the egress leg — different from design-4)
#   mgmt     : admin → NVA untrust PIP (SSH); webserver via ProxyJump
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

resource "azurerm_subnet" "untrust" {
  name                 = "snet-untrust"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_untrust_cidr]
}

# Azure Firewall requires this exact subnet name; min /26.
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_firewall_cidr]
}
