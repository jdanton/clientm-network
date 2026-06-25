# Clientm Network Lab — design-5: NVA (inbound) + Azure Firewall (egress)

design-5 is the **two-firewall** answer to the client's requirement.

design-4 satisfied Patrick's "real-NGFW-shape, multi-NIC firewall" review note
but only had one firewall and L4-only egress filtering. The client wants two
firewall products in the architecture, with Azure Firewall doing the outbound
inspection. design-5 keeps design-4's multi-NIC Linux NVA for inbound (so the
zone separation Patrick asked for is preserved) and adds Azure Firewall back
for egress (so FQDN allow-listing, managed threat intel, and the entire app-rule
feature set are available again).

It is essentially **design-2 with the active/active LB-fronted NVA pair replaced
by a single 3-NIC NVA.** No Internal LB → no asymmetric routing problem; the
NVA has explicit zone interfaces; Azure Firewall handles egress exactly as
design-2 and design-3 already do.

> 📐 **Detailed network diagram:** [`network-diagram.svg`](network-diagram.svg)
> — full topology with subnets, IPs, NIC zones, and every traffic flow
> (inbound public/private, backend DNAT chain, egress, management).

| | design-2 | design-3 | design-4 | **design-5 (this)** |
|---|---|---|---|---|
| Inbound firewall | active/active NVAs + Internal LB | Azure Firewall (1 NIC) | single NVA (3 NICs) | **single NVA (3 NICs)** |
| Egress firewall | Azure Firewall | Azure Firewall | same NVA (L4) | **Azure Firewall** |
| Firewall products | 2 | 1 | 1 | **2** |
| FQDN allow-list | yes | yes | no (L4 only) | **yes** |
| HA on inbound | active/active | PaaS | single VM | **single VM** |
| ~$/mo | ~$1,360 | ~$1,272 | ~$391 | **~$1,307** |

> **Status:** `terraform validate`-clean, **not yet deployed.** See
> [VERIFIED.md](VERIFIED.md).

## Topology

```
Internet                         in-VNet test client (snet-test 10.0.6.0/24)
   │  HTTPS:443                      │  HTTPS:443
   ▼                                 ▼
┌──────────────────────────────────────┐
│ App Gateway WAF_v2                    │  snet-appgateway 10.0.1.0/24
│  dual frontend:                       │  (+ NAT Gateway for App GW egress)
│   • frontend-public  (PIP)            │
│   • frontend-private (10.0.1.10)      │
└────────────────┬─────────────────────┘
                 │ backend = NVA trust IP 10.0.2.10  (same for both frontends)
                 ▼
┌─────────────────────────────────────────────────────────┐
│   Linux NVA  (single VM, 3 NICs, iptables)              │
│                                                         │
│   eth0  untrust  10.0.4.10  ← snet-untrust 10.0.4.0/24  │
│                  • public IP (management SSH only)      │
│                                                         │
│   eth1  trust    10.0.2.10  ← snet-trust   10.0.2.0/24  │
│                  • App Gateway backend target           │
│                  • PREROUTING DNAT :80/:443 → webserver │
│                                                         │
│   eth2  dmz      10.0.3.10  ← snet-dmz     10.0.3.0/24  │
│                  • webserver-facing                     │
│                  • POSTROUTING SNAT for inbound returns │
│                  • NO egress rules — egress bypasses    │
│                    the NVA via the snet-dmz UDR         │
└────────┬────────────────────────────────────────────────┘
         │ inbound
         ▼
   ┌──────────────────────┐
   │ Webserver 10.0.3.100 │  snet-dmz 10.0.3.0/24
   │ nginx /healthz       │
   └──────────┬───────────┘
              │ egress via snet-dmz UDR 0.0.0.0/0 → Azure Firewall
              ▼
   ┌──────────────────────────────────┐
   │ Azure Firewall (Standard)        │  AzureFirewallSubnet 10.0.5.0/26
   │  • net  : dmz → DNS / NTP        │
   │  • app  : dmz → FQDN allow-list  │
   │  • SNAT : dmz → firewall pub IP  │
   └──────────────┬───────────────────┘
                  ▼
                Internet
```

## How the two firewalls divide the work

| Direction | Firewall | What it does |
|---|---|---|
| **Inbound** (client → webserver) | Linux NVA (3 NICs, iptables) | TLS terminates at App GW WAF; NVA does L3/L4 inspection between trust and dmz zones, DNAT to the webserver, SNAT on the dmz NIC for symmetric returns. |
| **Egress** (webserver → Internet) | Azure Firewall (Standard) | Webserver default route → firewall. FQDN allow-list at L7 (Ubuntu mirrors, `api.ipify.org` for tests); DNS/NTP at L4. SNAT to the firewall public IP. |
| Management SSH | NVA (untrust public IP) | Locked to `allowed_ssh_cidr`. Webserver via `ssh -J` ProxyJump. |

Webserver egress bypasses the NVA entirely (UDR sends it straight to the
firewall subnet), so the NVA's iptables FORWARD chain has no egress rules.
The NVA's own outbound (apt updates) still goes via its untrust NIC and Azure
default Internet — it does NOT transit Azure Firewall.

## Why this is symmetric

- **Inbound:** same single-NVA pattern as design-4. App GW → NVA trust →
  iptables DNAT → out dmz NIC → webserver; reply through the same conntrack →
  out trust NIC. No LB, no asymmetry.
- **Egress:** same Azure Firewall pattern as design-2 and design-3. The firewall
  is a managed cluster behind one private IP whose instances share a session
  table — return traffic finds the flow no matter which backend instance sees it.

