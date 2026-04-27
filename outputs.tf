output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "nva1_public_ip" {
  description = "SSH to NVA1: ssh azureuser@<this>"
  value       = azurerm_public_ip.nva["nva1"].ip_address
}

output "nva2_public_ip" {
  description = "SSH to NVA2: ssh azureuser@<this>"
  value       = azurerm_public_ip.nva["nva2"].ip_address
}

output "external_lb_public_ip" {
  description = "Front LB public IP. curl -k https://<this> to test inbound."
  value       = azurerm_public_ip.external_lb.ip_address
}

output "appgw_public_ip" {
  description = "App Gateway public IP (the public frontend, not the active listener)."
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_private_ip" {
  description = "App Gateway private listener IP - this is what the firewalls forward to."
  value       = var.appgw_private_ip
}

output "internal_lb_frontend_ip" {
  description = "Internal LB frontend - the DMZ default route points here."
  value       = var.internal_lb_frontend_ip
}

output "webserver_ip" {
  description = "Webserver private IP."
  value       = var.webserver_ip
}

output "test_commands" {
  description = "Useful one-liners for verifying the lab."
  value = <<-EOT
    # SSH to NVA1 (debug iptables, run sudo nva-trace)
    ssh ${var.admin_username}@${azurerm_public_ip.nva["nva1"].ip_address}

    # SSH to NVA2
    ssh ${var.admin_username}@${azurerm_public_ip.nva["nva2"].ip_address}

    # Test direct through front LB (will hit the asymmetric routing bug)
    curl -kv --resolve connect.clientmworkspace.com:443:${azurerm_public_ip.external_lb.ip_address} \
      https://connect.clientmworkspace.com/healthz

    # From inside NVA1, watch packets arrive for the webserver flow:
    sudo tcpdump -i any -nn 'host ${var.webserver_ip} and port 443'

    # From inside NVA2, you should see RETURN traffic that has no conntrack:
    sudo conntrack -L | grep ${var.webserver_ip}
  EOT
}
