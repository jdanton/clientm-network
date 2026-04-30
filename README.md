# Clientm Asymmetric Routing Lab

A Terraform reproduction of the Clientm Azure network topology for isolating and proving the asymmetric routing bug. Mirrors the production design from the App Gateway and load balancer configs: external LB → active/active NVA pair → App Gateway WAF_v2 → webserver, with the NVAs' return path going through a separate DMZ LB frontend.

## What this is (and isn't)

**Is:** a cheap, broken-by-default reproduction of the routing problem so you can prove the failure mode and validate fixes without touching the production environment.

**Isn't:** a Palo Alto deployment. Palo Alto VMs in Azure are ~$1.50/hr just for licensing. This uses **Linux + iptables** to provide the same stateful-firewall semantics that drive the asymmetric routing bug. The bug is a property of stateful firewalls + load balancer hashing, not of Palo Alto specifically — iptables reproduces it faithfully.

## Cost estimate (running 24/7, US East)

| Resource | Approx. monthly |
|---|---|
| 2x NVA VMs (B2s) | ~$60 |
| 1x Webserver VM (B2s) | ~$30 |
| 3x OS disks (Standard HDD 30 GB) | ~$5 |
| 3x Public IPs (Standard) | ~$11 |
| External Standard LB | ~$18 |
| Internal Standard LB | ~$18 |
| **App Gateway WAF_v2** (idle, min=0) | **~$320** |
| **Total** | **~$462/mo** |

The App Gateway is the cost dominator. **Run `terraform destroy` between test sessions** — bringing the lab back up takes about 8–10 minutes and saves ~$10/day.

If you only need to reproduce the asymmetric routing bug (not the full App GW path), you can comment out `appgateway.tf` and drop the cost to ~$142/month.

## Topology

Two VNets, matching production:

```
┌─────────────────────────────────────────────────────────────────┐
│  vnet-fw-*  (10.0.0.0/16)  —  firewall transit                  │
│                                                                  │
│              Internet                                            │
│                  │                                               │
│         ┌────────┴────────┐                                      │
│         │  External LB    │  public, floating IP, SourceIP hash  │
│         └───┬─────────┬───┘                                      │
│             │         │                                           │
│          ┌──┴──┐   ┌──┴──┐                                       │
│          │NVA1 │   │NVA2 │  Linux + iptables                     │
│          │eth0 │   │eth0 │  snet-external 10.0.2.0/24            │
│          │eth1 │   │eth1 │  snet-internal 10.0.4.0/24            │
│          │eth2 │   │eth2 │  snet-dmz      10.0.3.0/24            │
│          └──┬──┘   └──┬──┘                                       │
│  eth1 pool  └────┬────┘  eth2 pool                               │
│                  │                                               │
│    ┌─────────────┴──────────────┐                                │
│    │     Back LB (internal)     │                                │
│    │  vip-internal  10.0.4.4    │ ← App GW → webserver inbound  │
│    │  vip-dmz       10.0.3.10   │ ← webserver return path       │
│    └────────────────────────────┘                                │
│                  │ (back LB vip-dmz → NVA eth2)                  │
│         ┌────────┴────────┐                                      │
│         │   Webserver     │  10.0.3.100, snet-dmz                │
│         │   nginx/healthz │  default route → 10.0.3.10           │
│         └─────────────────┘                                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                         │ VNet peering
┌────────────────────────┴────────────────────────────────────────┐
│  vnet-appgw-*  (10.1.0.0/16)  —  App Gateway                    │
│                                                                  │
│         ┌─────────────────┐                                      │
│         │  App Gateway    │  private listener 10.1.1.10          │
│         │  WAF_v2         │  backend: 10.0.3.100 (webserver)     │
│         └─────────────────┘  UDR: 10.0.0.0/16 → back LB 10.0.4.4│
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### The bug path

The App Gateway is **NATed behind the firewalls** — clients hit the front LB,
the NVAs DNAT inbound 443 to the App GW's private listener. App GW's backend
pool is the webserver, which it reaches **directly via VNet peering** (no NVA
on the way in). The asymmetry is on the **App-GW → webserver** leg:

```
Client ──▶ Front LB ──▶ NVA-X eth0
                          │ DNAT :443 → AppGW (10.1.1.10)
                          │ SNAT eth1 → NVA-X eth1 IP
                          ▼
                       App Gateway (10.1.1.10, listener)
                          │ backend pool = webserver
                          │ reaches webserver DIRECTLY via VNet peering
                          ▼
                       Webserver (10.0.3.100)
                          │ replies to App GW (src=10.0.3.100, dst=10.1.1.10)
                          │ DMZ default route → 10.0.3.10
                          ▼
                       Back LB vip-dmz (10.0.3.10)
                          │ SourceIP hash on 10.0.3.100 → NVA-Y eth2
                          ▼
                       NVA-Y eth2
                          │ no conntrack entry — NVA-Y never saw the inbound
                          │ App-GW→webserver flow (it bypassed all NVAs)
                          │ nf_conntrack_tcp_loose=0 → INVALID → DROP
                          ▼
                       ✗ webserver replies vanish → App GW backend probe fails
                         → front LB probe to App-GW-via-NVA also fails
                         → 502 / timeout to client
