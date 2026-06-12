# Clientm Network Lab — design-4: single multi-NIC Linux NVA, both directions

design-4 answers Patrick's 2026-06-12 ask: **the firewall should have multiple
interfaces, like a real NGFW** (Azure Firewall has only one). A single Linux
NVA with **three NICs** — `untrust` / `trust` / `dmz` — replaces Azure Firewall
entirely and inspects both inbound and egress.

> See [DESIGN.md](DESIGN.md) for the review document this build came from.

| | design-1 | design-2 | design-3 | **design-4 (this)** |
|---|---|---|---|---|
| Inbound firewall | active/active NVAs | active/active NVAs | Azure Firewall (1 NIC) | **single NVA (3 NICs)** |
| Egress firewall | none | Azure Firewall | Azure Firewall | **same NVA** |
| Firewall interfaces | 2 per NVA | 2 per NVA + 1 AzFW | 1 | **3** |
| FQDN allow-list | n/a | yes (AzFW) | yes (AzFW) | **L4 only** |
| HA | active/active | active/active | yes (PaaS) | **no (single VM)** |
| ~$/mo | ~$444 | ~$1,360 | ~$1,272 | **~$391** |

> **Status:** `terraform validate`-clean, **not yet deployed.** See
> [VERIFIED.md](VERIFIED.md).

## Topology

```
Internet
   │  HTTPS:443
   ▼
┌──────────────────────────────────────┐
│ App Gateway WAF_v2 (public IP)       │  snet-appgateway 10.0.1.0/24
└────────────────┬─────────────────────┘
                 │ backend = NVA trust IP 10.0.2.10
                 ▼
┌─────────────────────────────────────────────────────────┐
│   Linux NVA  (single VM, 3 NICs, iptables)              │
│                                                         │
│   eth0  untrust  10.0.4.10  ← snet-untrust 10.0.4.0/24  │
│                  • public IP (mgmt + egress SNAT)       │
│                  • POSTROUTING MASQUERADE → !RFC1918    │
│                                                         │
│   eth1  trust    10.0.2.10  ← snet-trust   10.0.2.0/24  │
│                  • App Gateway backend target           │
│                  • PREROUTING DNAT :80/:443 → webserver │
│                                                         │
│   eth2  dmz      10.0.3.10  ← snet-dmz     10.0.3.0/24  │
│                  • webserver-facing                     │
│                  • POSTROUTING SNAT for inbound returns │
│                  • FORWARD filter for egress L4 ACL     │
└────────┬──────────────────────────┬─────────────────────┘
         │ inbound                  ▲ egress (UDR)
         ▼                          │
   ┌──────────────────────┐         │
   │ Webserver 10.0.3.100 │  snet-dmz 10.0.3.0/24
   │ nginx /healthz       │         │
   └──────────┬───────────┘         │
              └──────────────────────┘  0.0.0.0/0 → 10.0.3.10
```

## Why this stays symmetric (the design-1 lesson, applied)

design-1 explicitly refused to route egress through its NVA pair because doing
that with an LB-fronted active/active pair recreated the asymmetric-routing
failure: the LB would hash outbound flows to NVA-A and the return packets to
NVA-B, and NVA-B (with no conntrack for the flow) would drop them.

design-4 has **one** NVA. There is no LB on either leg. Every flow — inbound
or egress — touches the same iptables conntrack. Symmetric by construction.
This is design-1's "active/standby" option taken to its logical conclusion.

The trade is HA: a single NVA is a single point of failure. The design notes
in [DESIGN.md](DESIGN.md) list active/standby as the obvious follow-on.

## Traffic flows

**Inbound** `client → App GW → NVA trust → DNAT → NVA dmz → webserver`

1. Client connects to App Gateway public IP. WAF inspects; App GW terminates
   TLS and adds `X-Forwarded-For` with the client IP.
2. App GW connects to its backend pool = NVA trust IP (10.0.2.10:80). No UDR
   on the App GW subnet — App GW sees a normal backend.
3. NVA iptables PREROUTING DNAT on the trust NIC: `:80 → webserver:80`.
   POSTROUTING SNAT on the dmz NIC: source → NVA dmz IP. Out eth2 to webserver.
4. Webserver replies to the NVA dmz IP (same subnet). NVA conntrack reverses
   both NATs. Out the trust NIC to App GW → client.

**Egress** `webserver → snet-dmz UDR → NVA dmz → MASQUERADE → untrust → Internet`

1. Webserver originates outbound (apt, monitoring, etc.).
2. snet-dmz UDR sends `0.0.0.0/0` → NVA dmz IP. Packet enters NVA on eth2.
3. FORWARD chain enforces the L4 allow-list (see below). If permitted, the
   main routing table sends the packet out eth0 (untrust NIC).
4. POSTROUTING MASQUERADE on eth0 SNATs to the NVA's untrust private IP.
   Azure then SNATs to the NVA's public IP → Internet.
