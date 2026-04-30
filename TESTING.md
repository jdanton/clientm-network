# Asymmetric Routing Lab — Testing Guide

## What this lab proves

In the production topology, the App Gateway is **NATed behind the firewalls**:
clients hit the front LB, the NVAs DNAT inbound 443 to the App GW's private
listener. The App GW's backend pool is the webserver, which it reaches
**directly via VNet peering** — no NVA on the way in.

The asymmetry is on the **App-GW → webserver leg**:
- **Inbound** (App GW → webserver): direct via peering, NVAs absent
- **Return** (webserver → App GW): forced through the back LB DMZ frontend by
  the webserver's default route → NVA eth2

The NVA that the DMZ LB hashes the webserver's reply to has no conntrack entry
for the App-GW→webserver flow — the original SYN never came through it. With
`nf_conntrack_tcp_loose=0`, the kernel marks the SYN-ACK INVALID and the
FORWARD chain drops it. App GW's backend probe then fails, and the front LB's
probe (which DNATs through to App GW) fails the same way → 502 / timeout to
clients. In the prod portal this shows as the front LB's App-GW frontend at
0% data-path availability.

---

## Network topology (lab IPs)

```
vnet-appgw-*  10.1.0.0/16
──────────────────────────────────────────────────────────
  App Gateway WAF_v2
    private listener: 10.1.1.10  (snet-appgateway)
    backend pool:     10.0.3.100 (webserver, reached DIRECTLY via VNet peering)
    NO UDR forcing 10.0.0.0/16 through the firewalls — that's the asymmetry

vnet-fw-*  10.0.0.0/16
──────────────────────────────────────────────────────────
  Front LB (public)  pip-clientm-lab-front-lb
    rule: TCP 443, floating IP, SourceIP distribution
    backend: NVA eth0 (snet-external 10.0.2.0/24)

  NVA1 / NVA2  —  Linux + iptables (Palo Alto stand-in)
    eth0  snet-external  10.0.2.10 / .11   ← front LB backend
                                            DNAT :443 → 10.1.1.10 (App GW)
    eth1  snet-internal  10.0.4.10 / .11   ← App-GW egress, SNAT to eth1 IP
    eth2  snet-dmz       10.0.3.20 / .21   ← back LB DMZ pool ← BUG LIVES HERE

  Back LB (internal)  lb-clientm-lab-back
    vip-internal  10.0.4.4   → pool: NVA eth1   (unused in this topology)
    vip-dmz       10.0.3.10  → pool: NVA eth2   (webserver return path)
    DMZ rule: HA Ports, SourceIP distribution, floating_ip_enabled=true (lab)

  Webserver  10.0.3.100  snet-dmz
    default route → back LB vip-dmz (10.0.3.10)
    Sees connections from App GW (10.1.1.10) via peering
```

**Bug path:**
```
Client ──▶ Front LB ──▶ NVA-X eth0
                          │ DNAT :443 → 10.1.1.10
                          │ SNAT eth1 → NVA-X eth1 IP
                          ▼
                        App Gateway listener (10.1.1.10)
                          │ backend: 10.0.3.100
                          │ goes DIRECTLY via VNet peering (no NVA)
                          ▼
                        Webserver (10.0.3.100)
                          │ replies to App GW: src=10.0.3.100 dst=10.1.1.10
                          │ default route 0.0.0.0/0 → 10.0.3.10
                          ▼
                        Back LB vip-dmz (10.0.3.10)
                          │ SourceIP hash on 10.0.3.100 → NVA-Y eth2
                          ▼
                        NVA-Y eth2
                          │ NVA-Y has NO conntrack for App-GW→webserver flow
                          │ (no NVA was on the inbound leg — peering bypass)
                          │ nf_conntrack_tcp_loose=0 → INVALID → DROP ✗
                          ▼
                        App GW probe / client connection times out → 502
```

---

## Prerequisites

- `terraform apply` completed successfully
- SSH key available — script auto-uses `~/.ssh/milbank_lab` if present
- `curl` and `ssh` in your PATH
- Run from the `clientm/` directory

```bash
terraform output   # verify all IPs are populated
```

---

## Quick start

```bash
./test-lab.sh
```

Runs all five phases automatically and pauses at Phase 4 to apply the fix.

```bash
./test-lab.sh --phase 3   # observation only
./test-lab.sh --phase 5   # verify fix (after applying)
./test-lab.sh --wait      # poll until VMs are SSH-reachable
```

---

## Phase 0 — Wait for VMs

Cloud-init takes 2–4 minutes after VMs become reachable. Watch it finish:

```bash
ssh azureuser@$(terraform output -raw nva1_public_ip) \
  'sudo tail -f /var/log/cloud-init-output.log'
```

If you re-applied with new cloud-init (e.g. after the topology refactor), the
running NVAs need to be recreated to pick up the new template — `terraform`
won't re-run cloud-init on a `custom_data` change alone:

