# Clientm Network Lab — design-6: private-frontend App Gateway

design-6 is **design-5 with the Application Gateway's front door moved from a
public IP to a private IP.** Everything behind the gateway is unchanged — the
two-firewall pattern (Linux NVA inbound, Azure Firewall egress), the NVA backend,
the DNAT/SNAT chain, the FQDN-aware egress. Only how clients *reach* the gateway
changes: they come in over a **private IP (`10.0.1.10`), not the Internet.**

This formalizes the private-IP direction that tested clean on design-5
(2026-06-19, confirmed on the Patrick call: *"I tested this Friday with a private
IP and it all still worked"*). Where design-5 kept the public front door and
*added* a private one as a variant, **design-6 makes private the front door.**

> 📐 **Network diagram:** [`network-diagram.svg`](network-diagram.svg)

## Who reaches it, and how

A private-frontend App Gateway has no Internet entry point. Clients reach
`10.0.1.10` from:

- another workload in the same VNet,
- a **peered VNet**,
- **on-prem** over VPN / ExpressRoute,
- (in this lab) the in-VNet `vm-test-client` in `snet-test`.

This matches the client's real shape — an **internal application** that must not
be exposed to the public Internet, fronted by WAF + the NVA.

## The `appgw_private_only` toggle

A truly private-only App Gateway on **WAF_v2** requires the subscription feature
`Microsoft.Network/EnableApplicationGatewayNetworkIsolation`. To stay deployable
without waiting on that registration, design-6 ships a toggle:

| `appgw_private_only` | Frontend | Feature flag needed? | Use |
|---|---|---|---|
| **`false`** (default) | private **primary** + public **fallback** | no | deploys today; private is the documented front door, public is a lab escape hatch |
| **`true`** | private **only** (no public IP at all) | **yes** | the real target state once the feature is registered |

Flipping the toggle is a `dynamic` block: at `true`, the public IP, public
frontend, public listener, and public rule are all omitted.

### Enabling true private-only

```bash
az feature register --namespace Microsoft.Network \
  --name EnableApplicationGatewayNetworkIsolation
# wait until Registered (can take 15-30 min), then:
az provider register --namespace Microsoft.Network
# then:
terraform apply -var 'appgw_private_only=true'
```

## Topology

```
   in-VNet / peered VNet / on-prem (VPN·ExpressRoute)      [Internet — fallback only]
                 │  HTTPS:443 → 10.0.1.10                       ┊ (public IP, off when
                 ▼                                              ┊  private_only = true)
┌──────────────────────────────────────┐
│ App Gateway WAF_v2                    │  snet-appgateway 10.0.1.0/24
│  frontend-private 10.0.1.10  ◀ FRONT  │  (+ NAT Gateway for App GW egress)
│  frontend-public  (fallback)          │
└────────────────┬─────────────────────┘
                 │ backend = NVA trust IP 10.0.2.10
                 ▼
┌─────────────────────────────────────────────────────────┐
│   Linux NVA  (single VM, 3 NICs, iptables)               │
│   trust 10.0.2.10  ← App Gateway backend                 │
│   dmz   10.0.3.10  ← PREROUTING DNAT :80/:443 → webserver │
│   untrust 10.0.4.10 ← mgmt PIP + NVA's own egress        │
└────────┬─────────────────────────────────────────────────┘
         ▼
   ┌──────────────────────┐
   │ Webserver 10.0.3.100 │  snet-dmz 10.0.3.0/24
   │ nginx /healthz       │
   └──────────┬───────────┘
              │ egress via snet-dmz UDR 0.0.0.0/0 → Azure Firewall
              ▼
   ┌──────────────────────────────────┐
   │ Azure Firewall (Standard)        │  AzureFirewallSubnet 10.0.5.0/26
   │  FQDN allow-list egress + SNAT   │
   └──────────────┬───────────────────┘
                  ▼
                Internet
```

## Why the private front door doesn't change probe behaviour

The App Gateway backend health probe originates from the gateway instances and
targets the **backend pool member** (the NVA trust IP) — it is independent of
which frontend serves clients. So making the front door private changes nothing
about where the probe goes: it still lands on the NVA, exactly as verified on
design-5. This is the crux of the client's "no probes in the firewall" issue —
see [`../appgw-probe-firewall-runbook.md`](../appgw-probe-firewall-runbook.md).

## Cost (US East, 24/7)

Same tier as design-5 (Azure Firewall dominates), plus a NAT Gateway for the
private gateway's control-plane egress. The `vm-test-client` is lab-only —
drop it in production (peering/VPN provides the real client path).

| Resource | ~$/mo |
|---|---|
| App Gateway WAF_v2 (idle, autoscale min=0) | ~$320 |
| Azure Firewall Standard | ~$912 |
| NAT Gateway (App GW subnet egress) | ~$33 |
| 1× NVA + 1× webserver (B2s) | ~$60 |
| `vm-test-client` (B2s, lab only) | ~$30 |
| public IPs (NVA mgmt + firewall + NAT GW [+ App GW fallback]) | ~$16 |
| **Total (lab)** | **~$1,371/mo** |

`terraform destroy` between sessions — Azure Firewall bills ~$30/day idle.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # or reuse the design-5 tfvars
# edit: paste your SSH public key, your public IP /32

terraform init
terraform plan
terraform apply                                # private primary + public fallback
# or, once the network-isolation feature is registered:
terraform apply -var 'appgw_private_only=true' # truly private-only
```

`resource_group_name` / `name_prefix` default to `*-d6`, so design-6 runs
alongside design-1…5 without colliding.

## Test

`terraform output test_commands` prints the full set with live IPs. The private
front door is exercised from the in-VNet test client:

```bash
ssh azureuser@$TEST_CLIENT_PIP \
  "curl -sk --resolve connect.clientmworkspace.com:443:10.0.1.10 \
     https://connect.clientmworkspace.com/healthz"     # expect 200
```

## Tear down

```bash
terraform destroy
```

## File map (delta from design-5)

| File | Change |
|---|---|
| `appgateway.tf` | private frontend is **primary**; public IP + public frontend/listener/rule are now behind a `appgw_private_only` `dynamic`/`count` toggle |
| `variables.tf` | + `appgw_private_only`; `resource_group_name`/`name_prefix` → `*-d6` |
| `outputs.tf` | `appgw_public_ip` is now null in private-only mode; `test_commands` leads with the private front door; + `appgw_private_only` output |
| `main.tf` | header re-scoped to design-6 (subnets unchanged, incl. `snet-test`) |
| `natgw.tf`, `test-client.tf`, `firewall.tf`, `route-tables.tf`, `network-security.tf`, `nva.tf`, `webserver.tf`, `*.tftpl`, `versions.tf` | unchanged from design-5 |
| `network-diagram.svg` | re-drawn for the private front door |

> **Status:** **Deployed and verified live end-to-end (7/7), 2026-06-23** — private
> front door + public fallback. The `appgw_private_only = true` path is not yet
> exercised (needs the network-isolation feature). See [VERIFIED.md](VERIFIED.md).
