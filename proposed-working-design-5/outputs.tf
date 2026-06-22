output "appgw_public_ip" {
  description = "App Gateway public IP — entrypoint for client traffic"
  value       = azurerm_public_ip.appgw.ip_address
}

output "nva_public_ip" {
  description = "NVA untrust NIC public IP — management SSH (still terminates on the NVA in design-5)"
  value       = azurerm_public_ip.nva.ip_address
}

output "nva_trust_ip" {
  description = "NVA trust NIC private IP — App Gateway backend pool target"
  value       = var.nva_trust_ip
}

output "nva_dmz_ip" {
  description = "NVA dmz NIC private IP — webserver-facing (NOT the DMZ UDR next-hop in design-5)"
  value       = var.nva_dmz_ip
}

output "firewall_public_ip" {
  description = "Azure Firewall public IP — egress SNAT source"
  value       = azurerm_public_ip.firewall.ip_address
}

output "firewall_private_ip" {
  description = "Azure Firewall private IP — snet-dmz 0.0.0.0/0 next-hop"
  value       = azurerm_firewall.main.ip_configuration[0].private_ip_address
}

output "webserver_ip" {
  description = "Webserver private IP (DMZ subnet, no public IP)"
  value       = var.webserver_ip
}

output "test_commands" {
  value = <<-EOT
    APPGW=${azurerm_public_ip.appgw.ip_address}
    NVA=${azurerm_public_ip.nva.ip_address}
    FW=${azurerm_public_ip.firewall.ip_address}

    # --- Inbound (client → App GW WAF → NVA trust → DNAT → webserver) ---
    curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/healthz                # expect 200 OK

    # remote_addr should be the NVA DMZ IP (${var.nva_dmz_ip}); x-forwarded-for your IP
    curl -sk --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/whoami

    # --- Management SSH (still via the NVA, not the firewall) ---
    ssh azureuser@$NVA
    ssh -J azureuser@$NVA azureuser@${var.webserver_ip}

    # --- Egress (on the webserver, via jump) — Azure Firewall this time ---
    curl -s https://api.ipify.org ; echo                          # expect == $FW (firewall SNAT)
    curl -s http://azure.archive.ubuntu.com/ -o /dev/null -w '%%{http_code}\n'   # expect 200 (allow-listed)
    curl -s --max-time 10 https://example.com/ -o /dev/null -w '%%{http_code}\n' # expect 000 (FQDN denied)

    # Inspect NVA state (firewall logs need a Log Analytics workspace — not wired up here)
    ssh azureuser@$NVA "sudo nva-trace"
  EOT
}
