# Verification Log

## 2026-06-23 — private-frontend retest (dual-frontend App Gateway)

**Why:** a client reported App Gateway health probes never reaching their
firewall, and asked whether putting a **private IP on the App Gateway** changes
where the backend/probe traffic routes. We retested design-5 with that variant.

**Azure constraint found:** a **private-ONLY** App Gateway is rejected on the
**WAF_v2** SKU — `ApplicationGatewayFeatureCannotBeEnabledForSelectedSku:
... does not support Application Gateway without Public IP for the selected SKU
tier WAF_v2`. Private-only needs the subscription feature
`Microsoft.Network/EnableApplicationGatewayNetworkIsolation` (state here:
**NotRegistered**). So we ran a **dual frontend** instead: the existing public
frontend **plus** a new private frontend `10.0.1.10` in snet-appgateway, both
listening :443 and routing to the same NVA backend.

**Resources added for the test:** NAT Gateway on snet-appgateway (deterministic
App GW egress), and an in-VNet test client (`vm-test-client`, snet-test
`10.0.6.0/24`) to exercise the private listener — the public `validate-flows.sh`
cannot reach a private frontend.

### Results

| Check | Result |
|---|---|
| Public frontend `/healthz` (from laptop) | **200 OK** — unchanged |
| Private frontend `/healthz` (from in-VNet test client) | **200 OK** |
| Private frontend `/whoami` `remote_addr` | `10.0.3.10` — NVA DMZ IP (traffic crossed the NVA + SNAT) |
| Private frontend `/whoami` `x-forwarded-for` | `10.0.6.4` — the test client's IP, preserved end-to-end |
| Backend health (NVA `10.0.2.10`) | **Healthy** |
| `nva-trace` on the NVA | `PREROUTING DNAT eth(trust) :80 → 10.0.3.100` showing **332 pkts** — App GW backend traffic **and** the 30s health probes land on the NVA and DNAT to the webserver |

