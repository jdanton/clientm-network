# ---------------------------------------------------------------------------
# Azure Firewall — the egress firewall this design adds on top of design-1.
#
# Why Azure Firewall and not "a second NVA pair" for egress:
#   Re-using the active/active NVA pattern for egress would put a load
#   balancer in front of two independent stateful firewalls. The LB hashes
#   the webserver's outbound flow to one NVA and the return packet can land
#   on the other → INVALID → DROP. That is the exact asymmetric-routing
#   failure design-1 deliberately avoided by NOT firewalling egress.
#
#   Azure Firewall sidesteps it: it is a managed, horizontally-scaled cluster
#   whose instances SHARE session state behind a single private IP. UDRs point
#   at that one IP, and any instance can handle the return half of a flow
#   another instance opened. Symmetric by construction. (See EXPLANATION.md.)
#
# Flow added by this file:
#   webserver (10.0.3.100) --0.0.0.0/0 UDR--> Azure Firewall private IP
#     --> firewall applies network/application rules, SNATs to its public IP
#     --> Internet. Return traffic comes back to the firewall public IP and
#         the cluster's shared state returns it to the webserver.
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

  # DNS proxy off: the webserver resolves names via Azure DNS (168.63.129.16)
  # directly, which is reached over the platform system route and never
  # transits the firewall. The firewall does its own FQDN resolution for the
  # application rules below.
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "rcg-egress"
  firewall_policy_id = azurerm_firewall_policy.egress.id
  priority           = 200

  # L3/L4 allow-list for the DMZ: outbound DNS + NTP. Everything else at the
  # network layer is implicitly denied.
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

  # L7 allow-list: the webserver may only reach these FQDNs over HTTP/HTTPS.
  # This is the egress inspection the client asked for — anything not on the
  # list (e.g. a C2 callback or data-exfil endpoint) is denied and logged.
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

# ---------------------------------------------------------------------------
# DMZ egress UDR: send the webserver's Internet-bound traffic to the firewall.
#
# Only 0.0.0.0/0 is overridden. Intra-VNet traffic (incl. the inbound return
# path webserver -> NVA DMZ IP at 10.0.3.x) keeps using the more-specific
# VNet system route, so the design-1 inbound path is untouched. Azure's
# special 168.63.129.16 platform route is also unaffected by this UDR.
# ---------------------------------------------------------------------------
resource "azurerm_route_table" "dmz_egress" {
  name                = "rt-${var.name_prefix}-dmz-egress"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.main.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "dmz_egress" {
  subnet_id      = azurerm_subnet.dmz.id
  route_table_id = azurerm_route_table.dmz_egress.id
}