```

The front LB's data-path availability for the App-GW frontend goes to 0% in
production because the probe path has the same asymmetry: the SYN-ACK reply
from App GW is taking a path that doesn't go back through the NVA that did
the DNAT.

## Prerequisites

- Terraform ≥ 1.5
- Azure CLI logged in (`az login`) with Contributor on a subscription
- An SSH keypair (`ssh-keygen -t ed25519` if you don't have one)
- Your public IP (`curl ifconfig.me`)

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — paste your SSH public key and your public IP /32

terraform init
terraform plan
terraform apply
```

First apply takes ~8–10 minutes (App Gateway is the slow one).

## Reproducing the bug

After `apply` settles, the lab is **broken by default** — no configuration changes needed.

```bash
FRONT_LB=$(terraform output -raw external_lb_public_ip)

# Send requests through the external LB — you'll see intermittent failures
for i in $(seq 1 50); do
  curl -sk --max-time 3 -o /dev/null -w "%{http_code}\n" \
    --resolve "connect.clientmworkspace.com:443:${FRONT_LB}" \
    https://connect.clientmworkspace.com/healthz
done | sort | uniq -c
```

Expected broken output: a mix of `200` and `000` (timeout/reset).

To see exactly where it dies, SSH to both NVAs and run `sudo nva-trace`. The NVA receiving return traffic without a conntrack entry will show incrementing INVALID drops in the FORWARD chain.

## Applying a fix

The asymmetry is between two paths:
- **App GW → webserver**: direct via VNet peering (no NVA)
- **Webserver → App GW**: through DMZ LB → NVA eth2

Two ways to make the return path match the (NVA-bypass) inbound path:

**Option A — Drop the DMZ UDR.** Remove the webserver subnet's `0.0.0.0/0 → 10.0.3.10` route in [route-tables.tf](route-tables.tf). The webserver's reply to App GW then goes back via VNet peering, the same direct path App GW used inbound. Symmetric, no NVA in either direction. **Trade-off:** the firewalls no longer see App-GW-to-webserver traffic — defeats the security model.

**Option B — Make the inbound path go through the NVAs too.** Restore an AppGW-subnet UDR forcing `10.0.0.0/16 → back LB internal frontend (10.0.4.4)`. App-GW-to-webserver then goes through an NVA, which gets a conntrack entry, and the return via DMZ LB will match. *Catch:* the back LB internal rule has `enable_floating_ip = false` (matches prod), so packet dst gets rewritten to NVA-eth1-IP, hitting the local INPUT chain instead of FORWARD — needs eth1:443 DNAT or floating IP enabled to function on Linux NVAs. Production Palo Altos handle this natively.

**Option C — Gateway Load Balancer.** The Microsoft-recommended pattern. Not implemented in this repo; see the [Azure GWLB docs](https://learn.microsoft.com/en-us/azure/load-balancer/gateway-overview).

## WAF mode

The lab WAF policy is in **Detection** mode so false positives don't obscure the routing debug. Once routing works, flip `mode` in `appgateway.tf` to `"Prevention"` to mirror production.

## Tearing down

```bash
terraform destroy
```

App Gateway takes 5–7 minutes to delete.

## File map

| File | Purpose |
|---|---|
| `versions.tf` | Provider pins (azurerm ~> 4.0) |
| `variables.tf` | All inputs with defaults matching the prod IP plan |
| `main.tf` | Resource group, 2x VNets (fw + appgw), bidirectional peering |
| `network-security.tf` | NSGs (VirtualNetwork tag covers peered VNets) |
| `route-tables.tf` | UDRs — DMZ default → back LB DMZ frontend; AppGW subnet → back LB internal frontend |
| `nva.tf` | 2x Linux NVAs, 3 NICs each (external / internal / DMZ) |
| `nva.yaml.tftpl` | iptables + routing — uncomment SNAT line for the fix |
| `external-lb.tf` | Front (public) Standard LB, floating IP, SourceIP distribution |
| `internal-lb.tf` | Back (private) Standard LB — 2 frontends (internal + DMZ), HA Ports |
| `appgateway.tf` | App Gateway WAF_v2 in the appgw VNet, private listener |
| `webserver.tf` | DMZ webserver (nginx + /healthz) |
| `webserver.yaml.tftpl` | nginx cloud-init + self-signed cert |
| `outputs.tf` | Useful IPs and test one-liners |
