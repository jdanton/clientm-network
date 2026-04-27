# Asymmetric Routing Lab — Testing Guide

## What this lab proves

The lab reproduces a real production incident: an active/active firewall pair (NVA1 and NVA2) sitting behind an Azure Standard Load Balancer drops return traffic intermittently because the internal LB hashes reply flows to a different NVA than the one that handled the original connection. That NVA has no conntrack entry, marks the packet INVALID, and drops it.

---

## Network topology

```
Internet
    │
    ▼
Public IP  (pip-clientm-lab-front-lb)
    │
    ▼
External LB  (lb-clientm-lab-front)   ← Standard SKU, TCP 443, 5-tuple hash
    │ distributes across both NVAs' external NICs
    ├──────────────────────┐
    ▼                      ▼
  NVA1 (eth0)           NVA2 (eth0)       ← snet-external 10.0.2.0/24
  NVA1 (eth1)           NVA2 (eth1)       ← snet-internal 10.0.4.0/24
    │                      │
    └──────────┬───────────┘
               ▼
        Internal LB  (lb-clientm-lab-back)   ← BROKEN: per-port TCP, no HA Ports
               │  or
               │  FIXED: HA Ports + floating IP (all ports, any proto)
               ▼
         Webserver  (snet-dmz 10.0.3.0/24)
               │
               │ default route → internal LB frontend (10.0.4.4)
               │ reply traffic re-enters the internal LB
               ▼
        (same LB, re-hashes)  ←── THIS is the bug: return flow may land on the
                                   *other* NVA, which has no conntrack state
```

Additionally, an Application Gateway (WAF_v2) sits in `snet-appgateway 10.0.1.0/24` with:
- Public frontend for external access
- Private frontend (10.0.1.10) that the NVAs DNAT inbound HTTPS to
- Backend pool pointing at the webserver
- Route table forcing AppGW→webserver traffic through the internal LB (same path, same bug)

---

## Prerequisites

- `terraform apply` has completed successfully (35 resources created)
- Your SSH key is available (`ssh-agent` loaded, or at `~/.ssh/id_rsa`)
- `curl` and `ssh` are in your PATH
- You are running commands from the `clientm/` directory

Verify terraform outputs are populated:
```bash
terraform output
```

---

## Quick start

```bash
./test-lab.sh
```

The script runs all five phases automatically and pauses at Phase 4 to let you make the code change before applying the fix.

To jump to a specific phase:
```bash
./test-lab.sh --phase 3   # just run the observation phase
./test-lab.sh --phase 5   # just verify the fix (after applying)
```

To poll until VMs are SSH-reachable (useful right after `terraform apply`):
```bash
./test-lab.sh --wait
```

---

## Phase-by-phase breakdown

### Phase 0 — Wait for VMs

Cloud-init takes 2–4 minutes after the VMs become reachable. The script polls SSH on both NVA public IPs until they respond, then proceeds.

If cloud-init is still running when you SSH in, watch it finish:
```bash
ssh azureuser@<NVA1_IP> 'sudo tail -f /var/log/cloud-init-output.log'
```

---

### Phase 1 — Component health checks

The script verifies:

| Check | Expected |
|---|---|
| `nva-firewall.service` on both NVAs | `active (exited)` |
| `net.ipv4.ip_forward` on both NVAs | `1` |
| `net.netfilter.nf_conntrack_tcp_loose` | `0` (strict — required to reproduce the bug) |
| Webserver `/healthz` from NVA1 internal NIC | HTTP 200 |
| External LB `/healthz` from the internet | HTTP 200 or intermittent (bug may already be active) |

**Key sysctl: `nf_conntrack_tcp_loose=0`**

Linux's default conntrack mode (`loose=1`) accepts mid-stream packets and creates a new conntrack entry for them. Enterprise firewalls like Palo Alto are strict: they only track flows that started with a SYN they processed. Setting `loose=0` on the NVAs makes them behave the same way — an unsolicited return packet gets no conntrack entry, is tagged `INVALID`, and the `FORWARD DROP` rule drops it.

---

### Phase 2 — Reproduce the bug

The script:
1. Flushes conntrack on both NVAs (clean slate)
2. Sends 20 HTTPS requests through the external LB
3. Reports how many fail

You should see intermittent `X` failures. The failure rate depends on how the LB hashes flows; with only two NVAs it's roughly 50% of sessions that route asymmetrically.

If all 20 succeed, the LB happened to hash everything to one NVA. Run the longer loop printed by the script (100 requests) to catch the asymmetry.

Manual equivalent:
```bash
ELB_IP=$(terraform output -raw external_lb_public_ip)
for i in $(seq 1 50); do
  curl -sk --max-time 3 -o /dev/null -w "%{http_code}\n" \
    --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
    https://connect.clientmworkspace.com/healthz
done | sort | uniq -c
```

Expected broken output: a mix of `200` and `000` (connection timeout/reset).

---

### Phase 3 — Observe the bug on the NVAs

SSH to both NVAs and run `sudo nva-trace` to see the iptables counters:

```bash
NVA1_IP=$(terraform output -raw nva1_public_ip)
NVA2_IP=$(terraform output -raw nva2_public_ip)

ssh azureuser@${NVA1_IP} 'sudo nva-trace'
ssh azureuser@${NVA2_IP} 'sudo nva-trace'
```

