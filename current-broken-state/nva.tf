# ---------------------------------------------------------------------------
# Network Virtual Appliances (Linux + iptables, simulating the Palo Altos)
#
# 3 NICs each (matching production):
#   - eth0 (external, snet-external)  — faces the front LB
#   - eth1 (internal, snet-internal)  — faces the back LB internal frontend
#   - eth2 (DMZ, snet-dmz)            — faces the back LB DMZ frontend
#
# eth2 is the key addition: webserver return traffic arrives here via the
# back LB DMZ frontend (10.0.3.10), reproducing the asymmetric routing
# condition when the returning NVA has no conntrack entry for the flow.
# ---------------------------------------------------------------------------

locals {
  nva_cloud_init = templatefile("${path.module}/nva.yaml.tftpl", {
    webserver_ip     = var.webserver_ip
    appgw_private_ip = var.appgw_private_ip
    external_cidr    = var.subnet_external_cidr
    internal_cidr    = var.subnet_internal_cidr
    dmz_cidr         = var.subnet_dmz_cidr
    appgw_cidr       = var.vnet_appgw_address_space[0]
  })
}

# Public IPs for management SSH
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

# External NICs (eth0) — face the front LB
resource "azurerm_network_interface" "nva_external" {
  for_each = {
    nva1 = var.nva1_external_ip
    nva2 = var.nva2_external_ip
  }
  name                  = "nic-${each.key}-ext"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true
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

# Internal NICs (eth1) — face the back LB internal frontend (10.0.4.4)
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

# DMZ NICs (eth2) — face the back LB DMZ frontend (10.0.3.10)
# Return traffic from the webserver arrives here. The asymmetric routing bug
# manifests when this NVA has no conntrack entry for the inbound flow.
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
