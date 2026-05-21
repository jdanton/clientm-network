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
