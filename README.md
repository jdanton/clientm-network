# Clientm Azure Network Lab

A Terraform lab exploring the Azure routing pattern of "Application Gateway WAF
in front of an active/active NVA pair, protecting a backend webserver."

## Repository layout

| Folder | What's in it |
|---|---|
| [`proposed-working-design-1/`](proposed-working-design-1/) | **Current design.** App GW WAF_v2 → Internal LB → 2× active/active Linux NVAs → webserver, all in a single VNet. `/healthz` end-to-end test verified — see [VERIFIED.md](proposed-working-design-1/VERIFIED.md). Inbound only; webserver egress is not firewalled. |
| [`proposed-working-design-2/`](proposed-working-design-2/) | design-1 **plus an Azure Firewall** for the webserver's outbound traffic, closing design-1's egress gap. Inbound is unchanged; a DMZ `0.0.0.0/0` UDR sends egress through the firewall. Adds ~$912/mo. Validates clean but **not yet deployed** — see [VERIFIED.md](proposed-working-design-2/VERIFIED.md). |
| [`current-broken-state/`](current-broken-state/) | Earlier attempt (App GW NATed *behind* the firewalls) that hit the asymmetric-return-path problem. Archived for reference; do not deploy. |

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