```bash
terraform taint 'azurerm_linux_virtual_machine.nva["nva1"]'
terraform taint 'azurerm_linux_virtual_machine.nva["nva2"]'
terraform apply
```

---

## Phase 1 — Component health checks

| Check | Expected |
|---|---|
| `nva-firewall.service` on both NVAs | `active (exited)` |
| `net.ipv4.ip_forward` on both NVAs | `1` |
| `net.ipv4.conf.eth2.rp_filter` | `0` (DMZ NIC, required for asymmetric observation) |
| `net.netfilter.nf_conntrack_tcp_loose` | `0` (strict — required to reproduce the bug) |
| Webserver `/healthz` from NVA1 (direct via eth2) | HTTP 200 |
| App GW listener from NVA1 (eth1 → peering) | HTTP 200 if not yet broken, 502 once probe fails |
| External LB `/healthz` from internet | 200 or timeout (bug may already be active) |

**Why `nf_conntrack_tcp_loose=0`:** Linux's default (`loose=1`) accepts mid-stream packets and creates a new conntrack entry. Enterprise firewalls like Palo Alto are strict — they only track flows started with a SYN they saw. With `loose=0`, the unsolicited SYN-ACK from the webserver gets tagged INVALID and the FORWARD DROP rule drops it.

---

## Phase 2 — Reproduce the bug

```bash
ELB_IP=$(terraform output -raw external_lb_public_ip)

ssh azureuser@$(terraform output -raw nva1_public_ip) 'sudo conntrack -F'
ssh azureuser@$(terraform output -raw nva2_public_ip) 'sudo conntrack -F'

# 50 requests — expect mostly timeouts once the App GW marks its backend unhealthy
for i in $(seq 1 50); do
  curl -sk --max-time 3 -o /dev/null -w "%{http_code}\n" \
    --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
    https://connect.clientmworkspace.com/healthz
done | sort | uniq -c
```

Expected broken output (varies; depends on probe history):
```
     50 000        # all timeouts — App GW marked backend unhealthy, returns 502
```
or
```
     34 502
     16 000
```

The exact mix depends on whether App GW has already marked the webserver
backend unhealthy from prior probe failures. Once that happens, App GW returns
502 immediately; some flows time out at front LB if its NVA-pool probe also
failed.

---

## Phase 3 — Observe the bug on the NVAs

```bash
NVA1_IP=$(terraform output -raw nva1_public_ip)
NVA2_IP=$(terraform output -raw nva2_public_ip)
APPGW=$(terraform output -raw appgw_private_ip)
WEBSERVER=$(terraform output -raw webserver_ip)

ssh azureuser@${NVA1_IP} 'sudo nva-trace'
ssh azureuser@${NVA2_IP} 'sudo nva-trace'
```

In the FORWARD chain, **one** NVA will show INVALID drops:

```
Chain FORWARD (policy DROP)
num   pkts bytes target  prot  match
1      120  ...  ACCEPT  all   ctstate ESTABLISHED,RELATED
2       80  ...  DROP    all   ctstate INVALID          ← THIS is the bug
3       40  ...  ACCEPT  tcp   ctstate NEW dport 443 dst ${APPGW}
```

Confirm conntrack state:

```bash
# Both NVAs may have client→AppGW flows (from Phase 2 traffic).
# NEITHER should have App-GW→webserver flows — that leg goes via peering, not through any NVA.
ssh azureuser@${NVA1_IP} "sudo conntrack -L | grep -E '${APPGW}|${WEBSERVER}'"
ssh azureuser@${NVA2_IP} "sudo conntrack -L | grep -E '${APPGW}|${WEBSERVER}'"
```

Live capture of the dropped SYN-ACKs on eth2 — try both NVAs, only one will see traffic (whichever the DMZ LB hashes the webserver to):

```bash
ssh azureuser@${NVA1_IP} \
  "sudo tcpdump -i eth2 -nn 'host ${WEBSERVER} and host ${APPGW}' -c 30"

ssh azureuser@${NVA2_IP} \
  "sudo tcpdump -i eth2 -nn 'host ${WEBSERVER} and host ${APPGW}' -c 30"
```

You'll see TCP packets from `${WEBSERVER}.443` → `${APPGW}.<rand>` arriving on eth2 that trigger INVALID → DROP.

---

## Phase 4 — Apply a fix

The asymmetry is between two paths:
- **App GW → webserver**: direct via VNet peering (no NVA)
- **Webserver → App GW**: through DMZ LB → NVA eth2

Three ways to make them match:

### Option A — Make the return symmetric (drop the DMZ UDR)

Either:

- **Permanent** — remove the `azurerm_route_table.dmz` route in [route-tables.tf](route-tables.tf), then `terraform apply`. The webserver subnet's effective default becomes Azure's system route, so replies to App GW go back via VNet peering — same direct path App GW used inbound.

