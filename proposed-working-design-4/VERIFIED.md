# Verification Log

## Status: NOT yet deployed

Done so far:

- `terraform fmt` clean.
- `terraform init` succeeds (azurerm `~> 4.0`).
- `terraform validate` passes.

The inbound design copies design-1's verified NVA pattern almost verbatim
(NIC detect by subnet, per-NIC PBR, DNAT on the App-GW-facing NIC, SNAT on the
webserver-facing NIC) so that half carries design-1's confidence. The **egress
half is new**: a third NIC (`untrust`), an iptables FORWARD allow-list for
DMZ-sourced traffic, MASQUERADE on the untrust NIC, and forcing the main
routing table's default route via untrust. That hasn't been live yet — it's
the part to validate first.

## To verify after `terraform apply`

1. **App Gateway backend is healthy through the NVA's DNAT.** Portal → App
   Gateway → Backend health should show the NVA trust IP as *Healthy*. If
   *Unhealthy*, the `/healthz` probe isn't completing through the NVA — check:
   - NVA: `sudo systemctl is-active nva-firewall.service`
   - NVA: `sudo nva-trace` to see iptables and conntrack
   - NSG on trust allows App-GW-subnet → NVA-trust on :80

2. **Inbound end-to-end:**
   ```
   APPGW=$(terraform output -raw appgw_public_ip)
   curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
     https://connect.clientmworkspace.com/healthz          # expect 200 OK
   ```

3. **/whoami proves the NVA was in the inbound path:**
   ```
   curl -sk --resolve connect.clientmworkspace.com:443:$APPGW \
     https://connect.clientmworkspace.com/whoami
   #   remote_addr     = 10.0.3.10  (NVA dmz IP — SNAT proves traffic crossed the NVA)
   #   x-forwarded-for = your public IP
   ```

4. **Management SSH + jump to webserver:**
   ```
   NVA=$(terraform output -raw nva_public_ip)
   ssh azureuser@$NVA                                       # NVA shell
   ssh -J azureuser@$NVA azureuser@10.0.3.100               # webserver
   ```

5. **Egress SNAT proof — webserver's source IP == NVA public IP:**
   ```
   # on the webserver:
   curl -s https://api.ipify.org ; echo                     # expect == nva_public_ip
   ```

6. **L4 allow-list — allowed port (80) succeeds, non-allowed port (25) blocked:**
   ```
   curl -s http://azure.archive.ubuntu.com/ -o /dev/null -w '%{http_code}\n'                       # expect 200
   curl --connect-timeout 8 -s -o /dev/null -w '%{http_code}\n' http://example.com:25/             # expect 000
   ```

7. **`validate-flows.sh proposed-working-design-4`** — full automated pass.

## Known risks to watch on first deploy

- **Three default routes from DHCP.** Each NIC's DHCP lease installs a default
  route; we delete all of them and add one via the untrust gateway. If the
  NVA's outbound suddenly stops working post-deploy, suspect a DHCP renewal
  re-installing a default via the wrong NIC. The fix is the cloud-init's
  `while ip route show default | grep -q '^default'; do ip route del default; done`
  loop — re-running `/usr/local/sbin/nva-firewall.sh` rebuilds state.
- **NIC ordering.** Linux's `ethN` numbering follows MAC/PCI, not the order in
  `network_interface_ids`. `nva.yaml.tftpl` detects each NIC by which subnet
  its IP belongs to — never trust the eth name. `sudo nva-trace` shows the
  resolved mapping.
- **App GW backend on a single VM.** No LB to take an unhealthy NVA out of
  rotation — if the NVA falls over, backend health goes red and clients see
  502 immediately. This is the single-NVA SPOF documented in EXPLANATION.md.
