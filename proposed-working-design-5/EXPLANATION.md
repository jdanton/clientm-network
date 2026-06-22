# Two Firewalls, Two Roles

A client-facing explanation of how design-5 fits between design-2 / design-3 /
design-4 and why it's the answer when the requirement is "two firewall
products in the architecture."

## The requirement this answers

> "Azure Firewall should be in this solution for the outbound traffic.
> Client needs a two firewall solution here."

design-4 satisfied Patrick's 2026-06-12 review note that the inbound firewall
should have multiple zone interfaces (which Azure Firewall can't represent —
it has only one). But design-4 used iptables on the same NVA for egress too,
and iptables is L3/L4 only — no FQDN allow-listing, no managed threat intel.
For an egress policy the client can actually defend, Azure Firewall (or a
real NGFW) needs to be in the path.

design-5 puts both firewalls in the architecture, each doing what it does best:

| Direction | Firewall | Why |
|---|---|---|
| **Inbound** | Linux NVA, 3 NICs, iptables | Mimics the client's Palo Alto's zone-interface model. Single instance → no LB → no asymmetric routing. |
| **Egress** | Azure Firewall (Standard) | Managed; FQDN allow-list (L7); shared-state cluster so symmetry holds without a load balancer; the same pattern design-2 and design-3 already use. |

## How it differs from design-2 and design-3

- **vs design-2:** same two-firewall split, but the inbound NVA is **one VM with
  three NICs** instead of two VMs in active/active behind an Internal Load
  Balancer. That removes the LB asymmetry problem outright (no LB → no hash)
  AND gives Patrick the explicit zone interfaces. Trade-off: no active/active
  HA on the inbound NVA. If the NVA fails, inbound fails. Production would run
  a Palo Alto HA pair here, like the client already does on-prem.
- **vs design-3:** design-3 collapsed everything onto Azure Firewall — simpler
  and one product less, but loses the multi-NIC NGFW shape Patrick asked for.
  design-5 keeps it.

## How the two firewalls compose

```
Inbound  : client → App GW WAF → NVA (zone enforcement, DNAT, SNAT) → webserver
Egress   : webserver → DMZ UDR 0.0.0.0/0 → Azure Firewall (FQDN allow-list, SNAT) → Internet
```

- Webserver-originated outbound never touches the NVA. The DMZ subnet's
  default route is the firewall's private IP, not the NVA's dmz IP. The NVA's
  iptables FORWARD chain therefore only sees inbound traffic.
- Inbound never touches Azure Firewall. App GW connects to the NVA's trust NIC
  (its backend pool); the NVA DNATs to the webserver and SNATs on the dmz NIC
  for symmetric return.
- The two firewalls operate independently — distinct policy planes, distinct
  audit trails. That's a real benefit if the security team wants different
  owners for ingress and egress controls.

## Defense-in-depth alternative (not built — flag if you want it)

The reading above is **parallel** — each firewall handles one direction. A
**series** reading of "two firewall solution" would route webserver egress
through the NVA *first*, then through Azure Firewall (defense in depth on the
outbound leg). Mechanically that means adding a UDR on `snet-untrust` so the
NVA's MASQUERADE'd egress hits the firewall on the way out, plus restoring
the L4 allow-list on the NVA. It's a ~30-minute Terraform change. The parallel
reading is what's built here; if the client wants series, that's a follow-on.

## What we gain

- **Both firewalls in the architecture** — separately auditable, separately
  managed, with the L7 egress controls Azure Firewall provides on top of the
  NVA's zone-based inbound model.
- **Patrick's NGFW-shape inbound preserved** — three explicit interfaces in
  three subnets, the way a Palo Alto would be configured on-prem.
- **No LB asymmetry** — single NVA, no Internal LB, no load balancer hashing
  return packets to the wrong stateful device.

## What we give up

- **HA on the inbound NVA.** Single instance. If it dies, inbound fails. Same
  caveat as design-4. Active/standby is the obvious follow-on; production = a
  vendor HA pair.
- **Cost.** Azure Firewall (~$912/mo) dominates. design-5 is in the same
  tier as design-2 (~$1,307 vs ~$1,360); design-4 (no Azure Firewall) was
  ~$391, and the gap is almost entirely the firewall.

## Recommendation framing for the client

- **Pick design-5** if the requirement is "two firewall products, NGFW-shape
  inbound, real FQDN-aware egress" — which is what was just communicated.
- **Stay on design-2** if active/active inbound HA is non-negotiable and the
  Palo Alto pair must remain in the lab pattern.
- **Pick design-3** to consolidate on Azure-native managed services, dropping
  Palo Alto entirely.
- **design-4** is the cheapest option but trades away FQDN egress filtering;
  not a fit when the brief says "Azure Firewall in the solution."

## What still needs verifying

Not yet deployed. The combination of the NVA's inbound path and the firewall's
egress path each carry their respective design's confidence (design-4 verified
the iptables NVA pattern by inspection; design-2/3 are live-verified for the
Azure Firewall egress). The new wrinkle is the boot-order interaction between
the NVA cloud-init and the firewall rule propagation, which design-3's apt
retry loop already addresses on the webserver side. See [VERIFIED.md](VERIFIED.md).