What to look for in the `FORWARD` chain output:

```
Chain FORWARD (policy DROP)
num   pkts bytes target  prot  ...  match
1      421  ...  ACCEPT  all   ...  ctstate ESTABLISHED,RELATED
2       37  ...  DROP    all   ...  ctstate INVALID          ← THIS is the bug
3      180  ...  ACCEPT  tcp   ...  ctstate NEW, dport 443
```

The NVA with INVALID drops is the one receiving return traffic it never saw the SYN for. The other NVA will have conntrack entries for the same flows:

```bash
# On NVA1 — look for the webserver's IP in conntrack
WEBSERVER_IP=$(terraform output -raw webserver_ip)
ssh azureuser@${NVA1_IP} "sudo conntrack -L | grep ${WEBSERVER_IP}"

# On NVA2 — same
ssh azureuser@${NVA2_IP} "sudo conntrack -L | grep ${WEBSERVER_IP}"
```

The NVA without conntrack entries for `${WEBSERVER_IP}` is the one being bypassed by the inbound flow but hit by the return flow.

Live packet capture on the "wrong" NVA:
```bash
ssh azureuser@${NVA2_IP} "sudo tcpdump -i any -nn 'host ${WEBSERVER_IP} and port 443' -c 50"
```

You will see TCP packets arriving on `eth1` with no corresponding conntrack entry.

---

### Phase 4 — Apply the fix

Two fixes exist. Pick one.

#### Fix A — Internal LB HA Ports (recommended)

This mirrors the Azure Gateway Load Balancer (GWLB) pattern. HA Ports means the LB forwards **all ports and protocols** based on 5-tuple, with `floating_ip_enabled = true` so the destination IP is preserved as the NVA internal IP rather than the LB frontend. The result: inbound and return flows hash identically.

**Steps:**

1. Open [internal-lb.tf](internal-lb.tf)
2. Comment out the broken rule (lines 55–66):
   ```hcl
   # resource "azurerm_lb_rule" "internal_443" { ... }
   ```
3. Uncomment the fixed rule (lines 73–84):
   ```hcl
   resource "azurerm_lb_rule" "internal_haports" {
     ...
     protocol           = "All"
     frontend_port      = 0
     backend_port       = 0
     floating_ip_enabled = true
     ...
   }
   ```
4. Apply:
   ```bash
   terraform apply -auto-approve
   ```

No VM restart required — the LB rule change takes effect immediately.

#### Fix B — NVA-side SNAT

Instead of fixing the LB, you can make the NVA SNAT the webserver-bound traffic to its own internal NIC IP. The webserver then replies directly to that NVA (not through the LB), forcing symmetric return.

**Steps:**

1. Open [nva.yaml.tftpl](nva.yaml.tftpl)
2. Uncomment line 117:
   ```bash
   iptables -t nat -A POSTROUTING -o eth1 -p tcp --dport 443 -d $WEBSERVER_IP -j MASQUERADE
   ```
3. SSH to both NVAs and re-run the firewall script:
   ```bash
   ssh azureuser@${NVA1_IP} 'sudo /usr/local/sbin/nva-firewall.sh'
   ssh azureuser@${NVA2_IP} 'sudo /usr/local/sbin/nva-firewall.sh'
   ```

No terraform apply needed — you're changing the iptables rules directly.

**Trade-off**: Fix B hides the client's original IP from the webserver (it sees the NVA internal IP). Fix A preserves the original client IP, which is why it's preferred in production.

---

### Phase 5 — Verify the fix

```bash
./test-lab.sh --phase 5
```

Or manually:
```bash
ELB_IP=$(terraform output -raw external_lb_public_ip)

# Flush conntrack so we start clean
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

Check that INVALID drop counters are now zero (or not incrementing):
```bash
ssh azureuser@${NVA1_IP} 'sudo iptables -L FORWARD -v -n'
ssh azureuser@${NVA2_IP} 'sudo iptables -L FORWARD -v -n'
```

---

## Useful one-liners

```bash
# Get all IPs at once
terraform output

# SSH to NVA1
ssh azureuser@$(terraform output -raw nva1_public_ip)

# SSH to NVA2
ssh azureuser@$(terraform output -raw nva2_public_ip)

# Live conntrack watch on NVA1 (updates every 2s)
ssh azureuser@$(terraform output -raw nva1_public_ip) \
  'watch -n2 "sudo conntrack -L 2>/dev/null | grep $(terraform output -raw webserver_ip || echo 10.0.3.10)"'

# Test AppGW public frontend (goes through AppGW → NVA path)
curl -kv --resolve "connect.clientmworkspace.com:443:$(terraform output -raw appgw_public_ip)" \
  https://connect.clientmworkspace.com/healthz

# Test /whoami to see which NVA handled the request
curl -sk --resolve "connect.clientmworkspace.com:443:$(terraform output -raw external_lb_public_ip)" \
  https://connect.clientmworkspace.com/whoami

# Watch iptables INVALID drops in real time on NVA2
ssh azureuser@$(terraform output -raw nva2_public_ip) \
  'watch -n1 "sudo iptables -L FORWARD -v -n | grep -E \"DROP|INVALID\""'
```

---

## Cleanup

```bash
terraform destroy
```

The App Gateway (WAF_v2) accounts for most of the cost (~$0.44/hr). Destroy between test sessions if you are not actively using the lab.
