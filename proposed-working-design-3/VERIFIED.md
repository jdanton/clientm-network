# Verification Log

## 2026-05-27 — deployed and verified end-to-end (7/7)

design-3 was applied to Azure and `validate-flows.sh` passed every check —
including the part with no design-1 precedent: **inbound traffic routed through
Azure Firewall (App GW → firewall → webserver) is symmetric and works.**

### Deployed outputs

```
appgw_public_ip     = 4.156.207.172
firewall_public_ip  = 134.33.234.114
firewall_private_ip = 10.0.4.4
webserver_ip        = 10.0.3.100
```

### Results — `./validate-flows.sh proposed-working-design-3`

| Check | Result |
|---|---|
| Inbound `/healthz` via App GW | **200 OK** |
| `/whoami` `remote_addr` | `10.0.1.4` — App GW subnet IP; **firewall did not SNAT the inbound leg** (return follows the web-subnet UDR back through the firewall → symmetric) |
| `/whoami` `x-forwarded-for` | `73.141.144.228` — real client IP preserved end to end |
| Webserver reachable (firewall DNAT ssh) | OK — `ssh azureuser@134.33.234.114` lands on the webserver |
| Egress SNAT (`api.ipify.org`) | `134.33.234.114` == firewall public IP — egress goes through Azure Firewall |
| Allow-listed FQDN (`http://azure.archive.ubuntu.com/`) | HTTP 200 |
| Non-allow-listed FQDN (`https://example.com/`) | blocked (000) |

**What this proves:** one Azure Firewall inspects BOTH directions and stays
symmetric — the inbound leg (App GW ⇆ webserver, no SNAT, return via UDR) and
the egress leg (SNAT to the firewall public IP, FQDN allow-listed). The NVA pair
+ Internal LB are genuinely not needed for this to work.

## First-boot race found and fixed

On the initial `apply`, the App Gateway returned **502** because the webserver's
nginx never installed: cloud-init's one-shot `apt` ran while the firewall's data
path + egress UDR were already live but its **application-rule collection had not
finished propagating**, so the `apt` egress to `azure.archive.ubuntu.com` was
denied with **HTTP 470** (Azure Firewall's deny response) and cloud-init aborted.
(design-2's webserver happened to win the same race.)

Confirmed it was timing, not config: once the firewall settled, egress from the
webserver worked (`api.ipify.org` → firewall IP, ubuntu mirror → 200, example.com
→ blocked).

Fixes applied:
- **cloud-init** (`webserver.yaml.tftpl`): packages now install in a `runcmd`
  **retry loop** (up to ~10 min) instead of the one-shot `packages:` directive,
  so a transient egress-not-ready denial self-heals.
- **`webserver.tf`**: added `depends_on` so the VM boots only after the firewall
  rule collection group and the web subnet route association exist, shrinking the
  window the retry loop has to cover.

### Drift note

The **running** webserver was hand-fixed (nginx installed manually) to get to a
green state. The Terraform cloud-init has since changed, so `terraform plan` will
show the webserver wants replacement. That is expected — a future `apply`
rebuilds it and the hardened cloud-init brings it up clean with no manual step.

## Still to verify (optional)

- A clean `terraform destroy && terraform apply` to confirm the retry loop +
  `depends_on` make first boot succeed unattended (the fix has not yet been
  exercised from scratch — the live box was hand-patched).
- Firewall logs — wire Log Analytics + diagnostic settings to see the denied
  `example.com` egress and the inbound-web allows.
