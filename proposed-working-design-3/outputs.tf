output "appgw_public_ip" {
  description = "App Gateway public IP — entrypoint for client traffic"
  value       = azurerm_public_ip.appgw.ip_address
}

output "firewall_public_ip" {
  description = "Azure Firewall public IP — egress SNAT source AND the DNAT target for management SSH"
  value       = azurerm_public_ip.firewall.ip_address
}

output "firewall_private_ip" {
  description = "Azure Firewall private IP — next hop for the App GW and web subnet UDRs"
  value       = azurerm_firewall.main.ip_configuration[0].private_ip_address
}

output "webserver_ip" {
  description = "Webserver private IP (web subnet, no public IP)"
  value       = var.webserver_ip
}

output "test_commands" {
  value = <<-EOT
    APPGW=${azurerm_public_ip.appgw.ip_address}
    FW=${azurerm_public_ip.firewall.ip_address}

    # --- Inbound (client → App GW WAF → Azure Firewall → webserver) ---
    curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/healthz          # expect 200 OK

    # remote_addr should be an App GW private IP (10.0.1.x); x-forwarded-for your IP
    curl -sk --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/whoami

    # --- Management SSH (admin → firewall public IP → DNAT → webserver) ---
    ssh azureuser@$FW

    # --- Egress (on the webserver) ---
    curl -s https://api.ipify.org ; echo                    # expect == $FW (SNAT)
    curl -s --max-time 10 https://example.com/ -o /dev/null -w '%%{http_code}\n'  # blocked

    # No-SSH alternative to run the egress check via the Azure control plane:
    # az vm run-command invoke -g ${var.resource_group_name} -n vm-webserver \
    #   --command-id RunShellScript --scripts "curl -s https://api.ipify.org"
  EOT
}
