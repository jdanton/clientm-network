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
  description = "Front LB public IP (VPN/HTTPS ingress)."
  value       = azurerm_public_ip.external_lb.ip_address
}

output "appgw_public_ip" {
  description = "App Gateway public IP (present but no active listener — listener is on private IP)."
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_private_ip" {
  description = "App Gateway private listener IP (10.1.1.x in the App GW VNet)."
  value       = var.appgw_private_ip
}

output "internal_lb_internal_frontend_ip" {
  description = "Back LB internal frontend — App GW → webserver inbound path."
  value       = var.internal_lb_frontend_ip
}

output "internal_lb_dmz_frontend_ip" {
  description = "Back LB DMZ frontend — webserver return path (source of the asymmetric routing bug)."
  value       = var.dmz_lb_frontend_ip
}

output "webserver_ip" {
  description = "Webserver private IP (in snet-dmz)."
  value       = var.webserver_ip
}

output "test_commands" {
  description = "Useful one-liners for verifying the lab."
  value = <<-EOT
    # SSH to NVA1 (debug iptables / conntrack)
    ssh ${var.admin_username}@${azurerm_public_ip.nva["nva1"].ip_address}

    # SSH to NVA2
    ssh ${var.admin_username}@${azurerm_public_ip.nva["nva2"].ip_address}

    # Test inbound through front LB (triggers the NVA path)
    curl -kv --resolve connect.clientmworkspace.com:443:${azurerm_public_ip.external_lb.ip_address} \
      https://connect.clientmworkspace.com/healthz

    # On NVA1: watch packets for the webserver flow
    sudo tcpdump -i any -nn 'host ${var.webserver_ip} and port 443'

    # On NVA2: verify RETURN traffic arrives with no conntrack entry (the bug)
    sudo conntrack -L | grep ${var.webserver_ip}

    # On either NVA: full firewall state
    sudo nva-trace
  EOT
}