## Dual-frontend App Gateway (private IP variant)

The App Gateway exposes **two frontends** on :443, both routing to the same NVA
backend:

| Frontend | Reachable from | Tested with |
|---|---|---|
| `frontend-public` (public IP) | Internet | `validate-flows.sh` / laptop |
| `frontend-private` (`10.0.1.10`) | inside the VNet only | `vm-test-client` in `snet-test` |

This came out of a client question: *"does putting a private IP on the App
Gateway change where the backend health probe routes?"* Answer, verified live
(see [VERIFIED.md](VERIFIED.md)): **no.** The probe originates from the gateway
instances and targets the **backend pool member** (the NVA trust IP) regardless
of which frontend serves clients. The frontend type is orthogonal to probe
routing — what determines whether probes reach a firewall is the **backend pool
target**, not the frontend. See the standalone
[`../appgw-probe-firewall-runbook.md`](../appgw-probe-firewall-runbook.md).

Two supporting notes:

- **Private-only is *not* available on WAF_v2** without the subscription feature
  `Microsoft.Network/EnableApplicationGatewayNetworkIsolation`. With it
  unregistered, Azure rejects a no-public-IP WAF_v2 gateway, so this design uses
  a **dual** frontend (public kept, private added).
- A private-capable App GW subnet loses default outbound, so a **NAT Gateway**
  is attached to `snet-appgateway` for the gateway's control-plane egress
  (CRL/OCSP).

## Cost (US East, 24/7)

| Resource | ~$/mo |
|---|---|
| App Gateway WAF_v2 (idle, autoscale min=0) | ~$320 |
| **Azure Firewall Standard** ($1.25/hr, bills idle) | **~$912** |
| Azure Firewall data processing ($0.016/GB) | usage-based |
| 1× NVA + 1× webserver (B2s) | ~$60 |
| 2× OS disks | ~$3 |
| 3× public IPs (App GW + firewall + NVA mgmt) | ~$12 |
| **Total** | **~$1,307/mo** |

Versus the other "egress-firewalled" designs:

| Design | ~$/mo | vs design-5 |
|---|---|---|
| design-2 (NVA pair + Azure FW) | ~$1,360 | +$53 |
| design-3 (Azure FW both ways) | ~$1,272 | −$35 |
| design-4 (single NVA both ways, no AzFW) | ~$391 | −$916 |
| **design-5** | **~$1,307** | — |

design-5 is design-2's price tier (Azure Firewall dominates regardless), with
the two-NVA active/active pair collapsed to one multi-NIC NVA. The savings vs
design-2 (~$53/mo: one NVA VM + the Internal LB removed) are modest; the real
gain is the explicit zone separation Patrick wanted on the inbound side. The
extra ~$35 vs design-3 buys you that NGFW-shape inbound.

`terraform destroy` between sessions — Azure Firewall bills ~$30/day idle.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit: paste your SSH public key, your public IP /32

terraform init
terraform plan
terraform apply
```

`resource_group_name`/`name_prefix` default to `*-d5` so design-5 can run
alongside any of design-1/2/3/4 without colliding.

## Test

`terraform output test_commands` prints the full set with live IPs filled in.
Or run the automated flow validator from the repo root (it auto-detects design-5
once outputs are present):

```bash
./validate-flows.sh proposed-working-design-5
```

The validator asserts:
- inbound `/healthz` → 200 via App GW
- `/whoami` `remote_addr` is an NVA DMZ IP (proves traffic crossed the NVA + SNAT)
- `X-Forwarded-For` preserves the client IP
- webserver reachable via ProxyJump through the NVA
- egress `api.ipify.org` source IP == Azure Firewall public IP (egress SNAT proof)
- allow-listed FQDN (`http://azure.archive.ubuntu.com/`) → 200
- non-allow-listed FQDN (`https://example.com/`) blocked

## Tear down

```bash
terraform destroy
```

## File map (delta from design-4)

| File | Change |
|---|---|
| `main.tf` | + `AzureFirewallSubnet` (10.0.5.0/26) |
| `variables.tf` | + `subnet_firewall_cidr`, `firewall_sku_tier`, `egress_allowed_fqdns` |
| `firewall.tf` | **new** — Azure Firewall + egress policy (DNS/NTP + FQDN allow-list) |
| `route-tables.tf` | DMZ UDR `0.0.0.0/0` → **Azure Firewall private IP** (not NVA dmz IP) |
| `nva.yaml.tftpl` | **removed** the L4 egress allow-list — dead code now (egress bypasses the NVA) |
| `outputs.tf` | + firewall public/private IPs |
| `nva.tf`, `webserver.tf`, `webserver.yaml.tftpl`, `terraform.tfvars.example`, `versions.tf` | unchanged from design-4 |

### Added for the private-frontend retest (2026-06-23)

| File | Change |
|---|---|
| `appgateway.tf` | App GW now has a **dual frontend** — `frontend-public` + `frontend-private` (`10.0.1.10`), each with its own :443 listener and routing rule → same NVA backend |
| `natgw.tf` | **new** — NAT Gateway + PIP on `snet-appgateway` (App GW control-plane egress) |
| `test-client.tf` | **new** — `vm-test-client` + NSG + PIP in `snet-test` to exercise the private listener |
| `main.tf` | + `snet-test` (`10.0.6.0/24`) |
| `variables.tf` | + `subnet_test_cidr`, `appgw_private_ip` |
| `outputs.tf` | + `appgw_private_ip`, `test_client_public_ip`, `natgw_public_ip`; `test_commands` covers both frontends |
| `network-diagram.svg` | **new** — detailed SVG topology diagram |
