# ---------------------------------------------------------------------------
# Azure Firewall — the single firewall for BOTH directions in design-3.
#
# It replaces the design-1/2 active/active NVA pair + Internal LB entirely:
#
#   INBOUND  : App GW (snet-appgateway) --UDR--> firewall --> webserver
#              enforced by the "inbound-web" network rule (only App GW subnet
#              may reach the webserver on 80/443).
#   OUTBOUND : webserver --UDR 0.0.0.0/0--> firewall --SNAT--> Internet
#              enforced by the egress network rules (DNS/NTP) + application
#              rules (FQDN allow-list).
#   MGMT     : admin --> firewall public IP:22 --DNAT--> webserver:22
#              source-restricted to var.allowed_ssh_cidr.
#
# Why this stays symmetric where an NVA pair would not: Azure Firewall is a
# managed cluster whose instances share one session table behind a single
# private IP. UDRs force both legs of each flow through that IP; the firewall
# does NOT SNAT VNet-internal (private→private) traffic, so the webserver's
# reply to the App GW keeps the App GW's real private IP as its destination
# and follows the web-subnet UDR back through the firewall. No LB hashing of
# independent stateful devices => none of design-1's asymmetric-routing drops.
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

resource "azurerm_firewall_policy" "main" {
  name                = "fwpol-${var.name_prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = var.firewall_sku_tier
  tags                = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "main" {
  name               = "rcg-main"
  firewall_policy_id = azurerm_firewall_policy.main.id
  priority           = 100

  # --- Management: publish SSH to the webserver via the firewall public IP ---
  nat_rule_collection {
    name     = "mgmt-dnat"
    priority = 100
    action   = "Dnat"

    rule {
      name                = "ssh-to-webserver"
      protocols           = ["TCP"]
      source_addresses    = [var.allowed_ssh_cidr]
      destination_address = azurerm_public_ip.firewall.ip_address
      destination_ports   = ["22"]
      translated_address  = var.webserver_ip
      translated_port     = "22"
    }
  }

  # --- Inbound: only the App Gateway subnet may reach the webserver ---
  network_rule_collection {
    name     = "inbound-web"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "appgw-to-webserver"
      protocols             = ["TCP"]
      source_addresses      = [var.subnet_appgw_cidr]
      destination_addresses = [var.webserver_ip]
      destination_ports     = ["80", "443"]
    }
  }

  # --- Egress L3/L4: DNS + NTP from the web subnet ---
  network_rule_collection {
    name     = "egress-infra"
    priority = 210
    action   = "Allow"

    rule {
      name                  = "dns"
      protocols             = ["UDP", "TCP"]
      source_addresses      = [var.subnet_web_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["53"]
    }

    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = [var.subnet_web_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
  }

  # --- Egress L7: the webserver may only reach these FQDNs over HTTP/HTTPS ---
  application_rule_collection {
    name     = "egress-web"
    priority = 300
    action   = "Allow"

    rule {
      name              = "allowed-fqdns"
      source_addresses  = [var.subnet_web_cidr]
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
  firewall_policy_id  = azurerm_firewall_policy.main.id
  zones               = ["1", "2", "3"]
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
}

# ---------------------------------------------------------------------------
# UDRs.
#
# App GW subnet: send only the webserver subnet through the firewall. This is
# a SPECIFIC route (not 0.0.0.0/0), which App Gateway v2 permits — the
# gateway's own management/Internet traffic is untouched, so it stays healthy.
#
# Web subnet: send the App GW subnet (inbound return leg) AND the default
# route (egress) through the firewall. The return-leg route is required
# because without it the webserver's reply to the App GW would take the
# VnetLocal system route and bypass the firewall, breaking flow symmetry.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "appgw" {
  name                = "rt-${var.name_prefix}-appgw"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  route {
    name                   = "web-via-firewall"
    address_prefix         = var.subnet_web_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.main.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "appgw" {
  subnet_id      = azurerm_subnet.appgw.id
  route_table_id = azurerm_route_table.appgw.id
}

resource "azurerm_route_table" "web" {
  name                = "rt-${var.name_prefix}-web"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  # Inbound return leg: webserver → App GW must go back through the firewall.
  route {
    name                   = "appgw-return-via-firewall"
    address_prefix         = var.subnet_appgw_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.main.ip_configuration[0].private_ip_address
  }

  # Egress: everything else out via the firewall.
  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.main.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "web" {
  subnet_id      = azurerm_subnet.web.id
  route_table_id = azurerm_route_table.web.id
}
