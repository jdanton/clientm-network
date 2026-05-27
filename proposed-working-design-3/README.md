# Clientm Network Lab — design-3: Azure Firewall for BOTH directions

design-3 answers the question "do we still need the NVAs?" with **no**. It
removes the active/active Linux NVA pair **and** the Internal Load Balancer
and lets a single **Azure Firewall** inspect both inbound and outbound traffic.
The App Gateway WAF stays at the public edge.

This is the alternative to [`proposed-working-design-2`](../proposed-working-design-2/):

| | design-2 | design-3 (this) |
|---|---|---|
| Inbound firewall | active/active Linux NVAs (Palo Alto stand-in) + Internal LB | Azure Firewall |
| Egress firewall | Azure Firewall | Azure Firewall (same one) |
| Firewall products | 2 (NVA pair **and** Azure Firewall) | 1 (Azure Firewall) |
| VMs to run/patch | 3 (2 NVA + webserver) | 1 (webserver) |
| Symmetry mechanism | NVA SNAT (in) + shared-state firewall (out) | shared-state firewall (both) |
| Keeps Palo Alto feature set? | yes (that's the point) | no — Azure Firewall Standard only |
| ~$/mo | ~$1,360 | ~$1,272 |

> **Status:** `terraform validate`-clean, **not yet deployed.** See
> [VERIFIED.md](VERIFIED.md). design-1 is the only live-verified design;
> design-3 also routes App-Gateway-backend traffic through the firewall, which
> has first-deploy caveats called out below.

## Topology

```
Internet
   │  HTTPS:443
   ▼
┌─────────────────────────────────────────┐
│ App Gateway WAF_v2 (public IP)          │  snet-appgateway 10.0.1.0/24
└────────────────┬────────────────────────┘
                 │  backend = webserver 10.0.3.100
                 │  (App GW subnet UDR: 10.0.3.0/24 ─► firewall)
                 ▼
┌─────────────────────────────────────────┐
│ Azure Firewall (Standard)               │  AzureFirewallSubnet 10.0.4.0/26
│  • DNAT  : public IP:22 ─► webserver:22 │
│  • net   : appgw subnet ─► web :80/:443 │
│  • net   : web ─► DNS/NTP               │
│  • app   : web ─► FQDN allow-list       │
│  • SNAT  : web egress ─► firewall pub IP│
└────────────────┬────────────────────────┘
                 ▼
       ┌──────────────────────┐
       │ Webserver 10.0.3.100 │  snet-web 10.0.3.0/24  (no public IP)
       │ nginx /healthz /whoami│
       └──────────┬───────────┘
                  │ web subnet UDRs:
                  │   10.0.1.0/24 ─► firewall  (inbound return leg)
                  │   0.0.0.0/0   ─► firewall  (egress)
                  ▼
                Internet
```

Every flow crosses the firewall in **both** directions: inbound web (App GW ⇆
webserver) and outbound (webserver ⇆ Internet). The firewall's shared session
state keeps each flow symmetric — see [EXPLANATION.md](EXPLANATION.md).

## How traffic stays symmetric

- **Inbound:** App GW connects to the webserver IP. The App GW subnet UDR sends
  that to the firewall; the firewall (no SNAT for private→private) forwards it
  to the webserver, which sees the App GW's real private IP. The webserver's
  reply hits the web-subnet UDR for `10.0.1.0/24` → back through the firewall →
  App GW. Both legs traverse the same shared-state firewall.
- **Outbound:** the `0.0.0.0/0` web-subnet UDR sends Internet-bound traffic to
  the firewall, which SNATs to its public IP. Return comes back to that public
  IP and the shared state returns it to the webserver.
- **Management:** a firewall DNAT rule publishes `firewall_public_ip:22` →
  `webserver:22`, source-restricted to `allowed_ssh_cidr`. Azure Firewall
  auto-SNATs DNAT traffic, so SSH is symmetric too.

## What gets inspected

| Rule | Type | Allows |
|---|---|---|
| `mgmt-dnat` | NAT (DNAT) | `allowed_ssh_cidr` → firewall pub IP:22 → webserver:22 |
| `inbound-web` | Network (L3/L4) | App GW subnet → webserver `:80/:443` |
| `egress-infra` | Network (L3/L4) | web subnet → `53` (DNS), `123` (NTP) |
| `egress-web` | Application (L7) | web subnet → HTTP/HTTPS to `var.egress_allowed_fqdns` |

Everything else is implicitly denied and logged.

## First-deploy caveats (read before `apply`)

1. **App Gateway v2 + UDR to a firewall.** Routing App-Gateway-backend traffic
   through Azure Firewall is the Microsoft "defense in depth with App Gateway +
   Azure Firewall" pattern, but it is finicky:
   - We use a **specific** route (`10.0.3.0/24` → firewall) on the App GW
     subnet, **not** `0.0.0.0/0`. A default route to a VirtualAppliance on the
     App Gateway subnet can break the gateway's required platform connectivity.
   - The App GW health probe (`/healthz`) must succeed *through* the firewall;
     the `inbound-web` network rule allows it. If the probe goes unhealthy after
     deploy, that rule / the UDRs are the first place to look.
2. **For an HTTP-only workload, the WAF is already the inbound L7 control.**
   Azure Firewall Standard adds L3/L4 control + central logging on the inbound
   leg, not deep HTTP inspection. If you do not want the firewall in the inbound
   path at all, delete the `appgw` route table + the `inbound-web` rule and the
   `appgw-return-via-firewall` route — that yields "App GW direct to webserver,
   Azure Firewall for egress only," a simpler variant of this design.
3. **No Palo Alto feature parity.** This design gives up App-ID / threat
   prevention / IDPS. If those are required, keep design-2 (real NVAs inbound).

## Cost (US East, 24/7)

| Resource | ~$/mo |
|---|---|
| App Gateway WAF_v2 (idle, autoscale min=0) | ~$320 |
| **Azure Firewall Standard** ($1.25/hr, bills idle) | **~$912** |
| Azure Firewall data processing ($0.016/GB) | usage-based |
| 1× webserver (B2s) + disk | ~$32 |
| App GW public IP + firewall public IP | ~$8 |
| **Total** | **~$1,272/mo** |

Versus design-2 (~$1,360), design-3 saves only ~$90/mo — the two NVA VMs and the
Internal LB. **The win is operational, not financial:** one firewall product
instead of two, one VM instead of three, no iptables cloud-init, native symmetry
both directions. The dominant costs (App GW + Azure Firewall) are identical.
Note also that design-3 retires the client's **Palo Alto licensing**, which is
real money but not on this Azure bill.

As in design-2, the Azure Firewall bills ~$30/day whether or not traffic flows —
`terraform destroy` between sessions. Cold `apply` ~10–15 min (firewall is the
long pole).

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit: paste your SSH public key, your public IP /32

terraform init
terraform plan
terraform apply
```

`resource_group_name`/`name_prefix` default to `*-d3` so design-3 can run
alongside design-1/2 without colliding.

## Test

```bash
eval "$(terraform output -raw test_commands | sed -n '1,2p')"   # sets APPGW / FW
curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
  https://connect.clientmworkspace.com/healthz                  # 200 OK

ssh azureuser@$FW            # DNAT'd to the webserver
#   on the webserver:
curl -s https://api.ipify.org ; echo        # → $FW (egress SNAT proof)
curl -s --max-time 10 https://example.com/   # → blocked (not allow-listed)
```

`terraform output test_commands` prints the full set with live IPs.

Or run the automated flow validator from the repo root (read-only — it asserts
the inbound path, XFF preservation, egress SNAT, and the allow-list deny):

```bash
../validate-flows.sh .          # from this directory, or:
./validate-flows.sh proposed-working-design-3   # from the repo root
```

## Tear down

```bash
terraform destroy
```

## File map (delta from design-2)

| File | Change |
|---|---|
| `main.tf` | subnets are appgateway / **web** / AzureFirewallSubnet (no `trust`) |
| `appgateway.tf` | backend pool = **webserver IP** (no Internal LB) |
| `firewall.tf` | + DNAT (mgmt SSH), + inbound-web network rule, + App GW & web UDRs |
| `network-security.tf` | single `nsg-web` (no trust/DMZ NSGs) |
| `variables.tf` | dropped trust/NVA/LB vars; `subnet_web_cidr` replaces dmz/trust |
| `webserver.tf` | webserver in `snet-web`, still no public IP |
| **removed** | `nva.tf`, `nva.yaml.tftpl`, `internal-lb.tf` |
