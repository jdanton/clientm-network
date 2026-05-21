# What Was Broken and What We Fixed

A client-facing explanation of the routing fix delivered in this design.

## The problem (one sentence)

The firewalls were dropping legitimate web traffic because **return packets were coming back through a different firewall than the one that handled the original request**, and stateful firewalls treat that as suspicious and block it.

## Original (broken) design

```
Internet → Firewall pair (active/active) → App Gateway → Webserver
```

- A client request arrives; the load balancer in front of the firewall pair picks **Firewall A**.
- Firewall A passes the request through to App Gateway, then to the webserver.
- The reply comes back — but Azure's load balancer hashes the return traffic and may send it through **Firewall B**.
- Firewall B has no record of the original conversation in its state table → drops the packet as unsolicited.
- Result: connections silently fail, the application "works sometimes" depending on which firewall gets chosen, and the firewall logs are full of asymmetric-routing alerts.

## New (working) design

```
Internet → App Gateway → Internal Load Balancer → Firewall pair (active/active) → Webserver
```

- The App Gateway sits at the public edge, terminates TLS, and forwards the request to **one fixed address** — the Internal Load Balancer (`10.0.2.4`).
- The Internal LB picks a firewall (say, **Firewall A**) and remembers the choice for this connection.
- Firewall A rewrites the source address (SNAT) before forwarding to the webserver, so **the webserver replies directly back to Firewall A's address**, not to the LB.
- Firewall A returns the packet to the LB, which sees the matching conversation in its connection table and sends it back to App Gateway → back to the client.
- **The same firewall handled both directions.** Stateful inspection works as designed.

## Why this fix works (the one-line version)

> By moving the App Gateway *in front of* the firewall pair instead of *behind* it, and letting the firewalls SNAT on egress, we guarantee that the same firewall sees both directions of every conversation.

## What we verified

Deployed the new design in Azure and ran an end-to-end test:

```
curl https://connect.clientmworkspace.com/healthz   →   200 OK
```

The request traveled client → App Gateway public IP → Internal LB → NVA firewall → webserver, and the response came back along the same path. No drops, no resets, no asymmetric-route warnings.

## What this means in practice

- No more dropped connections from asymmetric routing.
- Both firewalls actively pass traffic — full active/active HA, not active/standby.
- WAF protection (Azure Application Gateway WAF_v2) sits at the public edge, where it can inspect traffic before it ever reaches the internal network.

## Known limitations — webserver egress is NOT firewalled

This design fixes **inbound** client traffic only. The webserver's own **outbound-initiated** connections (package updates, outbound API calls, anything the webserver initiates to the Internet) bypass the firewall pair entirely and exit via Azure's default Internet path.

The original (broken) design had a route table forcing webserver egress through the firewalls. We removed that on purpose: re-adding it would recreate the **same asymmetric-routing failure mode** we just eliminated — only on the egress leg. The load balancer would hash webserver-originated flows to one NVA, return traffic could land on the other, and stateful inspection would fail.

**If egress inspection (DLP, C2 callback detection, allow-listed outbound) is a real requirement, this design is incomplete.** Three real options to close the gap, in increasing scope:

| Option | What changes | Tradeoff |
|---|---|---|
| **Azure Firewall (PaaS) for egress** | Add managed Azure Firewall; UDR webserver egress to it | Operationally simplest. ~$900/mo extra. Different product from the inbound firewalls. |
| **Gateway Load Balancer** in front of the NVA pair | Replace the Standard LB with GWLB | Azure-recommended LB type for NVAs; gives symmetric flows in both directions natively. Requires GENEVE-aware cloud-init on the NVAs. |
| **Active/standby NVA pair** | Single NVA owns all flows; partner takes over on failure | Eliminates the hashing problem entirely. Gives up half your throughput. Closest to traditional Palo Alto HA. |

A follow-on engagement should pick one and scope it.

## Why those three options actually work

All three close the egress gap, but they fix the underlying asymmetric-routing problem in fundamentally different ways. The general rule is:

> **Asymmetric routing is only a problem when you have independent stateful devices that can't see each other's flows.**

Each option attacks one part of that sentence.

### Where the problem comes from

Two independent stateful firewalls (a Palo Alto pair, or our Linux NVAs running iptables) each maintain their own private connection-tracking table. Put them behind a Standard Load Balancer and:

- LB hashes inbound on the 5-tuple → lands on **NVA A** → NVA A's conntrack records the flow
- LB hashes the return packet on a *different* 5-tuple (the webserver's reply has different source IP+port) → lands on **NVA B**
- NVA B has no record of that conversation → drops it as INVALID

The hashing isn't the bug. The bug is that **the two NVAs can't see each other's state.**

### Azure Firewall — make the devices see each other

- Underneath, Azure Firewall is a horizontally-scaled cluster of instances on a Microsoft-managed scale unit.
- Those instances **share session state** via an internal synchronization mechanism that Microsoft does not expose.
- From the customer's view there's a single private IP. UDRs point at *that one IP*, not at a load balancer in front of multiple firewalls.
- Any instance can handle return traffic for a flow another instance opened, because they all see the same conntrack.

Same flow, different instance on return → still finds the state → doesn't drop.

### Gateway Load Balancer — make the LB stop spreading flows

- GWLB uses **GENEVE encapsulation**: each packet is tagged with a flow identifier the LB can read.
- The GWLB uses that tag to **deterministically pin both directions of a flow to the same NVA**.
- Independent state tables on the NVAs stay fine, because the same NVA always sees both halves of every conversation.

This is the Azure-recommended LB type for NVAs precisely because it solves this problem natively, but..

Gateway Load Balancer is the right tool for inline NVA insertion in an NVA first topology. However, since App Gateway v2 does not currently support GWLB chaining on its frontend IP, it cannot be used to resolve the asymmetry in your current design. 

### Active/standby — remove the second device

- Only one NVA is ever in the data path at a time. The partner takes over on failure.
- Trivially symmetric — there is no "other firewall" for traffic to land on by mistake.
- Closest pattern to how a traditional Palo Alto HA pair runs on-prem.
- Tradeoff: you pay for two firewalls and use the throughput of one.
