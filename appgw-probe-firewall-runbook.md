# App Gateway Health Probe → Firewall: Diagnostic Runbook

**Symptom:** App Gateway backend shows *Unhealthy*, and the health probes never
appear in the firewall logs.

**Root cause, 95% of the time:** the firewall is not actually on the path the
App Gateway takes to the backend. A probe that never reaches the firewall cannot
be logged or dropped by it — the absence in the logs *is* the diagnosis. Work the
steps in order; each one ends in a **→ verdict** that tells you where to go next.

> Fill these in once and reuse them:
> ```powershell
> $RG     = "<resource-group>"
> $AppGw  = "<appgw-name>"
> $Vnet   = "<vnet-name>"
> $Subnet = "<appgw-subnet-name>"     # the App GW's OWN subnet
> $FwIp   = "<firewall-private-ip>"   # e.g. 10.0.5.4 / NVA trust NIC
> $gw     = Get-AzApplicationGateway -Name $AppGw -ResourceGroupName $RG
> ```

---

## Step 1 — What is actually in the backend pool?

```powershell
$gw.BackendAddressPools | Select-Object Name -ExpandProperty BackendAddresses
```

| You see | Meaning | → verdict |
|---|---|---|
| A **public IP** (e.g. `20.x` / `4.x`) | Azure hairpins the probe over the backbone straight to the VM's private NIC. It **never leaves toward the firewall.** | **STOP. This is the bug.** Go to **Fix A**. |
| The **web server's private IP** | Probe goes App GW → VM directly, intra-VNet. Firewall only sees it if a UDR forces it. | Go to **Step 2**. |
| The **firewall's private IP** (`$FwIp`) | Firewall *is* the destination — probe must arrive. If it doesn't, the firewall config or logging is the problem. | Go to **Step 3**. |

---

## Step 2 — Backend = web server private IP. Is a UDR forcing it through the firewall?

```powershell
$rtId = (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork (Get-AzVirtualNetwork -Name $Vnet -ResourceGroupName $RG) -Name $Subnet).RouteTable.Id
if (-not $rtId) { "NO route table on the App GW subnet" }
else { (Get-AzRouteTable -ResourceGroupName $RG -Name ($rtId -split '/')[-1]).Routes |
        Select-Object Name, AddressPrefix, NextHopType, NextHopIpAddress }
```

| You see | → verdict |
|---|---|
| No route table, **or** no route covering the web server IP | Firewall is not in the path. **This is the bug.** Go to **Fix A** (preferred) or **Fix B**. |
| A **specific** route (e.g. `10.0.3.100/32`) → `VirtualAppliance` @ `$FwIp` | Routing is correct — go to **Step 3** to check the firewall side. |
| A **`0.0.0.0/0`** route → `VirtualAppliance` | **Invalid for App GW v2** — this breaks the gateway. Remove it; use Fix A or a specific route. |

> **App GW v2 rule:** its own subnet may **not** carry a `0.0.0.0/0` UDR to a
> virtual appliance/firewall. Only **specific** prefixes are allowed. This is why
> "firewall as the backend" (Fix A) is the more robust pattern.

---

## Step 3 — Probe should be reaching the firewall. Why isn't it logged?

**3a. Backend health detail** (the error string names the failure mode):

```powershell
Get-AzApplicationGatewayBackendHealth -Name $AppGw -ResourceGroupName $RG |
  Select-Object -Expand BackendAddressPools |
  Select-Object -Expand BackendHttpSettingsCollection |
  Select-Object -Expand Servers | Format-List Address, Health, HealthProbeLog
```

**3b. Is there a DNAT/NAT rule on the firewall** translating `$FwIp:80` → web server?
(Azure Firewall: NAT rule collection. NVA: `iptables -t nat -L PREROUTING`.)

```powershell
# Azure Firewall example:
(Get-AzFirewall -ResourceGroupName $RG).NatRuleCollections |
  Select-Object -Expand Rules | Format-List Name, SourceAddresses, DestinationAddresses, DestinationPorts, TranslatedAddress, TranslatedPort
```

**3c. NSG on the backend / firewall subnet** — is App GW's subnet allowed inbound on :80?

```powershell
(Get-AzNetworkSecurityGroup -ResourceGroupName $RG).SecurityRules |
  Where-Object Direction -eq 'Inbound' |
  Select-Object Name, Priority, Access, SourceAddressPrefix, DestinationPortRange
```

