# ---------------------------------------------------------------------------
# Network Virtual Appliances (Linux + iptables, simulating the Palo Altos)
#
# 2 NICs each:
#   - eth0 (external, in snet-external) - faces the front LB
#   - eth1 (internal, in snet-internal) - faces the internal LB / DMZ
#
# Each NVA gets its own public IP so you can SSH directly for debugging.
# (NSG locks SSH to var.allowed_ssh_cidr.)
# ---------------------------------------------------------------------------

locals {
  nva_cloud_init = templatefile("${path.module}/nva.yaml.tftpl", {
    webserver_ip  = var.webserver_ip
    internal_cidr = var.subnet_internal_cidr
    dmz_cidr      = var.subnet_dmz_cidr
    appgw_cidr    = var.subnet_appgw_cidr
  })
}

# Public IPs for management (and source of egress SNAT in lab)
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

# External NICs (eth0)
resource "azurerm_network_interface" "nva_external" {
  for_each = {
    nva1 = var.nva1_external_ip
    nva2 = var.nva2_external_ip
  }
  name                  = "nic-${each.key}-ext"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true # Required for the VM to forward IP packets
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig-ext"
    subnet_id                     = azurerm_subnet.external.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
    public_ip_address_id          = azurerm_public_ip.nva[each.key].id
    primary                       = true
  }
}

# Internal NICs (eth1)
resource "azurerm_network_interface" "nva_internal" {
  for_each = {
    nva1 = var.nva1_internal_ip
    nva2 = var.nva2_internal_ip
  }
  name                  = "nic-${each.key}-int"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig-int"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
  }
}

# NVA VMs
resource "azurerm_linux_virtual_machine" "nva" {
  for_each              = toset(["nva1", "nva2"])
  name                  = "vm-${each.key}"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  zone                  = "2"
  network_interface_ids = [
    azurerm_network_interface.nva_external[each.key].id,
    azurerm_network_interface.nva_internal[each.key].id,
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

  # Optional cost saver: B-series shutdown when idle is fine, just stop/dealloc
  # via Azure Portal or `az vm deallocate` between test sessions.
}
