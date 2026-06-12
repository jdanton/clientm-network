output "appgw_public_ip" {
  description = "App Gateway public IP — entrypoint for client traffic"
  value       = azurerm_public_ip.appgw.ip_address
}

output "nva_public_ip" {
  description = "NVA untrust NIC public IP — management SSH AND the IP egress is SNATed to (no separate firewall PIP in this design)"
  value       = azurerm_public_ip.nva.ip_address
}

output "nva_trust_ip" {
  description = "NVA trust NIC private IP — App Gateway backend pool target"
  value       = var.nva_trust_ip
}

output "nva_dmz_ip" {
  description = "NVA dmz NIC private IP — DMZ subnet 0.0.0.0/0 next-hop"
  value       = var.nva_dmz_ip
}

output "webserver_ip" {
  description = "Webserver private IP (DMZ subnet, no public IP)"
  value       = var.webserver_ip
}

output "test_commands" {
  value = <<-EOT
    APPGW=${azurerm_public_ip.appgw.ip_address}
    NVA=${azurerm_public_ip.nva.ip_address}

    # --- Inbound (client → App GW WAF → NVA trust → DNAT → webserver) ---
    curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/healthz                # expect 200 OK

    # remote_addr should be the NVA DMZ IP (${var.nva_dmz_ip}); x-forwarded-for your IP
    curl -sk --resolve connect.clientmworkspace.com:443:$APPGW \
      https://connect.clientmworkspace.com/whoami

    # --- Management SSH ---
    ssh azureuser@$NVA                                            # NVA itself
    ssh -J azureuser@$NVA azureuser@${var.webserver_ip}           # jump to webserver

    # --- Egress (on the webserver, via jump) ---
    curl -s https://api.ipify.org ; echo                          # expect == $NVA (SNAT to NVA pub IP)
    curl -s http://azure.archive.ubuntu.com/ -o /dev/null -w '%%{http_code}\n'   # expect 200 (HTTP allowed)
    # L4 deny — port 25 (SMTP) is NOT in the allow-list, should fail:
    curl --connect-timeout 8 -s -o /dev/null -w '%%{http_code}\n' http://example.com:25/   # expect 000

    # Inspect NVA state
    ssh azureuser@$NVA "sudo nva-trace"
  EOT
}
