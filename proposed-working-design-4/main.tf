# ---------------------------------------------------------------------------
# Resource group + VNet + four subnets (one per firewall "zone" + AppGW)
#
#   snet-appgateway 10.0.1.0/24 — App Gateway only
#   snet-trust      10.0.2.0/24 — NVA trust NIC (App Gateway backend target)
#   snet-dmz        10.0.3.0/24 — NVA dmz NIC + webserver (protected zone)
#   snet-untrust    10.0.4.0/24 — NVA untrust NIC (Internet egress + mgmt PIP)
#
# Three-NIC layout per Patrick's 2026-06-12 review: Azure Firewall's single
# interface couldn't represent the textbook untrust/trust/dmz zone separation,
# so we use a Linux NVA with three NICs (iptables) instead. Single NVA → no
# LB hashing → symmetric flows both directions without recreating the
# asymmetric-routing failure design-1 fought.
#
# Flow:
#   inbound  : client → App GW → NVA trust → DNAT → NVA dmz → webserver
#   egress   : webserver → snet-dmz UDR → NVA dmz → MASQUERADE → NVA untrust →
#              Azure SNAT → Internet
#   mgmt     : admin → NVA untrust PIP (SSH)
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
