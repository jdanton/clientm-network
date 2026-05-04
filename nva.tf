# ---------------------------------------------------------------------------
# Active/Active NVAs (Linux + iptables, simulating Palo Alto firewalls)
#
# 2 NICs each:
#   eth0 (trust, snet-trust)  — receives traffic from Internal LB
#   eth1 (dmz,   snet-dmz)    — forwards to webserver (with SNAT for symmetric return)
#
# Linux assigns NICs to eth0/eth1 in PCI/MAC order, NOT Terraform list
# order — the cloud-init detects which interface is which by subnet.
# ---------------------------------------------------------------------------

locals {
  nva_cloud_init = templatefile("${path.module}/nva.yaml.tftpl", {
    webserver_ip      = var.webserver_ip
    trust_cidr        = var.subnet_trust_cidr
    dmz_cidr          = var.subnet_dmz_cidr
    appgw_subnet_cidr = var.subnet_appgw_cidr
  })
}

# Public IPs for NVA management SSH
resource "azurerm_public_ip" "nva" {
  for_each            = toset(["nva1", "nva2"])
  name                = "pip-${each.key}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["2"]
  tags                = var.tags
}

# Trust NICs (eth0 logical) — Internal LB pool members
resource "azurerm_network_interface" "nva_trust" {
  for_each = {
    nva1 = var.nva1_trust_ip
    nva2 = var.nva2_trust_ip
  }
  name                  = "nic-${each.key}-trust"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig-trust"
    subnet_id                     = azurerm_subnet.trust.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
    public_ip_address_id          = azurerm_public_ip.nva[each.key].id
    primary                       = true
  }
}

# DMZ NICs (eth1 logical) — face the webserver
resource "azurerm_network_interface" "nva_dmz" {
  for_each = {
    nva1 = var.nva1_dmz_ip
    nva2 = var.nva2_dmz_ip
  }
  name                  = "nic-${each.key}-dmz"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig-dmz"
    subnet_id                     = azurerm_subnet.dmz.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
  }
}

resource "azurerm_linux_virtual_machine" "nva" {
  for_each            = toset(["nva1", "nva2"])
  name                = "vm-${each.key}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = var.vm_size
  admin_username      = var.admin_username
  zone                = "2"
  network_interface_ids = [
    azurerm_network_interface.nva_trust[each.key].id,
    azurerm_network_interface.nva_dmz[each.key].id,
  ]
  tags = var.tags

  custom_data = base64encode(local.nva_cloud_init)

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.disk_type
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
