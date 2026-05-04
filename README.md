# Clientm Network Lab — App GW in front of Active/Active NVAs

A Terraform lab that builds the recommended Azure pattern for "App Gateway WAF
in front of an active/active firewall pair, with the firewalls protecting a
backend webserver." The previous attempt (App GW NATed *behind* the firewalls)
is archived under `current-broken-state/`.

## Topology

```
Internet
   │
   ▼  HTTPS:443
┌─────────────────────────────────────────┐
│ App Gateway WAF_v2                      │
│  • Public IP                            │  snet-appgateway 10.0.1.0/24
│  • Self-signed cert listener            │
│  • Adds X-Forwarded-For with client IP  │
│  • Backend pool = Internal LB (10.0.2.4)│
└────────────────┬────────────────────────┘
                 │ HTTP:80 (lab; HTTPS in prod)
                 ▼
┌─────────────────────────────────────────┐
│ Internal Load Balancer (Standard)       │  snet-trust 10.0.2.0/24
│  • Private frontend 10.0.2.4            │
│  • TCP:443 + TCP:80 rules, SourceIP     │
│  • Probe TCP:22 (sshd)                  │
└──────┬──────────────────────────┬───────┘
       │                          │
   ┌───▼───┐                  ┌───▼───┐
   │ NVA1  │  Linux/iptables  │ NVA2  │  trust NIC: 10.0.2.10 / .11
   │       │  active/active   │       │  dmz   NIC: 10.0.3.20 / .21
   │ DNAT inbound :443 → webserver       │
   │ SNAT on DMZ NIC → symmetric return  │
   └───┬───┘                  └───┬───┘
       │                          │
       └──────────┬───────────────┘
                  ▼  (same DMZ subnet, no LB on the return path)
       ┌──────────────────────┐
       │ Webserver            │  snet-dmz 10.0.3.0/24
       │ 10.0.3.100           │
       │ nginx /healthz       │
       │      /whoami (XFF)   │
       └──────────────────────┘
```

## Why this is symmetric

- App GW connects once to `10.0.2.4`, the Internal LB rewrites dst to a
  specific NVA's trust IP, and **the same LB sees the return** — its native
  connection-tracking rewrites the source back to `10.0.2.4` for the App GW.
- The NVA SNATs on its DMZ-side egress, so the webserver replies directly to
  the NVA's DMZ IP. **No LB hashes the return path.** The same NVA that
  processed the inbound owns the return.
- The webserver only ever sees connections from one IP per NVA — its routing
  is trivial and does not need any UDR.

## What about the original client IP?

App GW v2 automatically adds `X-Forwarded-For` with the client's real IP. The
NVA preserves it as opaque payload (it's an HTTP header, not L3/L4), and the
webserver can read it. `/whoami` shows it.

A Palo Alto in this position would do the same — reference XFF for any
client-IP-based policy rather than relying on the L3 source IP (which will be
the NVA's DMZ IP after SNAT).

## Cost (US East, 24/7)

| Resource | ~$/mo |
|---|---|
| 2× NVA + 1× webserver (B2s) | ~$90 |
| 3× OS disks | ~$5 |
| 2× NVA mgmt public IPs + 1× App GW public IP | ~$11 |
| Internal Standard LB | ~$18 |
| **App Gateway WAF_v2** (idle, autoscale min=0) | **~$320** |
| **Total** | **~$444/mo** |

The App Gateway dominates. `terraform destroy` between sessions saves real
money; `apply` from cold takes ~8–10 min.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit: paste your SSH public key, your public IP /32

terraform init
terraform plan
terraform apply
```

## Test

```bash
APPGW=$(terraform output -raw appgw_public_ip)

# Health
curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
  https://connect.clientmworkspace.com/healthz

# X-Forwarded-For verification
curl -sk --resolve connect.clientmworkspace.com:443:$APPGW \
  https://connect.clientmworkspace.com/whoami
```

The `/whoami` response should show:
- `remote_addr`: NVA's DMZ IP (10.0.3.20 or .21) — the SNATted source
- `x-forwarded-for`: your real public IP — preserved by App GW

## Tear down

```bash
terraform destroy
```

## File map

| File | Purpose |
|---|---|
| `versions.tf` | Provider pins |
| `variables.tf` | Inputs + IP plan defaults |
| `main.tf` | RG, single VNet, three subnets |
| `network-security.tf` | NSGs (trust, DMZ); App GW subnet has none (managed by AppGW) |
| `nva.tf` | 2× Linux NVA VMs with trust + DMZ NICs |
| `nva.yaml.tftpl` | iptables/PBR cloud-init (NIC detection by subnet) |
| `internal-lb.tf` | Internal Standard LB |
| `appgateway.tf` | App Gateway WAF_v2 |
| `webserver.tf` | DMZ webserver |
| `webserver.yaml.tftpl` | nginx + self-signed cert |
| `outputs.tf` | Useful IPs and test one-liners |
| `current-broken-state/` | The previous (non-working) "App GW behind firewalls" attempt |
