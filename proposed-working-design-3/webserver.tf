# ---------------------------------------------------------------------------
# Web subnet webserver — nginx with /healthz and /whoami (shows X-Forwarded-For).
#
# No NVA in front of it anymore. Inbound arrives via App GW → Azure Firewall;
# since the firewall does not SNAT private traffic, nginx sees remote_addr =
# the App Gateway instance's private IP (10.0.1.x) and X-Forwarded-For = the
# original client IP (added by App GW). No public IP — management SSH is
# published through the firewall DNAT rule (see firewall.tf).
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
    name                          = "ipconfig-web"
    subnet_id                     = azurerm_subnet.web.id
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

  # Boot the webserver only after the egress path is in place — the firewall
  # rule collection (allows the apt FQDNs) and the web subnet's route table
  # (0.0.0.0/0 → firewall). Combined with the apt retry loop in cloud-init,
  # this avoids the first-boot race where apt egress is denied before the
  # firewall rules have propagated.
  depends_on = [
    azurerm_firewall_policy_rule_collection_group.main,
    azurerm_subnet_route_table_association.web,
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
