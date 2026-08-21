# Verification Log

## 2026-06-23 — deployed and verified live end-to-end (7/7)

design-6 was applied cold to Azure (`rg-clientm-lab-d6`, 43 resources) with the
default `appgw_private_only = false` (private front door + public fallback) and
verified end-to-end. Backend went Healthy ~8 min after apply (cold webserver
cloud-init + Azure Firewall rule propagation, as expected).

### Deployed outputs

```
appgw_private_ip      = 10.0.1.10        (PRIMARY front door)
appgw_public_ip       = 48.194.121.148   (fallback)
firewall_public_ip    = 13.92.69.220
natgw_public_ip       = 4.157.247.75
test_client_public_ip = 172.210.69.27
```

### Results

| Check | Result |
|---|---|
| **Private** front door `/healthz` (from in-VNet test client) | **200 OK** |
| Private `/whoami` `remote_addr` | `10.0.3.10` — NVA DMZ IP (traffic crossed the NVA + SNAT) |
| Private `/whoami` `x-forwarded-for` | `10.0.6.4` — test client IP preserved end-to-end |
| **Public** fallback `/healthz` | **200 OK** |
| App GW backend health (NVA `10.0.2.10`) | **Healthy** |
| Probe/backend path (`nva-trace`) | DNAT on trust NIC `:80 → 10.0.3.100`, **334 pkts** — App GW backend traffic + 30s probes land on the NVA |
| Egress SNAT source (`api.ipify.org`) | `13.92.69.220` == Azure Firewall public IP |
| Allow-listed FQDN (`azure.archive.ubuntu.com`) | HTTP 200 |
| Non-allow-listed FQDN (`example.com`) | 000 — blocked |

**What this confirms:** the private-IP front door serves clients through the full
two-firewall chain (NVA inbound DNAT/SNAT + Azure Firewall FQDN egress) exactly
as design-5 did on a public frontend — and the health probe still lands on the
NVA regardless of the private front door, as expected.

> **Not yet exercised:** `appgw_private_only = true` (true private-only, no public
> IP) — requires the `EnableApplicationGatewayNetworkIsolation` feature registered
> first. The default private-primary path above is fully verified.

---

## Background — design-5 lineage

design-6 is design-5 with the App Gateway front door moved to a private IP. The
substantive change — serving clients from the App Gateway's **private** frontend
— was **first proven on design-5** (2026-06-23), and is now confirmed on design-6
directly (above).

### What is already proven (on design-5, 2026-06-23)

| Check | Result |
|---|---|
| Private frontend `/healthz` (from in-VNet client) | **200 OK** |
| Private frontend `/whoami` `remote_addr` | `10.0.3.10` — NVA DMZ IP (traffic crossed the NVA + SNAT) |
| Private frontend `/whoami` `x-forwarded-for` | `10.0.6.4` — test client IP preserved |
| Backend health (NVA `10.0.2.10`) | **Healthy** |
| Probe path (`nva-trace`) | App GW backend traffic + 30s probes land on the NVA trust NIC (332 pkts DNAT :80) |

The full two-firewall flow (inbound via NVA, egress via Azure Firewall with FQDN
allow-list) was verified 7/7 on design-5 (2026-06-22).

### What design-6 changes and still needs a cold deploy to confirm

1. **Private frontend as the *primary* front door** (no reliance on the public
   listener). design-5 kept both; design-6's default keeps a public *fallback*
   but routes the primary rule through the private frontend.
2. **`appgw_private_only = true`** — the truly private-only path (no public IP).
   Requires `Microsoft.Network/EnableApplicationGatewayNetworkIsolation`
   registered on the subscription; otherwise Azure returns
   `ApplicationGatewayFeatureCannotBeEnabledForSelectedSku` on WAF_v2. Not yet
   exercised end-to-end.
3. **Cold boot ordering** — same NVA/firewall/webserver cloud-init as design-5
   (already hardened); a from-scratch `apply` should come up unattended.

### Config validation performed

- `terraform init` + `terraform validate` → **Success** (config valid).
- `terraform plan` for both `appgw_private_only=false` and `=true` — the
  `dynamic`/`count` toggle resolves cleanly (public IP + public frontend/listener/
  rule present at `false`, absent at `true`).
  > Note: a full live plan was interrupted by an expired Azure CLI token
  > (conditional-access re-auth); re-run `terraform plan` after `az login` to
  > confirm the resource graph against Azure.

### Verification checklist

- [x] Cold `terraform apply` (default) → private front door serves `/healthz` 200
      from the in-VNet test client. **(2026-06-23)**
- [x] `nva-trace` confirms probe/backend traffic on the NVA trust NIC (parity
      with design-5). **(334 pkts DNAT :80)**
- [x] Egress leg unchanged: `api.ipify.org` SNAT == Azure Firewall public IP;
      allow-listed FQDN 200, non-allow-listed blocked.
- [ ] `terraform apply -var 'appgw_private_only=true'` (with the feature
      registered) → gateway comes up with **no** public IP; private front door
      still serves. *(not yet exercised — needs the subscription feature)*
