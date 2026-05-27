# Verification Log

## Status: NOT yet deployed

This design has **not** been applied to Azure or tested end-to-end. What has
been done:

- `terraform fmt` clean.
- `terraform validate` passes (config is internally consistent; provider is
  azurerm `~> 4.0`).

The inbound half is byte-for-byte the verified design-1 path, so it carries
design-1's [VERIFIED.md](../proposed-working-design-1/VERIFIED.md) confidence.
The **egress half (Azure Firewall + DMZ UDR) is new and unverified.**

## To verify after `terraform apply`

1. **Inbound still works** (regression check that the egress UDR didn't break
   the return path):
   ```
   APPGW=$(terraform output -raw appgw_public_ip)
   curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
     https://connect.clientmworkspace.com/healthz        # expect 200 OK
   ```

2. **Allowed egress is SNATed through the firewall.** Jump to the webserver via
   an NVA and confirm the source IP the Internet sees is the firewall's public
   IP:
   ```
   ssh -J azureuser@$(terraform output -raw nva1_public_ip) azureuser@10.0.3.100
   curl -s https://api.ipify.org ; echo
   #   expect == terraform output -raw firewall_public_ip
   ```

3. **Disallowed egress is blocked.** From the webserver, a FQDN not on the
   allow-list should fail:
   ```
   curl -s --max-time 10 https://example.com/    # expect timeout / connection refused
   ```

4. **apt still works** through the firewall (allow-list includes Ubuntu repos):
   ```
   sudo apt-get update                            # expect success
   ```

## Known risks to watch for on first deploy

- **DNS:** the webserver resolves names via Azure DNS (168.63.129.16) over the
  platform route, which does not transit the firewall, so FQDN app-rules should
  work. If name resolution is reconfigured to an external resolver, add/confirm
  the `dns` network rule covers it.
- **Provisioning time:** Azure Firewall takes ~10–15 min to deploy; the route
  table association depends on the firewall's private IP, so a cold `apply`
  serializes on it.
- **NVA management egress unaffected:** NVAs route their own Internet traffic out
  the trust NIC, not the DMZ, so the new DMZ UDR does not touch NVA updates.
