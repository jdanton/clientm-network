# Verification Log

## 2026-05-13 — `/healthz` end-to-end PASSED

The full client → App Gateway → Internal LB → NVA → webserver path returned `200 OK` from the webserver's nginx `/healthz` endpoint, with the response traversing the symmetric return path described in [README.md](README.md).

### Deployed outputs

```
appgw_public_ip         = 4.156.91.67
internal_lb_frontend_ip = 10.0.2.4
nva1_public_ip          = 172.208.69.87
nva2_public_ip          = 20.119.73.205
webserver_ip            = 10.0.3.100
```

### Test command and result

```
export APPGW=4.156.91.67
curl -kv --resolve connect.clientmworkspace.com:443:$APPGW \
  https://connect.clientmworkspace.com/healthz
```

```
* Connected to connect.clientmworkspace.com (4.156.91.67) port 443
* SSL connection using TLSv1.3 / AEAD-AES256-GCM-SHA384
*  subject: O=Clientm Lab; CN=connect.clientmworkspace.com
*  issuer:  O=Clientm Lab; CN=connect.clientmworkspace.com
> GET /healthz HTTP/1.1
> Host: connect.clientmworkspace.com
< HTTP/1.1 200 OK
< Server: nginx/1.24.0 (Ubuntu)
OK
```

What this proves: App GW listener accepts the self-signed cert, request routes to the Internal LB at `10.0.2.4`, the LB picks an NVA, the NVA DNATs to the webserver, and the response makes it all the way back to curl. The whole asymmetric-routing problem from the previous "App GW behind firewalls" attempt is gone.

### Gotcha

The test snippet in `outputs.tf` uses `$APPGW`. Running `bash` opens a subshell where the variable from your parent shell isn't visible — `export APPGW=...` (or paste the literal IP) in whatever shell you actually run curl from. Original failure was `Couldn't parse CURLOPT_RESOLVE entry 'connect.clientmworkspace.com:443:'` (empty IP).

## Still to verify

- `/whoami` — the real X-Forwarded-For symmetry proof. Should show:
  - `remote_addr` = NVA DMZ IP (`10.0.3.20` or `10.0.3.21`) after SNAT
  - `x-forwarded-for` = the caller's public IP, preserved by App GW
- NVA failover — kill one NVA, confirm `/healthz` stays green via the other.
