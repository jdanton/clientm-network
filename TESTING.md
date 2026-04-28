# Asymmetric Routing Lab — Testing Guide

## What this lab proves

Active/active NVA pairs behind Azure Standard Load Balancers can silently drop return traffic when the LB hashes the inbound flow and the return flow to **different NVAs**. The NVA that receives return traffic has no conntrack entry for the flow, marks it INVALID, and drops it.

In this lab the trigger is the back LB's **DMZ frontend** (`vip-dmz`, 10.0.3.10). The webserver's default route points here, so return traffic to the App GW re-enters the NVA pool via a separate LB frontend using SourceIP distribution. SourceIP hashes on source IP only — the return source (webserver, 10.0.3.100) hashes independently from the inbound source (App GW, 10.1.1.10), landing on a different NVA ~50% of the time.

---

## Network topology (lab IPs)

```
vnet-appgw-*  10.1.0.0/16
──────────────────────────────────────────────────────────
  App Gateway WAF_v2
    private listener:  10.1.1.10  (snet-appgateway)
    backend pool:      10.0.3.100 (webserver, via peering)
    UDR on subnet:     10.0.0.0/16 → back LB internal (10.0.4.4)

vnet-fw-*  10.0.0.0/16
──────────────────────────────────────────────────────────
  External LB (public)   pip-clientm-lab-front-lb
    rule: TCP 443, floating IP, SourceIP distribution
    backend: NVA eth0 (snet-external 10.0.2.0/24)

  NVA1 / NVA2  —  Linux + iptables (Palo Alto stand-in)
    eth0  snet-external  10.0.2.10 / .11  ← front LB backend
    eth1  snet-internal  10.0.4.10 / .11  ← back LB internal pool
    eth2  snet-dmz       10.0.3.20 / .21  ← back LB DMZ pool  ← BUG LIVES HERE

  Back LB (internal)  lb-clientm-lab-back
    vip-internal  10.0.4.4  → pool: NVA eth1   (inbound from App GW)
    vip-dmz       10.0.3.10 → pool: NVA eth2   (return from webserver)
    both rules: HA Ports, SourceIP distribution, no floating IP

  Webserver  10.0.3.100  snet-dmz
    default route → back LB vip-dmz (10.0.3.10)
```

**Bug path:**
```
App GW (10.1.1.10)
  │ UDR: 10.0.0.0/16 → 10.0.4.4
  ▼
Back LB vip-internal (10.0.4.4)
  │ SourceIP on 10.1.1.10 → NVA-A eth1
  ▼
NVA-A eth1 ──DNAT──▶ Webserver (10.0.3.100)
                          │ default route → 10.0.3.10
                          ▼
                     Back LB vip-dmz (10.0.3.10)
                          │ SourceIP on 10.0.3.100 → NVA-B eth2
                          ▼
                     NVA-B eth2
                          │ no conntrack entry → INVALID → DROP ✗
```

---

## Prerequisites

- `terraform apply` has completed successfully
- Your SSH key is available (`ssh-agent` loaded, or at `~/.ssh/id_rsa`)
- `curl` and `ssh` are in your PATH
- Run commands from the `clientm/` directory

```bash
terraform output   # verify all IPs are populated
```

---

## Quick start

```bash
./test-lab.sh
```

The script runs all five phases automatically and pauses at Phase 4 to let you apply the fix.

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

---

## Phase 1 — Component health checks

| Check | Expected |
|---|---|
| `nva-firewall.service` on both NVAs | `active (exited)` |
| `net.ipv4.ip_forward` on both NVAs | `1` |
| `net.ipv4.conf.eth2.rp_filter` | `0` (DMZ NIC, required for asymmetric observation) |
| `net.netfilter.nf_conntrack_tcp_loose` | `0` (strict — required to reproduce the bug) |
| Webserver `/healthz` from NVA1 | HTTP 200 |
| External LB `/healthz` from internet | 200 or intermittent (bug may already be active) |

**Why `nf_conntrack_tcp_loose=0`:** Linux's default (`loose=1`) accepts mid-stream packets and creates a new conntrack entry. Enterprise firewalls like Palo Alto are strict — they only track flows started with a SYN they saw. With `loose=0`, an unsolicited SYN-ACK gets tagged INVALID and the FORWARD DROP rule drops it.

---

## Phase 2 — Reproduce the bug

```bash
ELB_IP=$(terraform output -raw external_lb_public_ip)

# Flush conntrack for a clean slate
ssh azureuser@$(terraform output -raw nva1_public_ip) 'sudo conntrack -F'
ssh azureuser@$(terraform output -raw nva2_public_ip) 'sudo conntrack -F'

# 50 requests — expect a mix of 200 and 000
for i in $(seq 1 50); do
  curl -sk --max-time 3 -o /dev/null -w "%{http_code}\n" \
    --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
    https://connect.clientmworkspace.com/healthz
done | sort | uniq -c
```

Expected broken output:
```
     26 000
     24 200
```

