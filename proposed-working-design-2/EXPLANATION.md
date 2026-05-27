# Closing the Egress Gap with Azure Firewall

A client-facing explanation of what design-2 adds on top of design-1.

## What design-1 left open

design-1 fixed the **inbound** problem: client traffic now reaches the webserver
through the firewall pair without the asymmetric-routing drops that plagued the
original "App Gateway behind the firewalls" topology.

But it called out one gap explicitly: the webserver's own **outbound** traffic —
package updates, outbound API calls, and (the security concern) any malware
callback or data exfiltration — bypassed the firewalls entirely and went
straight to the Internet over Azure's default path. There was no egress
inspection.

We did not simply re-point the webserver's default route at the existing NVA
pair, because that recreates the very failure design-1 eliminated — just on the
outbound leg. The load balancer in front of the two NVAs would hash the
webserver's outbound flow to one NVA and the return packet to the other; the
second NVA has no record of the conversation and drops it. (That is documented
in design-1's `current-broken-state/`.)

## What design-2 adds

```
Webserver ──0.0.0.0/0──► Azure Firewall ──SNAT──► Internet
                          (egress inspection)
```

We add an **Azure Firewall** in its own subnet and put a single default route on
the webserver's subnet pointing at it. Now every Internet-bound packet the
webserver originates is inspected against an allow-list before it is allowed
out, and is source-NAT'd to the firewall's public IP. The inbound path from
design-1 is completely untouched — only the webserver's outbound default route
changed.

The firewall enforces two layers of allow-list:

- **Network rules (L3/L4):** only DNS and NTP are allowed at the port level.
- **Application rules (L7):** outbound HTTP/HTTPS is allowed only to a named list
  of fully-qualified domain names (e.g. the OS update repositories). A callback
  to an attacker-controlled host is not on the list, so it is denied and logged.

## Why Azure Firewall stays symmetric where an NVA pair would not

This is the key reason Azure Firewall is the right tool to close the egress gap,
and it is the same reasoning design-1 gave for why it works:

> **Asymmetric routing is only a problem when you have independent stateful
> devices that can't see each other's flows.**

Two independent NVAs behind a load balancer each keep their own private
connection-tracking table, so a flow opened on one and returned to the other
gets dropped. Azure Firewall removes that precondition:

- Under the hood it is a horizontally-scaled cluster of instances on a
  Microsoft-managed scale unit.
- Those instances **share session state** through an internal mechanism Microsoft
  does not expose.
- From our side there is a **single private IP**. The route table points at that
  one IP, not at a load balancer spreading traffic across independent devices.
- Any instance can handle the return half of a flow another instance opened,
  because they all see the same session table.

Outbound flow hashed to instance A, return packet hashed to instance B → B still
finds the state → no drop. Symmetric by construction. No GENEVE encapsulation,
no active/standby throughput penalty, no cloud-init tricks on our side.

## Trade-offs we are accepting

- **Cost.** Azure Firewall Standard is ~$912/month just to exist, billed by the
  hour whether or not traffic flows. It becomes the single largest line item in
  the lab — larger than the Application Gateway. This is the price of a managed,
  always-symmetric egress firewall. (`terraform destroy` between sessions.)
- **It is a different product from the inbound NVAs.** Inbound is still the
  Linux/iptables NVA pair (standing in for a Palo Alto); egress is Azure
  Firewall. Two control planes, two rule formats. If a single-vendor NGFW for
  both directions is a requirement, that is a larger redesign (e.g. Palo Alto
  VM-Series with Gateway Load Balancer), not this lab.
- **No TLS inspection.** Standard tier filters on SNI/FQDN, not decrypted
  payload. If you need to inspect inside HTTPS, that is the Premium tier (~2×
  the cost) and a separate decision.

## What still needs verifying

design-1 is deployed and tested live. design-2 is written and validates cleanly
but has **not** been deployed yet. See [VERIFIED.md](VERIFIED.md) for the
specific checks to run once it is applied.