| Finding | → verdict |
|---|---|
| No DNAT/NAT rule, or wrong port | Probe arrives but the firewall has nothing to forward it to → add/fix the DNAT rule (see Fix A). |
| NSG denies App GW subnet → backend on :80 | Add an allow rule; the probe is being dropped at the NSG, before the firewall rule logs. |
| Rules look right but logs empty | You're reading the **wrong log category** — DNAT hits log under **NAT rules**, not Network/Application rules. See **Step 4**. |

---

## Step 4 — Confirm you're looking at the right firewall logs

DNAT traffic is logged under the **NAT rule** category, *not* Network or
Application rules. In Log Analytics:

```kusto
AZFWNatRule
| where TimeGenerated > ago(30m)
| where DestinationPort == 80
| project TimeGenerated, SourceIp, DestinationIp, DestinationPort, TranslatedIp, Action
```

No rows here **and** routing verified in Steps 1–2 ⇒ the probe genuinely isn't
arriving — re-check the backend pool (Step 1). Rows present ⇒ the probe *is*
flowing; the health failure is now an app-layer issue (Host header / `/healthz`
returning non-2xx) — see **Fix A**, the probe Host-header note.

---

## Fix A — Firewall as the backend (recommended)

Put the **firewall's private IP** in the backend pool and let it DNAT to the web
server. The firewall is then literally the destination, so probes cannot bypass
it. No UDR on the App GW subnet required.

```powershell
$gw = Get-AzApplicationGateway -Name $AppGw -ResourceGroupName $RG

# 1. Backend pool -> firewall private IP
Set-AzApplicationGatewayBackendAddressPool -ApplicationGateway $gw `
  -Name "bepool-fw" -BackendIPAddresses $FwIp

# 2. Probe with an EXPLICIT Host header (so the web server's vhost answers 200)
Set-AzApplicationGatewayProbeConfig -ApplicationGateway $gw `
  -Name "probe-healthz" -Protocol Http -HostName "connect.clientmworkspace.com" `
  -Path "/healthz" -Interval 30 -Timeout 30 -UnhealthyThreshold 3 `
  -Match (New-AzApplicationGatewayProbeHealthResponseMatch -StatusCode @("200-299"))
$probe = Get-AzApplicationGatewayProbeConfig -Name "probe-healthz" -ApplicationGateway $gw

# 3. HTTP settings -> same Host header, bound to the probe
Set-AzApplicationGatewayBackendHttpSetting -ApplicationGateway $gw `
  -Name "settings-fw" -Port 80 -Protocol Http -CookieBasedAffinity Disabled `
  -RequestTimeout 20 -HostName "connect.clientmworkspace.com" -Probe $probe

Set-AzApplicationGateway -ApplicationGateway $gw
```

Then on the firewall add the DNAT rule: **inbound to `$FwIp:80` → web server `:80`**
(Azure Firewall NAT rule collection, or NVA `iptables -t nat -A PREROUTING`).

**Host-header note:** the probe and HTTP settings both set `-HostName` explicitly
(PickHostName toggles stay off). Without it, nginx's vhost won't match and
`/healthz` returns 404/444 → Unhealthy even though traffic is flowing.

## Fix B — Web server as backend + specific UDR (only if you can't DNAT)

Backend pool = web server private IP, **plus** a route table on the App GW subnet
with a **specific** route (`<webserver-ip>/32` → `VirtualAppliance` @ `$FwIp`).
Never `0.0.0.0/0`. More fragile than Fix A — avoid unless DNAT isn't an option.

---

## One-line decision tree

```
No probe in firewall logs
  └─ Step 1: backend pool =
       ├─ public IP ............... hairpin bypass → Fix A
       ├─ web server private IP ... Step 2: UDR forcing it to the firewall?
       │     ├─ no/0.0.0.0/0 UDR .. firewall not in path → Fix A (or specific-route Fix B)
       │     └─ specific UDR ...... Step 3
       └─ firewall private IP ..... Step 3: DNAT rule? NSG? right log category?
             ├─ no DNAT/wrong port ... add DNAT (Fix A)
             ├─ NSG deny ............. allow App GW subnet :80
             └─ rules OK ............. Step 4: read AZFWNatRule category, then check Host header
```
