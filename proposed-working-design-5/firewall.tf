# ---------------------------------------------------------------------------
# Azure Firewall — egress only.
#
# Inbound is owned by the multi-NIC Linux NVA (see nva.tf / nva.yaml.tftpl);
# this firewall handles only the webserver's outbound flows. snet-dmz UDR
# 0.0.0.0/0 → this firewall's private IP, exactly like design-2 and design-3.
#
# No DNAT rule here — admin SSH still terminates on the NVA's untrust PIP,
# not on the firewall. Keeping management on the NVA preserves the "the NVA
# is the inbound firewall" story and avoids an extra DNAT hop.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "firewall" {
  name                = "pip-${var.name_prefix}-fw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_firewall_policy" "egress" {
  name                = "fwpol-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = var.firewall_sku_tier
  tags                = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "rcg-egress"
  firewall_policy_id = azurerm_firewall_policy.egress.id
  priority           = 200

  network_rule_collection {
    name     = "net-egress"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "dns"
      protocols             = ["UDP", "TCP"]
      source_addresses      = [var.subnet_dmz_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["53"]
    }

    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = [var.subnet_dmz_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
  }

  application_rule_collection {
    name     = "app-egress"
    priority = 300
    action   = "Allow"

    rule {
      name              = "allowed-fqdns"
      source_addresses  = [var.subnet_dmz_cidr]
      destination_fqdns = var.egress_allowed_fqdns

      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}

resource "azurerm_firewall" "main" {
  name                = "afw-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = "AZFW_VNet"
  sku_tier            = var.firewall_sku_tier
  firewall_policy_id  = azurerm_firewall_policy.egress.id
  zones               = ["1", "2", "3"]
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
}
