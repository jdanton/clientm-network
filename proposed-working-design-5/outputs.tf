output "appgw_public_ip" {
  description = "App Gateway PUBLIC frontend IP — original client edge (validate-flows.sh uses this)"
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_private_ip" {
  description = "App Gateway PRIVATE frontend IP — reachable only from inside the VNet (test client)"
  value       = var.appgw_private_ip
}

output "test_client_public_ip" {
  description = "In-VNet test client public IP — SSH here, then curl the App GW private IP"
  value       = azurerm_public_ip.test.ip_address
}

output "natgw_public_ip" {
  description = "NAT Gateway public IP — App Gateway outbound SNAT source (private-only egress)"
  value       = azurerm_public_ip.natgw.ip_address
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
    TEST=${azurerm_public_ip.test.ip_address}     # in-VNet test client (SSH here)
    APPGW_PUB=${azurerm_public_ip.appgw.ip_address}   # App GW PUBLIC frontend
    APPGW_PRIV=${var.appgw_private_ip}                 # App GW PRIVATE frontend (in-VNet only)
    NVA=${azurerm_public_ip.nva.ip_address}
    FW=${azurerm_public_ip.firewall.ip_address}

    # --- Inbound via PUBLIC frontend (from your laptop) ---
    curl -kv --resolve connect.clientmworkspace.com:443:$APPGW_PUB \
      https://connect.clientmworkspace.com/healthz                # expect 200 OK

    # --- Inbound via PRIVATE frontend (from INSIDE the VNet — the variant under test) ---
    ssh azureuser@$TEST "curl -sk --resolve connect.clientmworkspace.com:443:${var.appgw_private_ip} \
      https://connect.clientmworkspace.com/healthz"               # expect 200 OK
    ssh azureuser@$TEST "curl -sk --resolve connect.clientmworkspace.com:443:${var.appgw_private_ip} \
      https://connect.clientmworkspace.com/whoami"                # remote_addr = NVA DMZ ${var.nva_dmz_ip}

    # --- Observe where the probe/backend traffic actually lands on the NVA ---
    ssh azureuser@$NVA "sudo nva-trace"            # watch trust-NIC hits from the App GW

    # --- Management SSH (still via the NVA) ---
    ssh azureuser@$NVA
    ssh -J azureuser@$NVA azureuser@${var.webserver_ip}

    # --- Egress (on the webserver, via jump) — Azure Firewall ---
    curl -s https://api.ipify.org ; echo                          # expect == $FW (firewall SNAT)
    curl -s http://azure.archive.ubuntu.com/ -o /dev/null -w '%%{http_code}\n'   # expect 200 (allow-listed)
    curl -s --max-time 10 https://example.com/ -o /dev/null -w '%%{http_code}\n' # expect 000 (FQDN denied)
  EOT
}
