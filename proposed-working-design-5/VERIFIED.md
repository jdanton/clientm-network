# Verification Log

## Status: NOT yet deployed

Done so far:

- `terraform fmt` clean.
- `terraform init` succeeds.
- `terraform validate` passes (azurerm `~> 4.0`).

The inbound half is design-4's NVA pattern (which itself was design-1's
verified iptables/PBR pattern adapted to a single 3-NIC instance). The egress
half is design-2/3's Azure Firewall pattern (live-verified in those designs).
**The novel piece in design-5 is the boundary between them** — specifically:

- Webserver egress hits Azure Firewall, not the NVA. The NVA's iptables
  FORWARD chain therefore never sees egress flows; if it does, the route
  table is wrong.
- The NVA's own outbound (apt during cloud-init) goes via Azure default
  Internet through the untrust NIC's PIP, NOT through Azure Firewall. There
  is no UDR on `snet-untrust`. This avoids the rule-propagation race that
  would otherwise happen for the NVA's apt.

## To verify after `terraform apply`

1. **App Gateway backend is healthy.** Portal → App Gateway → Backend health
   should show the NVA trust IP *Healthy*. If unhealthy, check:
   - NVA: `sudo systemctl is-active nva-firewall.service`
   - NVA: `sudo nva-trace` to inspect iptables + conntrack
   - NSG on snet-trust allows App-GW subnet → NVA trust on :80

2. **Inbound end-to-end** (regression check that the NVA half still works
   without an egress L4 chain):
   ```
   APPGW=$(terraform output -raw appgw_public_ip)
   curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
     https://connect.clientmworkspace.com/healthz          # expect 200
   ```

3. **/whoami** proves the NVA was in the inbound path:
   ```
   curl -sk --resolve connect.clientmworkspace.com:443:$APPGW \
     https://connect.clientmworkspace.com/whoami
   #   remote_addr     = 10.0.3.10  (NVA dmz IP — SNAT proves NVA touched it)
   #   x-forwarded-for = your public IP
   ```

4. **Management SSH + jump:**
   ```
   NVA=$(terraform output -raw nva_public_ip)
   ssh azureuser@$NVA
   ssh -J azureuser@$NVA azureuser@10.0.3.100
   ```

5. **Egress goes through Azure Firewall (not the NVA):**
   ```
   FW=$(terraform output -raw firewall_public_ip)
   # on the webserver:
   curl -s https://api.ipify.org ; echo                     # expect == $FW
   ```
   If the source IP equals the NVA's public IP instead, the DMZ UDR is wrong
   (still pointing at the NVA dmz IP from design-4's pattern).

6. **FQDN allow-list enforces:**
   ```
   curl -s http://azure.archive.ubuntu.com/ -o /dev/null -w '%{http_code}\n'   # expect 200
   curl -s --max-time 10 https://example.com/                                  # expect blocked
   ```

7. **`validate-flows.sh proposed-working-design-5`** — full automated pass.

## Known risks to watch on first deploy

- **Webserver apt race.** Same class of issue design-3 first hit: the firewall
  rule collection can still be propagating when the webserver runs its first
  apt. The webserver cloud-init's apt retry loop (carried over from design-3)
  handles it.
- **NVA boot order.** The NVA's apt does NOT egress through Azure Firewall
  (no UDR on snet-untrust), so the firewall race doesn't affect NVA bring-up.
  If you change that — e.g., to do defense-in-depth by routing NVA egress
  through the firewall too — apply the same retry-loop hardening to the NVA
  cloud-init.
- **App Gateway probe path.** The probe to `/healthz` goes App GW → NVA trust
  → DNAT → webserver → reply back through NVA → App GW. Identical to the
  client traffic path, so a healthy `/healthz` means the whole inbound chain
  is working.
- **The DMZ UDR was design-4's NVA dmz IP and is now the firewall's private
  IP.** Make sure you didn't `terraform apply` design-4 first and inherit
  state — design-5 uses a separate RG (`*-d5`).
