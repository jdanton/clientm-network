# ---------------------------------------------------------------------------
# Webserver — nginx, in snet-dmz, no public IP.
#
# Reached for management via ProxyJump through the NVA (the NVA's untrust NIC
# carries the only public IP in this design). The NVA's iptables PREROUTING
# DNAT lands all App-GW-bound :80/:443 here; the NVA's POSTROUTING SNAT on
# the DMZ NIC makes the return path symmetric without any LB.
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

  # Boot the webserver after the NVA + the DMZ subnet's 0.0.0.0/0 → NVA UDR
  # exist, so the webserver's egress (apt) hits a configured firewall path
  # rather than Azure's default Internet route. Combined with the cloud-init
  # apt retry loop, this avoids the same class of race design-3 first hit.
  depends_on = [
    azurerm_linux_virtual_machine.nva,
    azurerm_subnet_route_table_association.dmz,
  ]

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
