# A Real-NGFW-Shaped Firewall, Without Azure Firewall

A client-facing explanation of what design-4 is and why it exists alongside
design-2 and design-3.

## The question this answers

On the 2026-06-12 review, Patrick raised a concrete architectural objection to
design-3 (and by extension design-2's egress half): **a real enterprise
firewall has multiple interfaces — separate "outside," "inside," and "DMZ"
zones — and Azure Firewall has only one.** A topology built on Azure Firewall
doesn't represent the zone separation that the client's actual Palo Alto pair
provides on-prem.

His suggested answer was the only one that genuinely mimics that pattern in
Azure without buying a Palo Alto / Fortinet / Cisco appliance: **a Linux VM
with multiple NICs running iptables.** design-4 builds exactly that.

## What changed

```
design-2:  App GW WAF → NVA pair (inbound) → webserver → Azure Firewall → Internet
design-3:  App GW WAF → Azure Firewall (both directions) → webserver → ↑
design-4:  App GW WAF → single multi-NIC NVA (both directions) → webserver → ↑
```

design-4 collapses the firewall functions of design-2 (NVAs inbound + Azure
Firewall egress) onto **one** Linux NVA with three NICs. That NVA does:

- **Inbound:** App Gateway connects to its `trust` NIC. iptables DNATs to the
  webserver and SNATs on the `dmz` NIC so the return path is symmetric.
- **Egress:** the webserver's default route points at the NVA's `dmz` NIC.
  iptables enforces an L4 allow-list and MASQUERADEs out the `untrust` NIC
  to the Internet.
- **Management:** the `untrust` NIC carries the single public IP (SSH locked
  to the admin IP).

## Why one NVA is safe here when design-1 used two

design-1 specifically refused to route egress through its NVA pair, because
the active/active pair sat behind a Standard Load Balancer that hashes flows
independently per direction — outbound to NVA-A, return to NVA-B, drop.
Asymmetric routing.

design-4 has **one** NVA. Removing the LB removes the asymmetry. Every flow
in either direction touches the same iptables conntrack. The trade is HA:
this is the single-instance form of design-1's "active/standby" egress option,
and the obvious next iteration (active/standby with one node taking over on
failure) is documented as a follow-on.

## What we gain

- **Multi-interface zone separation** — exactly what Patrick asked for, and
  the only Azure-native pattern that mirrors a real NGFW without licensing
  a vendor image.
- **One firewall, no Azure Firewall** — operationally simpler than design-2
  (two firewall products), and ~$900/mo cheaper than design-2 or design-3.
- **Same iptables tooling design-1 already proved** — symmetric NAT, per-NIC
  PBR, NIC detection by subnet. Nothing new to learn or test for that layer.
- **Cheapest design that closes the egress gap** at ~$391/mo (vs $1,360 for
  design-2 and $1,272 for design-3).

## What we give up

- **HA.** Single NVA. If it fails, both inbound and egress fail. Acceptable for
  the lab; production needs an HA pair (Palo Alto in the client's case).
- **FQDN allow-listing.** iptables is L3/L4. design-2 and design-3 do FQDN
  matching via Azure Firewall application rules; design-4 allows or denies by
  port (DNS / NTP / HTTP / HTTPS). Adding a Squid forward proxy on the NVA
  would give FQDN parity if that becomes a requirement.
- **Managed threat intel / IDS-IPS.** Azure Firewall ships with these; iptables
  does not. Real NGFW features come from a real NGFW.
- **Customer-managed VM surface.** Patching, monitoring, log shipping all on
  the customer's plate. Azure Firewall is PaaS; iptables-on-Linux is IaaS.

## Cost reality

design-1 and design-4 are the two designs without Azure Firewall, and they're
the only two under ~$500/mo. design-2 and design-3 are both dominated by Azure
Firewall (~$912/mo) and end up at ~$1,272–$1,360/mo. App Gateway WAF is the
shared ~$320/mo baseline for all four designs.

| Design | Inbound | Egress | ~$/mo |
|---|---|---|---|
| design-1 | NVA pair | **(not firewalled)** | ~$444 |
| design-2 | NVA pair | Azure Firewall | ~$1,360 |
| design-3 | Azure Firewall | Azure Firewall | ~$1,272 |
| **design-4** | **single NVA** | **same NVA** | **~$391** |

## Recommendation framing for the client

- **Pick design-2** if the Palo Alto pair must stay on the inbound path (it's
  the client's standardized product) and egress filtering is a hard requirement.
- **Pick design-3** to consolidate on Azure-native managed services and retire
  Palo Alto entirely — accepting Azure Firewall's single-interface model.
- **Pick design-4** if you want the "real firewall with proper zones" topology
  (Patrick's concern) at the lowest cost, accepting single-NVA HA and L4-only
  egress filtering, with a clear path to vendor HA (Palo Alto VM-Series) for
  production.

## What still needs verifying

Not yet deployed. The L4 egress allow-list and the DMZ subnet UDR are new vs
design-1's NVA pattern; [VERIFIED.md](VERIFIED.md) lists the checks to run
once it's applied.
