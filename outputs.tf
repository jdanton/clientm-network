output "appgw_public_ip" {
  description = "App Gateway public IP — entrypoint for client traffic"
  value       = azurerm_public_ip.appgw.ip_address
}

output "internal_lb_frontend_ip" {
  description = "Internal LB private IP — App GW backend pool member"
  value       = var.internal_lb_frontend_ip
}

output "nva1_public_ip" {
  description = "SSH to NVA1: ssh azureuser@<this>"
  value       = azurerm_public_ip.nva["nva1"].ip_address
}

output "nva2_public_ip" {
  description = "SSH to NVA2"
  value       = azurerm_public_ip.nva["nva2"].ip_address
}

output "webserver_ip" {
  description = "Webserver private IP (DMZ subnet)"
  value       = var.webserver_ip
}

output "test_commands" {
  value = <<-EOT
    APPGW=${azurerm_public_ip.appgw.ip_address}

    # Health
    curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/healthz

    # Verify X-Forwarded-For propagates from client → AppGW → InternalLB → NVA → webserver
    curl -sk --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/whoami

    # SSH to NVAs
    ssh azureuser@${azurerm_public_ip.nva["nva1"].ip_address}
    ssh azureuser@${azurerm_public_ip.nva["nva2"].ip_address}

    # On either NVA
    sudo nva-trace
  EOT
}
