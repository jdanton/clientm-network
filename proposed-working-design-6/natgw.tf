# ---------------------------------------------------------------------------
# NAT Gateway on snet-appgateway.
#
# A private-only App Gateway v2 has no public IP, so it loses the default
# outbound path it used for control-plane needs (CRL/OCSP cert-revocation
# checks, Key Vault, metrics). Azure default outbound access is being retired,
# so we give the App Gateway subnet an explicit, deterministic egress via a
# NAT Gateway. This is the "additional resource" the private-only variant needs.
#
# NAT Gateway is regional (non-zonal) here; it still provides outbound SNAT for
# the zone-redundant App Gateway instances in the subnet.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "natgw" {
  name                = "pip-${var.name_prefix}-natgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "appgw" {
  name                = "natgw-${var.name_prefix}-appgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "appgw" {
  nat_gateway_id       = azurerm_nat_gateway.appgw.id
  public_ip_address_id = azurerm_public_ip.natgw.id
}

resource "azurerm_subnet_nat_gateway_association" "appgw" {
  subnet_id      = azurerm_subnet.appgw.id
  nat_gateway_id = azurerm_nat_gateway.appgw.id
}
