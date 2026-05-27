# Clientm Network Lab — design-1 + Azure Firewall egress

This is [`proposed-working-design-1`](../proposed-working-design-1/) with one
thing added: the webserver's **outbound** Internet traffic is forced through an
**Azure Firewall** for egress inspection. The inbound path (App Gateway WAF →
Internal LB → active/active Linux NVAs → webserver) is **unchanged** — see
design-1 for the inbound routing-symmetry write-up.

design-1 deliberately left egress un-firewalled because re-using the
LB-fronted NVA pair for egress recreates the asymmetric-routing failure it had
just fixed. Azure Firewall is the option that closes that gap without
reintroducing the problem — it is a managed cluster that shares session state
behind a single private IP, so the return half of a flow is handled correctly
no matter which backend instance sees it. See [EXPLANATION.md](EXPLANATION.md).

> **Status:** the Terraform is written and `terraform validate`-clean, but this
> design has **not yet been deployed or tested end-to-end.** See
> [VERIFIED.md](VERIFIED.md). design-1 *is* verified live.

## Topology

```
Internet
   │
   ▼  HTTPS:443                                INBOUND (identical to design-1)
┌─────────────────────────────────────────┐
│ App Gateway WAF_v2 (public IP)          │  snet-appgateway 10.0.1.0/24
└────────────────┬────────────────────────┘
                 ▼  HTTP:80 (lab)
┌─────────────────────────────────────────┐
│ Internal Load Balancer (Standard)       │  snet-trust 10.0.2.0/24
└──────┬──────────────────────────┬───────┘
   ┌───▼───┐                  ┌───▼───┐
   │ NVA1  │  Linux/iptables  │ NVA2  │  trust 10.0.2.10/.11
   │       │  active/active   │       │  dmz   10.0.3.20/.21
   └───┬───┘                  └───┬───┘
       └──────────┬───────────────┘
                  ▼
       ┌──────────────────────┐
       │ Webserver 10.0.3.100 │  snet-dmz 10.0.3.0/24
       │ nginx /healthz /whoami│
       └──────────┬───────────┘
                  │  OUTBOUND (new in design-2)
                  │  DMZ 0.0.0.0/0 UDR ─► firewall private IP
                  ▼
       ┌──────────────────────────────┐
       │ Azure Firewall (Standard)    │  AzureFirewallSubnet 10.0.4.0/26
       │  • network rules: DNS, NTP   │
       │  • app rules: FQDN allow-list│
       │  • SNAT ─► firewall public IP│
       └──────────────┬───────────────┘
                      ▼
                   Internet
```

Inbound returns (`webserver → NVA DMZ IP 10.0.3.x`) stay intra-VNet on the
more-specific system route, so the `0.0.0.0/0` egress UDR only catches the
webserver's *Internet-bound* traffic. The inbound path is untouched.

## Why Azure Firewall is symmetric (and an egress NVA pair is not)

The webserver opens an outbound flow; the firewall picks a backend instance and
SNATs to its public IP. The reply returns to that public IP and may be steered
to a *different* backend instance — but every instance shares the same session
table, so the flow is found and returned correctly.

Contrast with re-using the inbound pattern for egress: a Standard LB in front of
two **independent** NVAs hashes the outbound flow to NVA-A and the return to
NVA-B; NVA-B has no state for it → `INVALID` → drop. That is the exact failure
mode `current-broken-state/` hit and design-1 avoided. Azure Firewall removes
the "independent state tables" precondition, so the problem can't occur.

## What gets inspected

[`firewall.tf`](firewall.tf) defines a firewall policy with:

| Rule collection | Type | Allows |
|---|---|---|
| `net-egress` | Network (L3/L4) | DMZ → `UDP/TCP 53` (DNS), `UDP 123` (NTP) |
| `app-egress` | Application (L7) | DMZ → HTTP/HTTPS to the FQDNs in `var.egress_allowed_fqdns` |

Everything else outbound is implicitly denied and logged. The default allow-list
is Ubuntu update domains plus `api.ipify.org` (so the egress test can echo the
SNAT IP). Tighten `egress_allowed_fqdns` to whatever the real workload needs.

## Cost (US East, 24/7)

| Resource | ~$/mo |
|---|---|
| Everything in design-1 (App GW WAF_v2 ~$320, NVAs/webserver, LB, IPs, disks) | **~$444** |
| **Azure Firewall Standard** (deployment, $1.25/hr) | **~$912** |
| Azure Firewall data processing ($0.016/GB) | usage-based (~$0 idle lab) |
| Firewall public IP | ~$4 |
| **Total** | **~$1,360/mo** |

The Azure Firewall now dominates the bill — it is roughly 3× the App Gateway and
about two-thirds of the whole monthly cost. **This is the headline cost of the
design.** A few notes:

- **It bills whether or not traffic flows.** The $1.25/hr deployment fee accrues
  the moment the firewall exists. An idle lab still costs ~$30/day.
- `terraform destroy` between sessions is even more important than in design-1.
  Cold `apply` takes ~10–15 min (Azure Firewall provisioning is the long pole).
- **Cheaper lab option:** `firewall_sku_tier = "Basic"` is ~$0.395/hr (~$288/mo)
  but Basic **additionally requires a separate management public IP and a
  `management_ip_configuration` block** that this lab does not wire up. Switching
  to Basic is a small edit to `firewall.tf`, not just the variable — see the
  comment there before changing it. Premium is ~$2.496/hr (~$1,825/mo) and only
  worth it for TLS inspection / IDPS, which this lab does not use.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit: paste your SSH public key, your public IP /32

terraform init
terraform plan
terraform apply
```

No new required variables vs design-1 — the firewall tier and egress allow-list
both have defaults.

## Test

Inbound (same as design-1):

```bash
APPGW=$(terraform output -raw appgw_public_ip)
curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
  https://connect.clientmworkspace.com/healthz
```

Egress (new). The webserver has no public IP, so jump through an NVA:

```bash
NVA1=$(terraform output -raw nva1_public_ip)
ssh -J azureuser@$NVA1 azureuser@10.0.3.100

# On the webserver:
curl -s https://api.ipify.org ; echo        # → the firewall public IP (proves SNAT)
curl -s --max-time 10 https://example.com/   # → blocked (not in the allow-list)
```

`terraform output test_commands` prints these with your live IPs filled in.
Allowed egress is SNATed to `terraform output -raw firewall_public_ip`; denied
egress shows up in the firewall's Application-rule logs (enable a Log Analytics
workspace + diagnostic settings to see them — not wired up in this lab).

Or run the automated flow validator from the repo root (read-only — it asserts
the inbound path, XFF preservation, egress SNAT, and the allow-list deny):

```bash
../validate-flows.sh .          # from this directory, or:
./validate-flows.sh proposed-working-design-2   # from the repo root
```

## Tear down

```bash
terraform destroy
```

## File map (delta from design-1)

| File | Change |
|---|---|
| `main.tf` | + `AzureFirewallSubnet` (10.0.4.0/26) |
| `variables.tf` | + `subnet_firewall_cidr`, `firewall_sku_tier`, `egress_allowed_fqdns` |
| `firewall.tf` | **new** — public IP, firewall policy + egress rules, Azure Firewall, DMZ `0.0.0.0/0` route table |
| `outputs.tf` | + firewall private/public IPs, egress test commands |
| everything else | identical to design-1 |
