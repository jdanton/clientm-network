# ---------------------------------------------------------------------------
# Resource group + VNets + subnets
#
# Two VNets mirroring production:
#   vnet-fw  (firewall transit): external, internal, DMZ subnets + NVAs + webserver
#   vnet-appgw (server/app):     App Gateway subnet
#
# VNet peering (bidirectional, allow_forwarded_traffic) provides full routing
# between both VNets. UDRs on the AppGW subnet force App GW → webserver traffic
# through the back LB → NVAs, reproducing the asymmetric routing condition.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --- Firewall transit VNet (NVAs + webserver) ---

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-fw-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "external" {
  name                 = "snet-external"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_external_cidr]
}

resource "azurerm_subnet" "internal" {
  name                 = "snet-internal"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_internal_cidr]
}

resource "azurerm_subnet" "dmz" {
  name                 = "snet-dmz"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_dmz_cidr]
}

# --- App Gateway VNet (separate, mirrors prod vnet-srvfw) ---

resource "azurerm_virtual_network" "appgw" {
  name                = "vnet-appgw-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = var.vnet_appgw_address_space
  tags                = var.tags
}

# App Gateway requires a dedicated subnet
resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgateway"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.appgw.name
  address_prefixes     = [var.subnet_appgw_cidr]
}

# --- VNet peering (bidirectional) ---

resource "azurerm_virtual_network_peering" "fw_to_appgw" {
  name                         = "peer-fw-to-appgw"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.lab.name
  remote_virtual_network_id    = azurerm_virtual_network.appgw.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true

  # Wait for all subnets in both VNets to finish provisioning — Azure rejects
  # peering creation if either VNet is still in "Updating" state from a subnet op.
  depends_on = [
    azurerm_subnet.external,
    azurerm_subnet.internal,
    azurerm_subnet.dmz,
    azurerm_subnet.appgw,
  ]
}

resource "azurerm_virtual_network_peering" "appgw_to_fw" {
  name                         = "peer-appgw-to-fw"
  resource_group_name          = azurerm_resource_group.lab.name
  virtual_network_name         = azurerm_virtual_network.appgw.name
  remote_virtual_network_id    = azurerm_virtual_network.lab.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true

  # Serialize after the first peering — concurrent peering ops on the same VNet
  # pair race against the VNet's "Updating" state and one will 400.
  depends_on = [
    azurerm_virtual_network_peering.fw_to_appgw,
  ]
}
