# A Private Front Door for the Application

A client-facing explanation of design-6: why the Application Gateway's front
door is a **private IP**, and what does and doesn't change versus design-5.

## What changed, in one line

design-5 put the App Gateway behind a **public** IP; design-6 puts it behind a
**private** IP (`10.0.1.10`). Everything else — WAF, the NVA inbound firewall,
the DNAT to the webserver, the Azure Firewall egress — is identical.

## Why a private front door

The application is **internal**. It should be reachable by the client's own
users and systems, but not exposed to the public Internet. A private-frontend
App Gateway gives you the WAF + firewall inspection chain with **no public entry
point at all** — clients arrive over:

- a peered VNet,
- a site-to-site VPN or ExpressRoute from on-prem,
- another workload already in the VNet.

That is the shape the client has been describing: an internal app, fronted by
a WAF, with the traffic passing through their firewalls — never published to
the Internet.

## The one Azure caveat we hit (and how design-6 handles it)

A **truly private-only** App Gateway on the WAF_v2 SKU requires a subscription
feature — `Microsoft.Network/EnableApplicationGatewayNetworkIsolation` — to be
registered first. Until it is, Azure rejects a WAF_v2 gateway that has no public
IP.

design-6 doesn't make you wait on that. A single switch, `appgw_private_only`:

- **off (default):** the private IP is the front door, with a public IP kept
  only as a lab escape hatch. Deploys today, no feature flag.
- **on:** the public IP disappears entirely — the real private-only target
  state, for once the feature is registered.

So the client can adopt the private front door immediately and flip to fully
private-only the moment their subscription has the feature enabled, with no
redesign — just `-var 'appgw_private_only=true'`.

## What does NOT change: where the health probe goes

This is the piece that caused the "the App Gateway probe never reaches my
firewall" confusion, so it's worth stating plainly:

> The App Gateway's health probe comes from the **gateway itself** and is sent
> to whatever is in the **backend pool**. It has nothing to do with the
> frontend IP.

Making the front door private does **not** change the probe path — we proved
this live on design-5: with the private frontend, the probe still landed on the
NVA (the backend) exactly as with the public frontend. If a client's probes
aren't hitting their firewall, the fix is in the **backend pool** (point it at
the firewall, not the web server's public IP), not the frontend. Full runbook:
[`../appgw-probe-firewall-runbook.md`](../appgw-probe-firewall-runbook.md).

## What we gain

- **No public attack surface** on the application front door — WAF + firewalls
  with zero Internet exposure.
- **Same inspection chain** the client already reviewed and validated on
  design-5 — this is a front-door change, not an architecture change.
- **A clean upgrade path** to fully private-only via one variable.

## What we give up / must plan for

- **Client reachability is now a networking problem.** A private front door is
  only useful if clients can route to it — peering, VPN, or ExpressRoute must be
  in place. In the lab that's the in-VNet test client; in production it's the
  client's existing connectivity.
- **HA on the inbound NVA** — unchanged from design-5. Single NVA; production
  would run a vendor HA pair.
- **The feature registration** for true private-only is a subscription-level
  action the client's Azure admins must take.

## Recommendation framing

- **Pick design-6** if the application is internal and must not have a public
  endpoint — which is what the private-IP testing has been driving at.
- **Stay on design-5** if a public entry point is actually required (external
  users hitting the app directly) — design-6's public fallback is exactly
  design-5, so there's no lock-in either way.

## Verification status

`terraform validate`-clean, both toggle states plan cleanly. **Not yet deployed
as design-6** — but the substantive change (private-IP front door) is already
**live-proven on design-5** (2026-06-23; see design-5's VERIFIED.md). A cold
`apply` of design-6 to confirm the private-primary boot path is the remaining
step. See [VERIFIED.md](VERIFIED.md).
