# One Firewall for Both Directions

A client-facing explanation of design-3 and how it differs from design-2.

## The question this answers

> "If we're paying for an Azure Firewall anyway, why also keep the NVA pair?"

design-2 keeps the active/active firewall pair (the Palo Alto stand-in) for
**inbound** traffic and adds Azure Firewall only for **outbound**. That is the
right answer *if the Palo Alto pair is a hard requirement.*

design-3 takes the other path: **remove the NVA pair and the internal load
balancer entirely**, and let one Azure Firewall inspect both directions. The
Application Gateway WAF stays at the public edge for L7 web protection.

```
design-2:  Internet → App GW WAF → Internal LB → NVA pair → webserver → Azure Firewall → Internet
design-3:  Internet → App GW WAF → Azure Firewall → webserver → Azure Firewall → Internet
```

## Why one firewall can safely do both directions

design-1's whole saga was that **two independent stateful firewalls behind a
load balancer** drop traffic when the load balancer sends the two halves of a
conversation to different firewalls (asymmetric routing). The fix in design-1
was careful SNAT on the NVAs; design-2 avoided re-creating the problem on egress
by using Azure Firewall there.

Azure Firewall removes the precondition for the problem in **both** directions:

- It is a managed, horizontally-scaled cluster behind a **single private IP**.
- Its instances **share one session table**.
- We point route tables (UDRs) at that single IP, so there is no load balancer
  spreading a flow across devices that can't see each other's state.

So the same reasoning that made Azure Firewall safe for egress in design-2 makes
it safe for the inbound leg here. We force both legs of the inbound flow
(App Gateway ⇆ webserver) through the firewall with UDRs, and because the
firewall does not source-NAT internal traffic, the webserver's reply is routed
straight back through the firewall to the App Gateway. Same flow, shared state,
no drops.

## What we gain

- **One firewall product, not two.** A single rule base and control plane for
  inbound and outbound, instead of an iptables/Palo Alto pair *plus* Azure
  Firewall.
- **Fewer moving parts.** Two firewall VMs and a load balancer disappear. No
  cloud-init NAT scripting, no NVA patching, no failover to reason about — Azure
  Firewall is managed and zone-redundant.
- **Native symmetry in both directions**, by construction.
- **Retires the Palo Alto licensing** (not on the Azure bill, but real money).

## What we give up

- **Palo Alto's feature set.** Azure Firewall Standard does L3/L4 + FQDN
  filtering and basic threat intel, not App-ID, full IDS/IPS, or the policy
  ecosystem an enterprise Palo Alto deployment provides. If the security team
  standardizes on Palo Alto, that is a strong reason to stay on design-2.
- **Deep inbound HTTP inspection beyond the WAF.** For the inbound web leg, the
  Application Gateway WAF is still doing the heavy L7 lifting (OWASP rules);
  Azure Firewall adds network-level control and central logging, not HTTP
  payload inspection. (Premium tier adds TLS inspection / IDPS at ~2× the cost.)

## Cost reality

Both designs are dominated by the App Gateway (~$320/mo) and the Azure Firewall
(~$912/mo). design-3 saves only ~$90/mo on the Azure bill (two NVA VMs + the load
balancer). **The case for design-3 is operational simplicity and retiring Palo
Alto licensing, not the Azure line item.**

## Recommendation framing for the client

- **Keep design-2** if the Palo Alto pair is a standard / compliance / feature
  requirement. You keep your firewall investment and inspection capabilities;
  Azure Firewall just closes the egress gap.
- **Move to design-3** if the goal is to consolidate on Azure-native managed
  services, cut operational overhead, and you're comfortable with Azure Firewall
  Standard's feature set for this workload.

## What still needs verifying

Not yet deployed. The inbound-through-firewall routing (App Gateway UDR to the
firewall) is the part to validate first on deploy — see [VERIFIED.md](VERIFIED.md).
