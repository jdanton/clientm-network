# design-4 — Proposal (not yet built)

A proposal in response to Patrick's review of design-3 on 2026-06-12. This is a
design document for review; **no Terraform has been written yet** — see the
"Build plan" section at the bottom.

## What Patrick asked for

The pertinent exchange, paraphrased from the transcript:

> **Patrick:** On the firewall, you need to have at least two interfaces. So how
> many interfaces do you have on the firewall?
> **Joey:** It's just the public and the private and I don't know that there's a
> way to do that without deploying a second firewall.
> **Patrick:** Yeah, then… I'm gonna ask you to redo this with a Linux server
> with two interfaces, and that becomes like a firewall with iptables. Because
> that's the only way to mimic [an enterprise NGFW], unless you get a trial of
> Cisco Firewall, Fortinet, or [Palo Alto].
> **Joey:** We could stand up a Linux server with iptables, that's what I did
> before, yeah. And then ride that inbound traffic through there, back to the
> firewall on the return path. Is that what you're asking basically?
> **Patrick:** Okay.

Two distinct concerns, both legitimate:

1. **Single-interface firewall ≠ real NGFW zone separation.** Azure Firewall has
   exactly one interface (one NIC in `AzureFirewallSubnet`). A traditional
   enterprise firewall — and the Palo Alto pair the client actually runs — has
   multiple physical interfaces sitting in different zones (untrust / trust /
   DMZ), and rules are written in terms of those zone interfaces. Patrick wants
   the lab to mirror that pattern.
2. **"Having multiple functionality in the same subnet is going to be
   challenging."** Patrick (and Joey, agreeing) want clearer subnet/zone
   separation between the public edge, the firewall data path, and the protected
   web tier.

## Why design-2 and design-3 don't meet this

| Design | Inbound firewall | Egress firewall | # firewall interfaces |
|---|---|---|---|
| design-1 | NVA pair (multi-NIC iptables) | none | 2 per NVA |
| design-2 | NVA pair (multi-NIC iptables) | Azure Firewall | 2 per NVA, **1** on Azure FW |
| design-3 | Azure Firewall | Azure Firewall | **1** |

design-3 is the cleanest from an Azure-native perspective, but it collapses
everything onto Azure Firewall — the single-interface product Patrick is
specifically objecting to. design-2 keeps the multi-NIC NVAs for inbound but
uses single-interface Azure Firewall for egress, so egress still doesn't have
the "real firewall with multiple zones" shape.

