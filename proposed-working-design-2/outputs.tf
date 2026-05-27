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

output "firewall_private_ip" {
  description = "Azure Firewall private IP — DMZ 0.0.0.0/0 next hop"
  value       = azurerm_firewall.main.ip_configuration[0].private_ip_address
}

output "firewall_public_ip" {
  description = "Azure Firewall public (SNAT) IP — the source IP the webserver's egress appears to come from"
  value       = azurerm_public_ip.firewall.ip_address
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

    # --- Egress firewall verification ---
    # The webserver has no public IP; jump through an NVA to reach it.
    ssh -J azureuser@${azurerm_public_ip.nva["nva1"].ip_address} azureuser@${var.webserver_ip}

    # On the webserver: an ALLOWED FQDN egresses, SNATed to the firewall IP...
    curl -s https://azure.archive.ubuntu.com/ -o /dev/null -w '%%{http_code}\n'
    # ...and the source IP the Internet sees is the firewall public IP:
    curl -s https://api.ipify.org ; echo      # expect ${azurerm_public_ip.firewall.ip_address}
    # A NON-allow-listed FQDN is blocked by the firewall application rule:
    curl -s --max-time 10 https://example.com/ -o /dev/null -w '%%{http_code}\n'   # expect failure/timeout
  EOT
}