5. Return: Internet → NVA public IP → eth0 → conntrack un-NATs → out eth2 to
   webserver. Same conntrack saw both directions; nothing to drop.

**Management** `admin → NVA untrust public IP (eth0) → SSH`. Webserver has no
public IP — reach it via `ssh -J` ProxyJump through the NVA.

## Egress filter (L4 only — by decision)

iptables FORWARD chain rules for traffic sourced in `snet-dmz`:

| Rule | Allows |
|---|---|
| `--ctstate ESTABLISHED,RELATED` | return traffic for permitted flows |
| `-p udp/tcp --dport 53`  | DNS |
| `-p udp --dport 123`     | NTP |
| `-p tcp --dport 80`      | HTTP (any host) |
| `-p tcp --dport 443`     | HTTPS (any host) |
| (default) | DROP |

This is **port allow-listing**, not FQDN allow-listing. Per the review
decision, FQDN matching was deferred — design-2/3 use Azure Firewall application
rules for that, and the real client deployment will use Palo Alto. If FQDN
parity becomes a requirement, the right add is a Squid forward proxy on the
NVA (~80 more lines of cloud-init).

## Cost (US East, 24/7)

| Resource | ~$/mo |
|---|---|
| App Gateway WAF_v2 (idle, autoscale min=0) | ~$320 |
| 1× NVA + 1× webserver (B2s) | ~$60 |
| 2× OS disks | ~$3 |
| 1× NVA management/egress PIP | ~$4 |
| 1× App GW public IP | ~$4 |
| **Total** | **~$391/mo** |

**design-4 is the cheapest design that closes the egress gap** — about $970/mo
cheaper than design-2 and $880/mo cheaper than design-3, entirely because
Azure Firewall (~$912/mo) is gone. The App Gateway is now the dominant cost
again, so `terraform destroy` between sessions for that reason alone.

## First-deploy caveats

1. **No Azure Firewall** means no managed threat intel, no IDS/IPS, no FQDN
   matching — this is iptables L3/L4 only. That's a deliberate trade.
2. **Single NVA = single point of failure.** Acceptable for the lab and the
   stated review intent; production would use a vendor HA pair (Palo Alto VM-
   Series).
3. **Linux NIC ordering is by MAC/PCI, not Terraform list order.** `nva.yaml.tftpl`
   detects each NIC by which subnet its IP belongs to — same trick design-1
   used — so this works regardless of which physical NIC Azure happens to
   assign to which logical position.
4. **Main routing table default is forced via the untrust NIC** so forwarded
   egress (and the NVA's own outbound) leave through the only NIC with a public
   IP. The cloud-init deletes any extra default routes that DHCP installs.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit: paste your SSH public key, your public IP /32

terraform init
terraform plan
terraform apply
```

`resource_group_name`/`name_prefix` default to `*-d4` so design-4 can run
alongside design-1/2/3 without colliding.

## Test

`terraform output test_commands` prints the full set with live IPs. Or run
the automated flow validator from the repo root (it auto-detects design-4
once outputs are present):

```bash
../validate-flows.sh .            # from this directory, or
./validate-flows.sh proposed-working-design-4   # from the repo root
```

The validator asserts:
- inbound `/healthz` → 200 via App GW
- `/whoami` `remote_addr` is an NVA DMZ IP (proves traffic crossed the NVA + SNAT)
- `X-Forwarded-For` preserves the client IP
- webserver reachable via ProxyJump through the NVA
- egress `api.ipify.org` source IP == NVA public IP (egress SNAT proof)
- allow-listed port (HTTP) succeeds
- a non-allow-listed port (TCP/25) is blocked

## Tear down

```bash
terraform destroy
```

## File map

| File | Purpose |
|---|---|
| `DESIGN.md` | The review doc this build came from |
| `versions.tf` | Provider pins (same as other designs) |
| `variables.tf` | Inputs + subnet/IP plan (4 subnets, 3 NVA NIC IPs, webserver IP) |
| `main.tf` | RG, VNet, 4 subnets |
| `network-security.tf` | NSGs for trust/dmz/untrust; SSH allow on untrust |
| `nva.tf` | 1× Linux NVA with 3 NICs + untrust public IP |
| `nva.yaml.tftpl` | NIC detection by subnet, PBR, iptables NAT + L4 egress ACL |
| `route-tables.tf` | `rt-dmz`: 0.0.0.0/0 → NVA dmz IP |
| `appgateway.tf` | App GW WAF_v2; backend pool = NVA trust IP |
| `webserver.tf` | Webserver VM in snet-dmz, no public IP, `depends_on` NVA + DMZ UDR |
| `webserver.yaml.tftpl` | nginx + cert, apt retry loop (hardened pattern from design-3) |
| `outputs.tf` | App GW PIP, NVA PIP, NVA trust/dmz IPs, webserver IP, test commands |
