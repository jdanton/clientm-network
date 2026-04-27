# ---------------------------------------------------------------------------
# DMZ Webserver
# Static IP 10.29.254.250 to match the prod App Gateway backend pool.
# nginx with /healthz and self-signed cert for connect.clientmworkspace.com.
# ---------------------------------------------------------------------------

locals {
  webserver_cloud_init = file("${path.module}/webserver.yaml.tftpl")
}

resource "azurerm_network_interface" "webserver" {
  name                = "nic-webserver"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-dmz"
    subnet_id                     = azurerm_subnet.dmz.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.webserver_ip
  }
}

resource "azurerm_linux_virtual_machine" "webserver" {
  name                  = "vm-webserver"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  zone                  = "2"
  network_interface_ids = [azurerm_network_interface.webserver.id]
  tags                  = var.tags

  custom_data = base64encode(local.webserver_cloud_init)

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
