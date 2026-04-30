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
    # SSH to NVA1 / NVA2
    ssh ${var.admin_username}@${azurerm_public_ip.nva["nva1"].ip_address}
    ssh ${var.admin_username}@${azurerm_public_ip.nva["nva2"].ip_address}

    # Inbound test through front LB (DNAT'd to App GW, App GW → webserver)
    curl -kv --resolve connect.clientmworkspace.com:443:${azurerm_public_ip.external_lb.ip_address} \
      https://connect.clientmworkspace.com/healthz

    # The bug lives on the webserver → App GW return path. Watch eth2 (DMZ NIC)
    # on the NVA that the DMZ LB hashes the webserver to — it'll see SYN-ACKs
    # from ${var.webserver_ip} → ${var.appgw_private_ip} with no matching conntrack:
    sudo tcpdump -i eth2 -nn "host ${var.appgw_private_ip} and host ${var.webserver_ip}"

    # On either NVA: confirm the INVALID drop counter is incrementing
    sudo iptables -L FORWARD -v -n | grep INVALID

    # On either NVA: full firewall state
    sudo nva-trace
  EOT
}
