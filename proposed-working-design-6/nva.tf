# ---------------------------------------------------------------------------
# Single Linux NVA with THREE NICs — one per firewall zone.
#
#   eth0 ↔ untrust (snet-untrust 10.0.4.10) — Internet egress + mgmt PIP
#   eth1 ↔ trust   (snet-trust   10.0.2.10) — App Gateway backend target
#   eth2 ↔ dmz     (snet-dmz     10.0.3.10) — webserver-facing
#
# Linux assigns ethN by PCI/MAC order, NOT by Terraform list order, so the
# cloud-init detects each NIC by which subnet its IP belongs to. ip_forwarding
# is enabled on every NIC.
# ---------------------------------------------------------------------------

locals {
  nva_cloud_init = templatefile("${path.module}/nva.yaml.tftpl", {
    webserver_ip  = var.webserver_ip
    appgw_cidr    = var.subnet_appgw_cidr
    trust_cidr    = var.subnet_trust_cidr
    dmz_cidr      = var.subnet_dmz_cidr
    untrust_cidr  = var.subnet_untrust_cidr
    vnet_supernet = var.vnet_address_space[0]
  })
}

resource "azurerm_public_ip" "nva" {
  name                = "pip-${var.name_prefix}-nva"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["2"]
  tags                = var.tags
}

resource "azurerm_network_interface" "nva_untrust" {
  name                  = "nic-nva-untrust"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig-untrust"
    subnet_id                     = azurerm_subnet.untrust.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.nva_untrust_ip
    public_ip_address_id          = azurerm_public_ip.nva.id
    primary                       = true
  }
}

resource "azurerm_network_interface" "nva_trust" {
  name                  = "nic-nva-trust"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig-trust"
    subnet_id                     = azurerm_subnet.trust.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.nva_trust_ip
  }
}

resource "azurerm_network_interface" "nva_dmz" {
  name                  = "nic-nva-dmz"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig-dmz"
    subnet_id                     = azurerm_subnet.dmz.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.nva_dmz_ip
  }
}

resource "azurerm_linux_virtual_machine" "nva" {
  name                = "vm-nva"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = var.vm_size
  admin_username      = var.admin_username
  zone                = "2"
  tags                = var.tags

  # NIC order here does NOT determine eth0/eth1/eth2 in Linux — cloud-init
  # detects each NIC by its subnet. The untrust NIC is marked primary above
  # so it owns the default route metric Azure publishes via DHCP.
  network_interface_ids = [
    azurerm_network_interface.nva_untrust.id,
    azurerm_network_interface.nva_trust.id,
    azurerm_network_interface.nva_dmz.id,
  ]

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
