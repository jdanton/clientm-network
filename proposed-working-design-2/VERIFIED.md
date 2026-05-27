# Verification Log

## 2026-05-27 — deployed and verified end-to-end (7/7)

design-2 was applied to Azure and `validate-flows.sh` passed every check.

### Deployed outputs

```
appgw_public_ip     = 172.214.122.55
firewall_public_ip  = 20.75.153.29
firewall_private_ip = 10.0.4.4
webserver_ip        = 10.0.3.100
nva1_public_ip      = 40.90.232.161
```

### Results — `./validate-flows.sh proposed-working-design-2`

| Check | Result |
|---|---|
| Inbound `/healthz` via App GW | **200 OK** |
| `/whoami` `remote_addr` | `10.0.3.20` — NVA DMZ IP (inbound traversed an NVA + SNAT) |
| `/whoami` `x-forwarded-for` | `73.141.144.228` — real client IP preserved end to end |
| Webserver reachable (ProxyJump via NVA1) | OK |
| Egress SNAT (`api.ipify.org`) | `20.75.153.29` == firewall public IP — **egress goes through Azure Firewall** |
| Allow-listed FQDN (`http://azure.archive.ubuntu.com/`) | HTTP 200 — application rule permits it |
| Non-allow-listed FQDN (`https://example.com/`) | blocked (000) — egress allow-list enforcing |

**What this proves:** the inbound path is the verified design-1 path (App GW →
Internal LB → NVA → webserver, symmetric via NVA SNAT, XFF preserved), AND the
new egress leg works as designed — the webserver's outbound traffic is forced
through Azure Firewall, SNATed to the firewall's public IP, and filtered against
the FQDN allow-list. The egress gap design-1 documented is closed.

### Notes / gotchas found during verification

- **Ubuntu archive mirrors are HTTP-only (port 80), not TLS on 443.** An
  `https://azure.archive.ubuntu.com/` probe returns 000 (the mirror doesn't
  speak TLS) even though the firewall permits it — use HTTP for that check. The
  HTTPS allow path is proven separately by `api.ipify.org`.
- `validate-flows.sh` reaches the webserver via `ProxyCommand` (not `ssh -J`)
  so the non-interactive SSH options apply to the jump hop too; `-J` blocked on
  a host-key prompt on this OpenSSH build.

## Post-verification hardening (cloud-init drift)

After design-3 hit a first-boot race (cloud-init's one-shot `apt` denied with
HTTP 470 while the Azure Firewall rules were still propagating), the same fix was
applied here proactively — design-2's webserver won that race by luck, not
design. `webserver.yaml.tftpl` now installs packages in a `runcmd` retry loop and
`webserver.tf` gained a `depends_on` (firewall rule collection + DMZ route
association). **This changes the webserver's cloud-init**, so `terraform plan`
will show the (already-verified, currently-running) webserver wants replacement.
A future `apply` rebuilds it and it self-heals; the live box is unaffected until
then.

## Still to verify (optional)

- NVA failover — drop one NVA, confirm `/healthz` stays green via the other and
  egress is unaffected (egress doesn't depend on the NVAs).
- Firewall logs — wire a Log Analytics workspace + diagnostic settings to see
  the denied `example.com` egress in the Application-rule logs.
