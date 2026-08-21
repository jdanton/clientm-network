locals {
  # Public IP only exists in fallback mode (appgw_private_only = false).
  appgw_public_display = var.appgw_private_only ? "(none - private-only mode)" : one(azurerm_public_ip.appgw[*].ip_address)
}

output "appgw_private_ip" {
  description = "App Gateway PRIMARY private frontend IP — design-6's front door (reached from in-VNet / peered / on-prem)"
  value       = var.appgw_private_ip
}

output "appgw_public_ip" {
  description = "App Gateway public fallback IP — null when appgw_private_only = true"
  value       = one(azurerm_public_ip.appgw[*].ip_address)
}

output "appgw_private_only" {
  description = "Whether the gateway is truly private-only (no public frontend)"
  value       = var.appgw_private_only
}

output "test_client_public_ip" {
  description = "In-VNet test client public IP — SSH here, then curl the App GW private front door"
  value       = azurerm_public_ip.test.ip_address
}

output "natgw_public_ip" {
  description = "NAT Gateway public IP — App Gateway control-plane egress SNAT source (required when private-only)"
  value       = azurerm_public_ip.natgw.ip_address
}

output "nva_public_ip" {
  description = "NVA untrust NIC public IP — management SSH front door"
  value       = azurerm_public_ip.nva.ip_address
}

output "nva_trust_ip" {
  description = "NVA trust NIC private IP — App Gateway backend pool target"
  value       = var.nva_trust_ip
}

output "nva_dmz_ip" {
  description = "NVA dmz NIC private IP — webserver-facing"
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
    TEST=${azurerm_public_ip.test.ip_address}       # in-VNet test client (SSH here)
    APPGW_PRIV=${var.appgw_private_ip}                # App GW PRIMARY private front door
    APPGW_PUB=${local.appgw_public_display}           # public fallback (absent in private-only mode)
    NVA=${azurerm_public_ip.nva.ip_address}
    FW=${azurerm_public_ip.firewall.ip_address}

    # --- PRIMARY: inbound via the PRIVATE front door (from inside the VNet) ---
    ssh azureuser@$TEST "curl -sk --resolve connect.clientmworkspace.com:443:${var.appgw_private_ip} \
      https://connect.clientmworkspace.com/healthz"               # expect 200 OK
    ssh azureuser@$TEST "curl -sk --resolve connect.clientmworkspace.com:443:${var.appgw_private_ip} \
      https://connect.clientmworkspace.com/whoami"                # remote_addr = NVA DMZ ${var.nva_dmz_ip}

    # --- Fallback: public frontend (only when appgw_private_only = false) ---
    curl -kv --resolve connect.clientmworkspace.com:443:${local.appgw_public_display} \
      https://connect.clientmworkspace.com/healthz                # expect 200 OK

    # --- Observe where the probe/backend traffic lands on the NVA ---
    ssh azureuser@$NVA "sudo nva-trace"            # watch trust-NIC hits from the App GW

    # --- Management SSH (via the NVA) ---
    ssh azureuser@$NVA
    ssh -J azureuser@$NVA azureuser@${var.webserver_ip}

    # --- Egress (on the webserver, via jump) — Azure Firewall ---
    curl -s https://api.ipify.org ; echo                          # expect == $FW (firewall SNAT)
    curl -s http://azure.archive.ubuntu.com/ -o /dev/null -w '%%{http_code}\n'   # expect 200 (allow-listed)
    curl -s --max-time 10 https://example.com/ -o /dev/null -w '%%{http_code}\n' # expect 000 (FQDN denied)
  EOT
}
