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

```
App GW (10.1.1.10) ──UDR──▶ Back LB vip-internal (10.0.4.4)
                              │ SourceIP hash on 10.1.1.10 → NVA-A eth1
                              ▼
                            NVA-A eth1 ──DNAT──▶ Webserver (10.0.3.100)
                                                        │
                                   default route (0.0.0.0/0)
                                                        │
                                                        ▼
                              Back LB vip-dmz (10.0.3.10)
                              │ SourceIP hash on 10.0.3.100 → NVA-B eth2
                              ▼
                            NVA-B eth2
                              │ no conntrack entry (NVA-A owns the flow)
                              │ nf_conntrack_tcp_loose=0 → INVALID → DROP
                              ▼
                           ✗ connection reset / timeout
```

SourceIP distribution hashes on source IP only. Inbound (src = App GW) and return (src = webserver) hash independently — 50% chance they land on different NVAs with only two in the pool. The NVA that receives return traffic has never seen the SYN, marks the packet INVALID, and drops it.

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

## Applying the fix

The easiest fix is SNAT on the NVAs' DMZ NIC (eth2). With SNAT, the webserver sees the NVA's DMZ IP as the source and replies directly to that NVA — bypassing the back LB DMZ frontend entirely and forcing symmetric return.

Open [nva.yaml.tftpl](nva.yaml.tftpl) and uncomment the line in the `# >>> Toggle for the FIX <<<` section:

```bash
iptables -t nat -A POSTROUTING -o eth2 -p tcp --dport 443 -d $WEBSERVER_IP -j MASQUERADE
```

Then SSH to both NVAs and re-run the firewall script:

```bash
ssh azureuser@$(terraform output -raw nva1_public_ip) 'sudo /usr/local/sbin/nva-firewall.sh'
ssh azureuser@$(terraform output -raw nva2_public_ip) 'sudo /usr/local/sbin/nva-firewall.sh'
```

No `terraform apply` needed. Re-run the curl loop and all requests should return 200.

**Trade-off:** SNAT hides the original source IP from the webserver (it sees the NVA's DMZ IP). For production, the correct fix is a **Gateway Load Balancer** — see the [Azure GWLB docs](https://learn.microsoft.com/en-us/azure/load-balancer/gateway-overview) for the bump-in-the-wire pattern.

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