If all 50 succeed, the LB happened to hash everything to one NVA. Run 200 requests to catch the asymmetry.

---

## Phase 3 — Observe the bug on the NVAs

```bash
NVA1_IP=$(terraform output -raw nva1_public_ip)
NVA2_IP=$(terraform output -raw nva2_public_ip)
WEBSERVER=$(terraform output -raw webserver_ip)

ssh azureuser@${NVA1_IP} 'sudo nva-trace'
ssh azureuser@${NVA2_IP} 'sudo nva-trace'
```

Look at the FORWARD chain. The NVA receiving return traffic it never saw the SYN for will show INVALID drops:

```
Chain FORWARD (policy DROP)
num   pkts bytes target  prot  match
1      421  ...  ACCEPT  all   ctstate ESTABLISHED,RELATED
2       37  ...  DROP    all   ctstate INVALID          ← THIS is the bug
3      180  ...  ACCEPT  tcp   ctstate NEW dport 443
```

Confirm which NVA owns the conntrack entries vs. which is dropping:

```bash
# NVA with entries = handled inbound (NVA-A)
ssh azureuser@${NVA1_IP} "sudo conntrack -L | grep ${WEBSERVER}"

# NVA without entries but with INVALID drops = receiving return traffic (NVA-B)
ssh azureuser@${NVA2_IP} "sudo conntrack -L | grep ${WEBSERVER}"
```

Live packet capture on NVA-B's DMZ NIC (eth2) — this is where return traffic arrives:

```bash
ssh azureuser@${NVA2_IP} \
  "sudo tcpdump -i eth2 -nn 'host ${WEBSERVER} and port 443' -c 30"
```

You'll see TCP packets arriving on eth2 that trigger INVALID → DROP because NVA-B never saw the corresponding SYN on its eth1.

---

## Phase 4 — Apply the fix

### Fix A — NVA SNAT on eth2 (simplest to demonstrate)

With SNAT, the webserver sees the NVA's DMZ IP (10.0.3.20 or .21) as the source instead of the App GW IP. The webserver replies directly to that NVA rather than back through the DMZ LB frontend — symmetric return path, no INVALID drops.

**Steps:**

1. Open [nva.yaml.tftpl](nva.yaml.tftpl)
2. Uncomment the SNAT line in the `# >>> Toggle for the FIX <<<` section:
   ```bash
   iptables -t nat -A POSTROUTING -o eth2 -p tcp --dport 443 -d $WEBSERVER_IP -j MASQUERADE
   ```
3. SSH to both NVAs and re-run the firewall script (no `terraform apply` needed):
   ```bash
   ssh azureuser@${NVA1_IP} 'sudo /usr/local/sbin/nva-firewall.sh'
   ssh azureuser@${NVA2_IP} 'sudo /usr/local/sbin/nva-firewall.sh'
   ```

**Trade-off:** The webserver logs show the NVA's DMZ IP as the client, not the real client IP. Acceptable in many environments, breaks source-IP-based logic.

### Fix B — Gateway Load Balancer (production recommendation)

Not implemented in this repo. Azure's GWLB uses "bump-in-the-wire" semantics — it attaches to the front of another LB's backend and guarantees symmetric flow through the same NVA by using a flow-sticky encapsulation (VXLAN with the same outer header for both directions). See [Azure GWLB docs](https://learn.microsoft.com/en-us/azure/load-balancer/gateway-overview).

---

## Phase 5 — Verify the fix

```bash
# Flush conntrack
ssh azureuser@${NVA1_IP} 'sudo conntrack -F'
ssh azureuser@${NVA2_IP} 'sudo conntrack -F'

# 50 requests — all should return 200
for i in $(seq 1 50); do
  curl -sk --max-time 5 -o /dev/null -w "%{http_code}\n" \
    --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
    https://connect.clientmworkspace.com/healthz
done | sort | uniq -c
```

Expected fixed output:
```
     50 200
```

Confirm INVALID drops are no longer incrementing:

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

# Watch INVALID drops in real time on NVA2's DMZ NIC
ssh azureuser@$(terraform output -raw nva2_public_ip) \
  'watch -n1 "sudo iptables -L FORWARD -v -n | grep -E \"DROP|INVALID\""'

# Live conntrack events on NVA1
ssh azureuser@$(terraform output -raw nva1_public_ip) \
  'sudo conntrack -E -p tcp --dport 443'

# Test via external LB
ELB_IP=$(terraform output -raw external_lb_public_ip)
curl -kv --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
  https://connect.clientmworkspace.com/healthz

# Packet capture on NVA2 eth2 (DMZ NIC — return traffic lands here)
ssh azureuser@$(terraform output -raw nva2_public_ip) \
  "sudo tcpdump -i eth2 -nn 'port 443' -c 50"
```

---

## Cleanup

```bash
terraform destroy
```

The App Gateway (WAF_v2) accounts for most of the cost (~$0.44/hr). Destroy between sessions.