design-4 keeps the multi-NIC Linux iptables firewall pattern (Patrick's ask)
**for both directions** by routing egress through the same NVA — which design-1
explicitly didn't do because doing it with the active/active LB-fronted pair
recreated the asymmetric-routing failure. The fix here is to use a **single**
NVA instead of a pair, removing the LB and therefore the asymmetry.

## Proposed architecture

```
Internet
   │  HTTPS:443
   ▼
┌────────────────────────────────┐
│ App Gateway WAF_v2 (public)    │  snet-appgateway 10.0.1.0/24
└──────────────┬─────────────────┘
               │ backend pool = NVA trust IP (10.0.2.10)
               ▼
┌──────────────────────────────────────────────────────┐
│              Linux NVA (single VM)                   │
│  eth0 = TRUST  (snet-trust 10.0.2.0/24)              │
│         - App GW backend target                      │
│         - NVA's own egress (MASQUERADE to its PIP)   │
│         - management SSH                             │
│  eth1 = DMZ    (snet-dmz   10.0.3.0/24)              │
│         - faces the webserver                        │
│         - SNAT inbound so webserver replies to NVA   │
│                                                      │
│  iptables:                                           │
│   inbound DNAT  trust:443 → 10.0.3.100:443           │
│                 trust:80  → 10.0.3.100:80            │
│   egress filter snet-dmz → only DNS/HTTP/HTTPS/NTP   │
│                 (deny default; FQDN filter optional) │
│   SNAT          trust → MASQUERADE for !RFC1918      │
└────────────┬──────────────────┬──────────────────────┘
             │                  │ DMZ subnet UDR:
             │ inbound          │   0.0.0.0/0 → NVA DMZ IP
             ▼                  ▼
       ┌──────────────────────────┐
       │ Webserver 10.0.3.100     │  snet-dmz 10.0.3.0/24
       │ nginx /healthz /whoami   │  (no public IP, isolated)
       └──────────────────────────┘
```

Subnets — three, matching design-1's zoning:

| Subnet | CIDR | Purpose |
|---|---|---|
| `snet-appgateway` | 10.0.1.0/24 | App Gateway only |
| `snet-trust` | 10.0.2.0/24 | NVA trust NIC only (the "outside" zone of the firewall) |
| `snet-dmz` | 10.0.3.0/24 | NVA DMZ NIC + webserver (the "inside" / protected zone) |

This is **identical to design-1's subnet layout** — the change is in what lives
in each subnet (one NVA, not two; no Internal LB) and what the NVA's iptables
does (now also egress-filtering, which design-1 didn't).

## Why this stays symmetric (the design-1 lesson, applied)

design-1 specifically refused to send egress through its NVA pair because
re-pointing the DMZ default route at the LB would have caused the LB to hash
outbound flows to NVA-A and return flows to NVA-B → asymmetric drop. That
problem **only exists with two independent stateful devices behind a load
balancer.**

design-4 has **one** NVA. There is no LB on either leg. Every flow — inbound or
egress — terminates on the same iptables conntrack. Symmetric by construction.
This is the same reasoning that made design-1's "active/standby NVA pair" an
acceptable option for egress in its limitations table; we are taking it to its
logical conclusion (single instance).

## Traffic flows

**Inbound** `client → App GW → NVA trust → DNAT → NVA DMZ → webserver`
1. Client connects to App Gateway public IP. WAF inspects; App GW terminates
   TLS and adds `X-Forwarded-For` with the client IP.
2. App GW connects to its backend pool = the NVA's **trust** NIC IP (10.0.2.10)
   on port 80. No UDR on the App GW subnet — App GW just sees a normal backend.
   This avoids the App-Gateway-UDR-to-virtual-appliance fragility design-3 hit.
3. NVA iptables PREROUTING DNATs `trust:80` → `webserver:80` and emits the
   packet out the DMZ NIC. POSTROUTING MASQUERADEs the source to the NVA's DMZ
   IP so the webserver's reply comes straight back to the NVA (not via any
   alternative VNet path).
4. Reply: webserver → NVA DMZ → conntrack reverses both NATs → out trust NIC
   → App GW → client.

**Egress** `webserver → NVA DMZ → iptables filter → NVA trust → Internet`
1. Webserver originates an outbound connection (apt, monitoring agent, etc.).
2. `snet-dmz` UDR sends `0.0.0.0/0` → NVA DMZ IP. Packet arrives at DMZ NIC.
3. NVA iptables FORWARD chain enforces the egress allow-list (see below). If
   permitted, POSTROUTING MASQUERADE on the trust NIC SNATs to the NVA's public
   IP → Internet.
4. Return packet hits the NVA's public IP, Azure DNATs to the NVA, conntrack
   reverses, packet returns to webserver via the DMZ NIC.

**Management** `admin → NVA trust PIP → ssh`
- NVA trust NIC has a public IP, locked to `allowed_ssh_cidr`. Same pattern as
  design-1's NVA management.
- Webserver has no public IP. Reach it via `ssh -J` ProxyJump through the NVA,
  same pattern `validate-flows.sh` already implements for design-2.

## What the egress filter actually filters

iptables on the NVA is L3/L4. For the lab, the egress allow-list will be:

| Layer | Rule | Reason |
|---|---|---|
| FORWARD | `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` | return traffic for permitted flows |
| FORWARD | `-s snet-dmz -p udp --dport 53 -j ACCEPT` | DNS |
| FORWARD | `-s snet-dmz -p udp --dport 123 -j ACCEPT` | NTP |
| FORWARD | `-s snet-dmz -p tcp -m multiport --dports 80,443 -j ACCEPT` | HTTP / HTTPS to anywhere |
| FORWARD | default | DROP |

That's functionally **L4 allow-listing**, not FQDN allow-listing. design-2/3
have FQDN matching via Azure Firewall's application rules; iptables does not
natively. Three options if you want the FQDN parity later:

1. **Squid forward proxy on the NVA**, listening on the DMZ-facing interface,
   with a domain whitelist; configure the webserver's apt + curl to use it via
   `http_proxy`. Real FQDN allow-listing for explicit-proxy clients.
2. **`ipset` + DNS resolution loop** (e.g. `dnsmasq` populating an ipset from
   allowed FQDN resolutions; iptables matches on the ipset). Works transparently
   but fragile when DNS TTLs are short or the destination uses many IPs.
3. **Accept the L4-only limitation** for this design, document it, and point at
   design-2 for FQDN-aware egress.

Recommendation: ship design-4 with the L4 allow-list and clearly document that
FQDN filtering = Azure Firewall (design-2/3) or Palo Alto. If Patrick wants the
FQDN parity in design-4, option 1 (Squid) is the right add — it's an additional
~80 lines of cloud-init. **Open question for the review.**

## Patrick's "webserver looks like it's on the internet" concern

Re-reading the transcript, Patrick was reacting to how the diagram presents
design-3 — the webserver looks externally exposed because the App Gateway
public IP is "in front of" it. In all designs (2, 3, 4) the webserver has **no
public IP** and is only reachable via the inbound path through firewalls/WAF.
design-4 makes this even more legible:

- Webserver lives in `snet-dmz`, no public IP, no route to the Internet except
  via the NVA's DMZ NIC.
- App Gateway connects to the NVA, not the webserver — the webserver IP isn't
  in App GW's backend pool, so a topology diagram literally shows two firewall
  layers (WAF + NVA) between the Internet and the webserver.

## Tradeoffs vs the existing designs

| | design-1 | design-2 | design-3 | **design-4** |
|---|---|---|---|---|
| Inbound firewall | active/active NVAs | active/active NVAs | Azure Firewall (1 NIC) | **single NVA (2 NICs)** |
| Egress firewall | none | Azure Firewall | Azure Firewall | **same NVA** |
| Firewall interfaces | 2 per NVA | 2 per NVA + 1 AzFW | 1 | **2** |
| Symmetric flows | yes (NVA SNAT) | yes | yes | **yes (single NVA, no LB)** |
| HA | yes (active/active) | yes | yes (PaaS) | **no (single VM)** |
| Throughput ceiling | sum of 2 VMs | sum of 2 VMs | scales auto | **one VM size** |
| FQDN allow-list | n/a | yes (Azure FW app rules) | yes | **L4 only** (Squid optional) |
| Managed threat intel | no | yes | yes | **no** |
| Customer-managed surface | NVA OS x2 | NVA OS x2 | none | **NVA OS x1** |

The big tradeoff is **HA**: design-4 has one VM. If it goes down, both inbound
and egress fail. Mitigations to discuss:

- **Active/standby NVA pair** (design-1's third egress option) — two NVAs, only
  one in the data path at a time, manual or scripted failover. Doubles the VM
  cost; doesn't introduce LB asymmetry.
- **VM Scale Set + auto-rebuild** — single instance with Azure replacing it on
  failure. Minutes of downtime on failure; cheaper than active/standby.
- **Accept SPOF for the lab** and document that production would use the Palo
  Alto VM-Series pair (with vendor-supported HA), which is what the client
  actually runs.

For an initial design-4 to review I propose **single instance**, with the HA
options listed as follow-ons. Patrick's ask was specifically about interface
count, not HA.

## Cost estimate (US East, 24/7)

| Resource | ~$/mo |
|---|---|
| App Gateway WAF_v2 (idle, autoscale min=0) | ~$320 |
| 1× NVA + 1× webserver (B2s) | ~$60 |
| 2× OS disks | ~$3 |
| 1× NVA management PIP (also egress SNAT) | ~$4 |
| 1× App GW public IP | ~$4 |
| **Total** | **~$391/mo** |

Versus the other designs:

| Design | ~$/mo | vs design-4 |
|---|---|---|
| design-1 (no egress firewall) | ~$444 | +$53 |
| design-2 (NVA pair + Azure FW) | ~$1,360 | +$969 |
| design-3 (Azure FW both ways) | ~$1,272 | +$881 |
| **design-4 (single NVA both ways)** | **~$391** | — |

**design-4 is the cheapest design AND the only one that closes the egress gap
without Azure Firewall.** The savings vs design-2/3 are ~$900/mo entirely
because Azure Firewall is gone. App Gateway WAF_v2 is still the dominant cost
at ~$320/mo (`terraform destroy` between sessions, ~10–15 min cold apply).

## Open questions for the review

1. **FQDN egress filtering — required, optional, or skip?** L4-only ships with
   the base design; Squid forward proxy adds real FQDN allow-listing at the
   cost of more cloud-init complexity.
2. **HA — accept the SPOF or build active/standby from the start?** I'd lean
   toward accepting SPOF for design-4 and treating active/standby as design-4b.
3. **NVA size.** B2s is fine for the lab. Real client workload sizing depends
   on throughput requirements — out of scope for the lab unless Patrick wants a
   throughput-tuned variant.
4. **Naming the zones.** design-1 used "trust" for the App-GW-facing NIC and
   "dmz" for the webserver-facing NIC — that's backwards from standard NGFW
   terminology (where trust = inside). I'd keep design-1's terms for repo
   consistency unless Patrick prefers the standard inversion.

## Build plan (after review approval)

If approved, design-4 builds out as:

```
proposed-working-design-4/
├── DESIGN.md              (this doc)
├── README.md              full topology + cost + test commands
├── EXPLANATION.md         client-facing rationale (parallels design-2/3)
├── VERIFIED.md            empty initially; filled by validate-flows.sh
├── versions.tf            (copy from design-1)
├── variables.tf           subnets, NVA IPs, allowed_ssh_cidr, egress mode
├── main.tf                RG + VNet + 3 subnets (same as design-1)
├── network-security.tf    trust + DMZ NSGs (same as design-1)
├── nva.tf                 1× Linux VM, 2 NICs, mgmt PIP
├── nva.yaml.tftpl         iptables: DNAT inbound + egress allow-list + MASQUERADE
├── route-tables.tf        rt-dmz: 0.0.0.0/0 → NVA DMZ IP
├── appgateway.tf          same as design-1 but backend pool = NVA trust IP
├── webserver.tf           same as design-1/2/3 (single VM, no PIP)
├── webserver.yaml.tftpl   nginx /healthz /whoami, hardened apt retry loop
├── outputs.tf             APPGW pub IP, NVA pub IP, webserver IP, test commands
└── terraform.tfvars.example
```

`validate-flows.sh` already handles design-2 and design-3; extending it to
auto-detect design-4 (look for NVA pub IP **without** a firewall pub IP) is a
~5-line change at the top.

Estimated build time: **2–3 hours** (most of the iptables cloud-init can be
adapted from design-1's `nva.yaml.tftpl`; egress chain is new).

## Status

- ✓ Design reviewed by Joey
- ✓ Open questions resolved (#1 FQDN filter: skipped; #2 HA: single NVA; #3: 3 NICs)
- ✓ Terraform built — `terraform validate` clean. See [README.md](README.md) and the rest of this directory for the deployable artifact.
- ☐ Deployed & verified via `validate-flows.sh proposed-working-design-4`