- **Live demo on the running webserver** (test-lab.sh Phase 4 does this automatically):
  ```bash
  WEBSERVER=$(terraform output -raw webserver_ip)
  NVA1_IP=$(terraform output -raw nva1_public_ip)
  ssh -J azureuser@${NVA1_IP} azureuser@${WEBSERVER} \
    "sudo ip route del default 2>/dev/null; \
     sudo ip route add default via 10.0.3.1 && ip route show default"
  ```
  This swaps the OS default route to the subnet gateway, bypassing the UDR. Reverts on webserver reboot.

**Trade-off:** The firewalls no longer see App-GW→webserver traffic, defeating the security posture. Useful for proving the fix works; not what you'd ship.

### Option B — Make the inbound symmetric (route App-GW→webserver through NVAs)

Restore an AppGW-subnet UDR forcing `10.0.0.0/16` → back LB internal frontend (10.0.4.4). App-GW→webserver then goes through an NVA (eth1), creating conntrack, and the return via DMZ LB will match.

**Catch:** The back LB internal rule has `enable_floating_ip = false` (matches prod). Without floating IP, the LB rewrites destination to NVA's eth1 IP and the packet ends up on the NVA's INPUT chain instead of FORWARD. To make this work on Linux NVAs you need either:
- `enable_floating_ip = true` on the internal rule, or
- An eth1:443 PREROUTING DNAT to the webserver

Production Palo Altos handle this natively via session-table forwarding regardless of destination IP — Linux netfilter doesn't.

### Option C — Azure Gateway Load Balancer

The Microsoft-recommended pattern. GWLB uses "bump-in-the-wire" semantics with VXLAN encapsulation that guarantees symmetric flow through the same NVA in both directions. Not implemented in this repo. See [Azure GWLB docs](https://learn.microsoft.com/en-us/azure/load-balancer/gateway-overview).

---

## Phase 5 — Verify the fix

```bash
# Flush conntrack
ssh azureuser@${NVA1_IP} 'sudo conntrack -F'
ssh azureuser@${NVA2_IP} 'sudo conntrack -F'

# Wait ~30s for App GW backend probe to recover
sleep 30

# 50 requests — all should return 200
for i in $(seq 1 50); do
  curl -sk --max-time 5 -o /dev/null -w "%{http_code}\n" \
    --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
    https://connect.clientmworkspace.com/healthz
done | sort | uniq -c
```

Expected:
```
     50 200
```

The INVALID drop counter should stop incrementing:

```bash
ssh azureuser@${NVA1_IP} 'sudo iptables -L FORWARD -v -n'
ssh azureuser@${NVA2_IP} 'sudo iptables -L FORWARD -v -n'
```

---

## Useful one-liners

```bash
# All IPs at once
terraform output

# SSH to NVA1 / NVA2
ssh azureuser@$(terraform output -raw nva1_public_ip)
ssh azureuser@$(terraform output -raw nva2_public_ip)

# Watch INVALID drops in real time on NVA2
ssh azureuser@$(terraform output -raw nva2_public_ip) \
  'watch -n1 "sudo iptables -L FORWARD -v -n | grep -E \"DROP|INVALID\""'

# Live conntrack events on NVA1 (filter for App GW or webserver)
APPGW=$(terraform output -raw appgw_private_ip)
WEBSERVER=$(terraform output -raw webserver_ip)
ssh azureuser@$(terraform output -raw nva1_public_ip) \
  "sudo conntrack -E -p tcp 2>/dev/null | grep -E '${APPGW}|${WEBSERVER}'"

# Test via front LB
ELB_IP=$(terraform output -raw external_lb_public_ip)
curl -kv --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
  https://connect.clientmworkspace.com/healthz

# Test via App GW public frontend (skips the front LB / NVA path)
APPGW_PUB=$(terraform output -raw appgw_public_ip)
curl -kv --resolve "connect.clientmworkspace.com:443:${APPGW_PUB}" \
  https://connect.clientmworkspace.com/healthz

# Packet capture on NVA2 eth2 — the dropped SYN-ACKs land here
ssh azureuser@$(terraform output -raw nva2_public_ip) \
  "sudo tcpdump -i eth2 -nn 'host ${WEBSERVER} and host ${APPGW}' -c 50"

# Webserver-side: drop the UDR-installed default route (Option A live)
ssh -J azureuser@$(terraform output -raw nva1_public_ip) \
    azureuser@$(terraform output -raw webserver_ip) \
  'sudo ip route del default 2>/dev/null; sudo ip route add default via 10.0.3.1; ip route show default'
```

---

## Cleanup

```bash
terraform destroy
```

The App Gateway (WAF_v2) accounts for most of the cost (~$0.44/hr). Destroy between sessions.
