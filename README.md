# Clientm Asymmetric Routing Lab

A Terraform reproduction of the Clientm Azure topology so you can poke at the asymmetric routing bug in isolation. Mirrors the prod design from the meeting notes and the App Gateway JSON: external LB → 2x active/active firewall NVAs → internal LB → App Gateway WAF_v2 → webserver.

## What this is (and isn't)

**Is:** a cheap, broken-by-default reproduction of the routing problem so you can prove the failure mode and validate fixes without touching the customer's environment.

**Isn't:** a Palo Alto deployment. Palo Alto VMs in Azure are ~$1.50/hr just for licensing. This uses **Linux + iptables** to provide the same stateful-firewall + NAT semantics that drive the asymmetric routing bug. The bug is a property of stateful firewalls + load balancer hashing, not of Palo Alto specifically — so iptables reproduces it faithfully.

## Cost estimate (running 24/7, US East)

| Resource | Approx. monthly |
|---|---|
| 2x NVA VMs (B1s) | $15 |
| 1x Webserver VM (B1s) | $7.50 |
| 3x OS disks (Standard HDD 30GB) | ~$5 |
| 3x Public IPs (Standard) | ~$11 |
| External Standard LB | ~$18 |
| Internal Standard LB | ~$18 |
| **App Gateway WAF_v2** (idle) | **~$320** |
| **Total** | **~$395/mo** |

The App Gateway is the cost dominator. **Run `terraform destroy` between test sessions** — bringing the lab back up takes about 8 minutes and saves ~$10/day.

If you only need to reproduce the asymmetric routing bug (not the full path through AppGW), you can comment out `appgateway.tf` and drop the cost to ~$75/month.

## Topology (matches the diagram you uploaded)

```
                   Internet
                       │
              ┌────────┴────────┐
              │ External LB     │  Standard, public IP
              │ (front)         │  443/tcp
              └────┬───────┬────┘
                   │       │
            ┌──────┘       └──────┐
            │                     │
         ┌──┴──┐               ┌──┴──┐
         │NVA1 │               │NVA2 │  Linux + iptables
         │     │   active/active│     │  (Palo Alto stand-ins)
         └──┬──┘               └──┬──┘
            │                     │
            └──────────┬──────────┘
                       │
              ┌────────┴────────┐
              │ Internal LB     │  10.29.252.100
              │ (back)          │  ◀── DMZ default route here
              └────────┬────────┘
                       │
              ┌────────┴────────┐
              │ App Gateway     │  10.28.255.150 (private listener)
              │ WAF_v2          │  Probe: /healthz on connect.clientmworkspace.com
              └────────┬────────┘
                       │
              ┌────────┴────────┐
              │ Webserver       │  10.29.254.250
              │ nginx + /healthz│  DMZ subnet
              └─────────────────┘
```

## Prerequisites

- Terraform ≥ 1.5
- Azure CLI logged in (`az login`) with Contributor on a subscription
- An SSH keypair (`ssh-keygen -t ed25519` if you don't have one)
- Your public IP (`curl ifconfig.me`)

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars - paste your SSH public key and your public IP /32

terraform init
terraform plan
terraform apply
```

First apply takes ~8-10 minutes (App Gateway is the slow one).

## Reproducing the asymmetric routing bug (default state)

After `apply` settles, the lab is **broken on purpose**. Here's how to see the bug:

```bash
# Grab the front LB IP from outputs
FRONT_LB=$(terraform output -raw external_lb_public_ip)

# Send a request - it'll either hang or return after retries fail
curl -kv --max-time 10 \
  --resolve connect.clientmworkspace.com:443:$FRONT_LB \
  https://connect.clientmworkspace.com/healthz
```

To see exactly where it dies, SSH to both NVAs in parallel and run:

```bash
# On NVA1
sudo tcpdump -i any -nn 'host 10.29.254.250 and port 443'

# On NVA2 (same command)
sudo tcpdump -i any -nn 'host 10.29.254.250 and port 443'

# On either
sudo conntrack -E -p tcp --dport 443    # live conntrack events
```

You'll see the SYN arrive on NVA1, get DNAT'd to the webserver, the webserver's SYN-ACK route through the internal LB, and land on NVA2 — which has no conntrack entry and drops it. Classic asymmetric routing.

There's a helper installed on each NVA: `sudo nva-trace` shows iptables counters and recent conntrack entries.

## Validating fixes

Three fixes worth testing, in order of "what the customer should actually do":

### Fix 1: HA Ports + Floating IP on the internal LB

Open `internal-lb.tf`. Comment out the `azurerm_lb_rule.internal_443` block and uncomment the `azurerm_lb_rule.internal_haports` block. Run `terraform apply`. Re-run the curl test.

This makes the internal LB forward all ports/protocols and preserves the original destination IP, so the NVAs see the flow as a single 5-tuple and the LB can hash consistently.

### Fix 2: SNAT on the NVAs

Open `cloud-init/nva.yaml.tftpl`. Find the "Toggle for the FIX" section near the bottom of `nva-firewall.sh` and uncomment the `iptables -t nat -A POSTROUTING -o eth1 ...` line. Run `terraform apply` (or just SSH and re-run the script).

With SNAT, the webserver replies go back to the NVA's internal IP rather than the original client IP, so Azure routing sends them straight back through the same NVA. Symmetric. The trade-off: the webserver sees the NVA's IP as the source, not the real client IP — fine for most apps, breaks anything that does source-IP based logic.

### Fix 3: Gateway Load Balancer

Not in this repo (would need a separate construct). The "Microsoft-recommended" gateway LB approach the customer mentioned trying. Worth knowing it exists; usually fix 1 or 2 lands first.

## Switching to "Prevention" WAF mode

The lab WAF policy is in **Detection** mode by default so you don't fight false positives while debugging routing. Once routing works, flip `mode` in `appgateway.tf` (`azurerm_web_application_firewall_policy.appgw.policy_settings.mode`) to `"Prevention"` to mirror prod.

## Tearing down

```bash
terraform destroy
```

App Gateway takes 5-7 minutes to delete. Be patient.

## File map

| File | Purpose |
|---|---|
| `versions.tf` | Provider pins |
| `variables.tf` | All inputs, with defaults matching the prod IP plan |
| `main.tf` | RG + VNet + subnets |
| `network-security.tf` | NSGs |
| `route-tables.tf` | UDRs (the DMZ default route is what triggers the bug) |
| `nva.tf` | 2x Linux NVAs with stateful iptables |
| `external-lb.tf` | Front (public) Standard LB |
| `internal-lb.tf` | Back (private) Standard LB — flip rule here for fix #1 |
| `appgateway.tf` | App Gateway WAF_v2 mirroring the prod JSON |
| `webserver.tf` | DMZ webserver (nginx + /healthz) |
| `outputs.tf` | Useful IPs and test commands |
| `cloud-init/nva.yaml.tftpl` | iptables setup — flip SNAT line for fix #2 |
| `cloud-init/webserver.yaml.tftpl` | nginx + self-signed cert |
