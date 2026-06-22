# Clientm Azure Network Lab

A Terraform lab exploring the Azure routing pattern of "Application Gateway WAF
in front of an active/active NVA pair, protecting a backend webserver."

## Repository layout

| Folder | What's in it |
|---|---|
| [`proposed-working-design-1/`](proposed-working-design-1/) | **Current design.** App GW WAF_v2 → Internal LB → 2× active/active Linux NVAs → webserver, all in a single VNet. `/healthz` end-to-end test verified — see [VERIFIED.md](proposed-working-design-1/VERIFIED.md). Inbound only; webserver egress is not firewalled. |
| [`proposed-working-design-2/`](proposed-working-design-2/) | design-1 **plus an Azure Firewall** for the webserver's outbound traffic, closing design-1's egress gap. Inbound is unchanged (keeps the NVA pair); a DMZ `0.0.0.0/0` UDR sends egress through the firewall. ~$1,360/mo. **Deployed and verified end-to-end (7/7)** — see [VERIFIED.md](proposed-working-design-2/VERIFIED.md). |
| [`proposed-working-design-3/`](proposed-working-design-3/) | **Alternative to design-2.** Drops the NVA pair *and* the Internal LB; one **Azure Firewall** inspects **both** inbound (App GW → firewall → webserver) and egress. Fewer moving parts, retires Palo Alto, but gives up the Palo Alto feature set. ~$1,272/mo. **Deployed and verified end-to-end (7/7)** — see [VERIFIED.md](proposed-working-design-3/VERIFIED.md). |
| [`proposed-working-design-4/`](proposed-working-design-4/) | In response to the 2026-06-12 review with Patrick: a **single Linux NVA with three NICs** (untrust / trust / dmz, iptables) replaces Azure Firewall and handles BOTH inbound and egress, giving the multi-interface zone separation Patrick wants. Single instance = no LB asymmetry. **L4 port allow-list** (no FQDN). ~$391/mo (cheapest, no Azure Firewall). Validates clean but **not yet deployed** — see [DESIGN.md](proposed-working-design-4/DESIGN.md) and [README.md](proposed-working-design-4/README.md). |
| [`proposed-working-design-5/`](proposed-working-design-5/) | **Two-firewall solution** — design-4's single 3-NIC NVA for inbound + Azure Firewall for egress. Answers "the client needs both firewall products in the architecture." NGFW-shape inbound preserved; FQDN-aware egress restored. ~$1,307/mo. Validates clean but **not yet deployed** — see [README.md](proposed-working-design-5/README.md). |
| [`current-broken-state/`](current-broken-state/) | Earlier attempt (App GW NATed *behind* the firewalls) that hit the asymmetric-return-path problem. Archived for reference; do not deploy. |

## Cost at a glance (US East, 24/7)

Estimates, idle lab. Each design's README has the full line-item breakdown.

| Design | What it adds | Egress firewalled? | ~$/mo |
|---|---|---|---|
| [design-1](proposed-working-design-1/README.md#cost-us-east-247) | App GW WAF + NVA pair + Internal LB | no | **~$444** |
| [design-2](proposed-working-design-2/README.md#cost-us-east-247) | design-1 **+ Azure Firewall** (egress only) | yes | **~$1,360** |
| [design-3](proposed-working-design-3/README.md#cost-us-east-247) | NVAs/LB **replaced by Azure Firewall** (both directions) | yes | **~$1,272** |
| [design-4](proposed-working-design-4/README.md#cost-us-east-247) | Single multi-NIC Linux NVA — both directions, no Azure Firewall | yes (L4 ports only) | **~$391** |
| [design-5](proposed-working-design-5/README.md#cost-us-east-247) | design-4's NVA inbound **+ Azure Firewall** egress (the two-firewall variant) | yes (FQDN) | **~$1,307** |

The Azure Firewall (~$912/mo, Standard) dominates designs 2, 3, and 5 and **bills
by the hour whether or not traffic flows** (~$30/day idle). design-3 is only
~$90/mo cheaper than design-2 on the Azure bill — its real advantage is
operational (one firewall product, one VM) plus retiring the client's Palo Alto
licensing, which is off this bill. design-5 sits between design-3 and design-2 in
price (one NVA + AzFW vs no NVA / two NVAs), with Patrick's NGFW-shape inbound
preserved. **`terraform destroy` between sessions**, and note that a deployed
design-2 + design-3 + design-5 together run **three** Azure Firewalls.

## Quick start

```bash
cd proposed-working-design-1
cp terraform.tfvars.example terraform.tfvars
# edit: paste your SSH public key and your public IP /32

terraform init
terraform apply
```

Full topology, cost breakdown, test commands, and file-by-file reference are
in [`proposed-working-design-1/README.md`](proposed-working-design-1/README.md).

The App Gateway alone runs ~$320/mo, so run `terraform destroy` between
sessions. design-2 adds an Azure Firewall (~$912/mo on top), so destroying it
between sessions matters even more there — see
[`proposed-working-design-2/README.md`](proposed-working-design-2/README.md).

## Validating traffic flows (design-2 / design-3)

[`validate-flows.sh`](validate-flows.sh) is a read-only checker that probes a
deployed design and asserts the inbound path, X-Forwarded-For preservation, the
egress SNAT through Azure Firewall, and the egress allow-list deny. It
auto-detects which design it's pointed at:

```bash
./validate-flows.sh proposed-working-design-2
./validate-flows.sh proposed-working-design-3
```

It uses `~/.ssh/clientm-lab` if present and exits non-zero if any check fails.