**What this proves (the client's actual question):** the App Gateway backend
health probe originates from the **gateway instances** and targets the
**backend pool member** — it is **independent of which frontend (public or
private) serves clients.** In design-5 the probe always hits the firewall (NVA)
because the **backend pool is the NVA trust IP** `10.0.2.10`. Switching the
frontend to private changed nothing about probe routing, exactly as expected.

The client's "no probes in the firewall" symptom is therefore **not** a frontend
issue — it means their **backend pool points at something that bypasses the
firewall** (typically the web server's *public* IP, which Azure hairpins over
the backbone). Fix: put the firewall's private IP (or a forced route) in the
backend pool. See [`../appgw-probe-firewall-runbook.md`](../appgw-probe-firewall-runbook.md).

> **Status:** validated live 2026-06-23, then `terraform destroy`-ed (Azure
> Firewall bills ~$30/day idle). Re-`apply` to bring it back.

---

## 2026-06-22 — deployed and verified end-to-end (7/7)

design-5 was applied to Azure and `validate-flows.sh` passed every check after
two cloud-init bugs were patched (see below). The two-firewall pattern works
live: NVA inspects inbound, Azure Firewall inspects egress, both legs
symmetric.

### Deployed outputs

```
appgw_public_ip     = 20.242.195.8
nva_public_ip       = 20.55.26.168
firewall_public_ip  = 20.81.61.132
firewall_private_ip = 10.0.5.4
webserver_ip        = 10.0.3.100
```

### Results — `./validate-flows.sh proposed-working-design-5`

| Check | Result |
|---|---|
| Inbound `/healthz` via App GW | **200 OK** |
| `/whoami` `remote_addr` | `10.0.3.10` — NVA DMZ IP (proves inbound traversed the NVA + SNAT) |
| `/whoami` `x-forwarded-for` | `73.141.144.228` — real client IP preserved end-to-end |
| Webserver reachable (ProxyJump via NVA) | OK |
| Egress SNAT (`api.ipify.org`) | `20.81.61.132` == Azure Firewall public IP — **outbound traverses Azure Firewall** |
| Allow-listed FQDN (`http://azure.archive.ubuntu.com/`) | HTTP 200 — application rule permits it |
| Non-allow-listed FQDN (`https://example.com/`) | blocked (000) — FQDN allow-list enforcing |

**What this proves:** the multi-NIC NVA pattern (Patrick's 2026-06-12 review
ask) AND Azure Firewall's FQDN-aware egress live in the same architecture and
function independently. App Gateway WAF terminates TLS; NVA's `trust` NIC
receives the post-WAF backend traffic, iptables DNATs to the webserver, the
`dmz` NIC SNATs for symmetric returns; webserver-originated outbound bypasses
the NVA entirely via the DMZ UDR and hits the Azure Firewall, which enforces
the FQDN allow-list and SNATs to its public IP. Two firewall products, two
distinct enforcement layers.

## Bugs found and fixed during deploy

Both were latent bugs in the cloud-init scripts I authored — neither was an
issue with the topology or the routing.

### NVA: `iptables ! -d A ! -d B ! -d C` rejected (multiple -d flags)

The egress SNAT rule for the untrust NIC originally read:
```
iptables -t nat -A POSTROUTING -o "$UNTRUST_IF" \
  ! -d 10.0.0.0/8 ! -d 172.16.0.0/12 ! -d 192.168.0.0/16 -j MASQUERADE
```
Modern iptables (nf_tables backend on Ubuntu 24.04) rejects multiple `-d`
flags with `"multiple -d flags not allowed"`. The `nva-firewall.service` exited
with `INVALIDARGUMENT` at this line. The rules that ran BEFORE this point did
load (inbound DNAT + dmz SNAT MASQUERADE), so the inbound path the validator
tests was unaffected. **Real impact: the NVA's own outbound MASQUERADE never
installs**, so `apt-get update` on the NVA itself would fail. (Doesn't matter
for the lab's validated flows, but worth fixing.)

**Fix in `nva.yaml.tftpl`:** replaced the multi-`-d` rule with three `RETURN`
rules for the RFC1918 prefixes followed by an unconditional `MASQUERADE`.
Applied to both design-4 and design-5 cloud-inits.

### Webserver: empty `sites-enabled/` after dpkg install

cloud-init's `write_files` creates `/etc/nginx/sites-available/default` with
the `/healthz` + `/whoami` server block. When dpkg later installs
`nginx-common` and finds that file already on disk, it skips creating the
usual `sites-enabled/default` symlink. nginx then starts (`systemctl is-active
nginx` = active), config tests clean, but **the running master is bound to no
sites** — `ss -tlnp` shows no listener on `:80/:443` and curl localhost returns
`000`. App Gateway's `/healthz` probe couldn't connect → backend unhealthy →
client gets 502.

**Fix in `webserver.yaml.tftpl`:** add an explicit
```
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
```
to the runcmd right after the apt-install retry loop. Idempotent. Applied to
**all four** designs that share the hardened cloud-init pattern (design-2/3/4/5).

### Live workaround applied to the running deployment

The running boxes were patched by hand so the validator could pass without a
re-deploy:
```
# on the webserver (via ssh -J through the NVA):
sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo systemctl reload nginx
```
The NVA's own egress MASQUERADE was NOT patched live (its absence doesn't
affect the validated flows). The Terraform fix means a future
`terraform apply` will rebuild both VMs cleanly without manual intervention.

### Drift note

The Terraform cloud-init changed for both the NVA and the webserver, so
`terraform plan` will show both VMs wanting replacement. That's expected — a
future `apply` rebuilds them and the hardened cloud-init brings everything up
clean.

## Still to verify (optional)

- A `terraform destroy && terraform apply` from scratch to prove the
  hardened cloud-init brings the lab up unattended (the fix has not yet been
  exercised on a cold deploy).
- Azure Firewall diagnostic logs — wire Log Analytics workspace + diagnostic
  settings to see the denied `example.com` flow in the Application-rule log.
- A pull on the NVA after re-deploy to confirm the new `RETURN`/`MASQUERADE`
  pair lets the NVA itself reach the Internet for `apt-get update`.
