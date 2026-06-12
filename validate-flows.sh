#!/usr/bin/env bash
# =============================================================================
# validate-flows.sh — verify the traffic flows for design-2 / design-3 / design-4.
#
# Read-only: it only sends curl/ssh probes, it changes nothing. Auto-detects
# which design it is pointed at from the Terraform outputs:
#
#   design-2  (firewall_public_ip + nva1_public_ip present):
#       inbound  : client → App GW → Internal LB → NVA → webserver
#       egress   : webserver → Azure Firewall → Internet
#       webserver reached for egress checks via ProxyJump through an NVA.
#
#   design-3  (firewall_public_ip, no NVAs):
#       inbound  : client → App GW → Azure Firewall → webserver
#       egress   : webserver → Azure Firewall → Internet
#       webserver reached via the firewall DNAT (ssh to the firewall public IP).
#
#   design-4  (nva_public_ip, no firewall):
#       inbound  : client → App GW → NVA trust → DNAT → NVA dmz → webserver
#       egress   : webserver → snet-dmz UDR → NVA → Internet (SNAT to NVA PIP)
#       webserver reached via ProxyJump through the NVA. L4 egress allow-list
#       (the "deny" probe targets a non-allow-listed port, not an FQDN).
#
# Usage:
#   ./validate-flows.sh                         # use Terraform state in $PWD
#   ./validate-flows.sh proposed-working-design-2
#   ./validate-flows.sh proposed-working-design-3
#   ./validate-flows.sh proposed-working-design-4
#
# Requirements: terraform, curl, ssh. Uses ~/.ssh/clientm-lab if present.
# Exit code is non-zero if any check fails.
# =============================================================================
set -uo pipefail

DIR="${1:-.}"
HOST_FQDN="connect.clientmworkspace.com"
ADMIN_USER="azureuser"

# ── colors / helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS_N=0; FAIL_N=0
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS_N=$((PASS_N+1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL_N=$((FAIL_N+1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "       $*"; }
section() {
  echo ""; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
}

tf() { terraform -chdir="$DIR" output -raw "$1" 2>/dev/null; }

# ── read outputs + detect design ───────────────────────────────────────────────
section "Reading Terraform outputs from: $DIR"
APPGW_IP=$(tf appgw_public_ip)        || true
FW_PUBLIC=$(tf firewall_public_ip)    || true
FW_PRIVATE=$(tf firewall_private_ip)  || true
WEBSERVER_IP=$(tf webserver_ip)       || true
NVA1_IP=$(tf nva1_public_ip)          || true   # design-2 (active/active pair)
NVA_IP=$(tf nva_public_ip)            || true   # design-4 (single NVA)

if [[ -z "${APPGW_IP:-}" || -z "${WEBSERVER_IP:-}" ]]; then
  fail "Could not read required outputs from '$DIR'. Run from a deployed design dir,"
  info "or pass the dir:  ./validate-flows.sh proposed-working-design-{2,3,4}"
  exit 1
fi

# Mode detection + per-mode "egress public IP" and "jump host" assignments.
# EGRESS_PIP = the IP we expect outbound SNAT to land on
# JUMP_IP    = the public IP we ssh -J through to reach the webserver (empty
#              for design-3, which uses firewall DNAT instead of a jump host)
if [[ -n "${FW_PUBLIC:-}" && -n "${NVA1_IP:-}" ]]; then
  MODE=2; EXPECT_REMOTE_PREFIX="10.0.3."   # NVA DMZ IP after SNAT (.20/.21)
  EGRESS_PIP="$FW_PUBLIC"; EGRESS_LABEL="Azure Firewall public IP"
  JUMP_IP="$NVA1_IP"; JUMP_LABEL="ProxyJump via NVA1"
  log "Detected: design-2 (NVA pair inbound, Azure Firewall egress)"
elif [[ -n "${FW_PUBLIC:-}" ]]; then
  MODE=3; EXPECT_REMOTE_PREFIX="10.0.1."   # App GW subnet IP (firewall doesn't SNAT private)
  EGRESS_PIP="$FW_PUBLIC"; EGRESS_LABEL="Azure Firewall public IP"
  JUMP_IP=""; JUMP_LABEL="firewall DNAT ssh"
  log "Detected: design-3 (Azure Firewall both directions)"
elif [[ -n "${NVA_IP:-}" ]]; then
  MODE=4; EXPECT_REMOTE_PREFIX="10.0.3."   # NVA DMZ IP after SNAT (.10)
  EGRESS_PIP="$NVA_IP"; EGRESS_LABEL="NVA public IP"
  JUMP_IP="$NVA_IP"; JUMP_LABEL="ProxyJump via NVA"
  log "Detected: design-4 (single multi-NIC NVA, both directions)"
else
  fail "Could not identify the design — neither firewall_public_ip nor nva_public_ip is set."
  exit 1
fi

log "App Gateway public IP : ${APPGW_IP}"
if [[ $MODE == 4 ]]; then
  log "NVA public IP         : ${NVA_IP}"
else
  log "Firewall public IP    : ${FW_PUBLIC}"
  log "Firewall private IP   : ${FW_PRIVATE:-<n/a>}"
fi
log "Webserver private IP  : ${WEBSERVER_IP}"
[[ $MODE == 2 ]] && log "NVA1 public IP        : ${NVA1_IP}"

# ── ssh plumbing ────────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
LAB_KEY="${HOME}/.ssh/clientm-lab"
[[ -f "$LAB_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $LAB_KEY -o IdentitiesOnly=yes"

# web_ssh <remote command> — run a command ON THE WEBSERVER, however we reach it.
# stdin is closed (</dev/null) so SSH can never block on an interactive prompt.
# When jumping (design-2 / design-4) we use an explicit ProxyCommand rather than
# -J so the no-prompt SSH options apply to BOTH hops — some OpenSSH builds do
# not propagate command-line -o options to a -J jump host.
web_ssh() {
  if [[ -n "$JUMP_IP" ]]; then
    ssh $SSH_OPTS \
      -o ProxyCommand="ssh $SSH_OPTS -W %h:%p ${ADMIN_USER}@${JUMP_IP}" \
      "${ADMIN_USER}@${WEBSERVER_IP}" "$@" </dev/null
  else
    ssh $SSH_OPTS "${ADMIN_USER}@${FW_PUBLIC}" "$@" </dev/null   # design-3: firewall DNAT → webserver:22
  fi
}

# ── phase 1: inbound flow (client → … → webserver) ──────────────────────────────
section "Phase 1 — Inbound flow via App Gateway"

log "Polling https://${HOST_FQDN}/healthz (resolve → ${APPGW_IP}) until 200 (cold App GW/firewall can take ~10 min)..."
code=000; for i in $(seq 1 40); do
  code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' \
    --resolve "${HOST_FQDN}:443:${APPGW_IP}" "https://${HOST_FQDN}/healthz" || echo 000)
  [[ $code == 200 ]] && break
  echo -ne "\r  attempt $i — last HTTP $code   "; sleep 15
done; echo ""
if [[ $code == 200 ]]; then
  pass "/healthz returned 200 — full inbound path is up"
else
  fail "/healthz never returned 200 (last: $code)"
  case $MODE in
    2) info "design-2: check Internal LB backend health + NVA firewall service" ;;
    3) info "design-3: check App GW backend health + the inbound-web firewall rule / App GW UDR" ;;
    4) info "design-4: check App GW backend health + NVA firewall service ('ssh azureuser@$NVA_IP sudo nva-trace')" ;;
  esac
fi

log "Checking X-Forwarded-For preservation + inbound source IP via /whoami..."
WHOAMI=$(curl -sk --max-time 10 --resolve "${HOST_FQDN}:443:${APPGW_IP}" "https://${HOST_FQDN}/whoami" || true)
REMOTE_ADDR=$(echo "$WHOAMI" | awk -F': ' '/^remote_addr:/{print $2}' | tr -d '\r ')
XFF=$(echo "$WHOAMI"        | awk -F': ' '/^x-forwarded-for:/{print $2}' | tr -d '\r ')

if [[ "$REMOTE_ADDR" == ${EXPECT_REMOTE_PREFIX}* ]]; then
  if [[ $MODE == 2 ]]; then
    pass "remote_addr=${REMOTE_ADDR} — webserver sees the NVA DMZ IP (proves inbound traversed an NVA + SNAT)"
  else
    pass "remote_addr=${REMOTE_ADDR} — webserver sees the App GW subnet IP (firewall did not SNAT the inbound leg, as designed)"
  fi
else
  fail "remote_addr=${REMOTE_ADDR:-<empty>} — expected to start with ${EXPECT_REMOTE_PREFIX}"
fi

if [[ -n "$XFF" ]]; then
  pass "x-forwarded-for=${XFF} — original client IP preserved through the chain"
  MY_IP=$(curl -s --max-time 5 https://api.ipify.org || true)
  [[ -n "$MY_IP" && "$XFF" == *"$MY_IP"* ]] && info "matches this host's public IP (${MY_IP})"
else
  fail "x-forwarded-for empty — App GW should have injected it"
fi

# ── phase 2: webserver reachability for egress checks ───────────────────────────
section "Phase 2 — Reaching the webserver (${JUMP_LABEL})"

up=false; for i in $(seq 1 24); do
  if web_ssh true 2>/dev/null; then up=true; break; fi
  echo -ne "\r  waiting for webserver SSH... attempt $i/24   "; sleep 5
done; echo ""
if $up; then
  pass "webserver reachable over SSH"
else
  fail "cannot SSH to the webserver — skipping egress checks"
  warn "last attempt, with errors shown:"
  web_ssh true || true
  case $MODE in
    2) info "design-2: confirm NVA1 ($NVA1_IP) is reachable and allowed_ssh_cidr matches your IP" ;;
    3) info "design-3: confirm the mgmt-dnat rule + that allowed_ssh_cidr matches your current IP ($(curl -s https://api.ipify.org || echo '?'))" ;;
    4) info "design-4: confirm the NVA ($NVA_IP) is reachable and allowed_ssh_cidr matches your IP" ;;
  esac
  section "Result"; echo "PASS: $PASS_N   FAIL: $FAIL_N"; exit $(( FAIL_N > 0 ? 1 : 0 ))
fi

# ── phase 3: egress flow (webserver → firewall → Internet) ─────────────────────
section "Phase 3 — Egress flow"

log "[SNAT] webserver → https://api.ipify.org — source IP should be the ${EGRESS_LABEL}..."
SEEN_IP=$(web_ssh "curl -s --max-time 15 https://api.ipify.org || true"); SEEN_IP=$(echo "$SEEN_IP" | tr -d '\r ')
if [[ "$SEEN_IP" == "$EGRESS_PIP" ]]; then
  pass "egress SNATed to ${SEEN_IP} == ${EGRESS_LABEL} — outbound is going through the firewall"
elif [[ -z "$SEEN_IP" ]]; then
  fail "no response from api.ipify.org — is it allow-listed? is the egress UDR / firewall service up?"
else
  fail "egress source IP ${SEEN_IP} != ${EGRESS_LABEL} ${EGRESS_PIP} — traffic is NOT going through the firewall"
fi

# NB: Ubuntu archive mirrors serve HTTP (port 80), not TLS on 443 — apt uses
# HTTP here. design-2/3 allow both 80/443 to the ubuntu FQDNs; design-4's L4
# allow-list permits any TCP/80 outbound. We probe 80.
log "[ALLOW] webserver → http://azure.archive.ubuntu.com/ should succeed..."
A_CODE=$(web_ssh "curl -s --max-time 15 -o /dev/null -w '%{http_code}' http://azure.archive.ubuntu.com/ || true"); A_CODE=$(echo "$A_CODE" | tr -d '\r ')
if [[ "$A_CODE" =~ ^(200|30.|40.)$ ]]; then
  pass "reached the allow-listed target (HTTP $A_CODE) — egress rule permits it"
else
  fail "allow-listed target returned '$A_CODE' — expected a real HTTP response"
fi

# design-2/3 deny by FQDN (example.com not allow-listed); design-4 denies by
# PORT (L4-only allow-list — port 25 is not in {53,80,123,443}, should drop).
if [[ $MODE == 4 ]]; then
  log "[DENY] webserver → tcp/25 (port NOT in the L4 allow-list) should be blocked..."
  D_CODE=$(web_ssh "curl --connect-timeout 8 -s -o /dev/null -w '%{http_code}' http://example.com:25/ || true"); D_CODE=$(echo "$D_CODE" | tr -d '\r ')
  if [[ "$D_CODE" == "000" || -z "$D_CODE" ]]; then
    pass "tcp/25 blocked (HTTP '${D_CODE:-000}') — L4 egress allow-list is enforcing"
  else
    fail "tcp/25 returned '$D_CODE' — port allow-list is NOT enforcing (check iptables FORWARD)"
  fi
else
  log "[DENY] webserver → https://example.com/ (NOT allow-listed FQDN) should be blocked..."
  D_CODE=$(web_ssh "curl -s --max-time 12 -o /dev/null -w '%{http_code}' https://example.com/ || true"); D_CODE=$(echo "$D_CODE" | tr -d '\r ')
  if [[ "$D_CODE" == "200" ]]; then
    fail "example.com returned 200 — FQDN allow-list is NOT enforcing (check the application rule)"
  else
    pass "example.com blocked (HTTP '${D_CODE:-000}') — FQDN allow-list is enforcing"
  fi
fi

# ── summary ─────────────────────────────────────────────────────────────────────
section "Result — design-$MODE"
echo -e "  ${GREEN}PASS: $PASS_N${NC}    ${RED}FAIL: $FAIL_N${NC}"
echo ""
case $MODE in
  2) echo "  Inbound : client → App GW WAF → Internal LB → NVA → webserver"
     echo "  Egress  : webserver → Azure Firewall (SNAT ${EGRESS_PIP}) → Internet, FQDN allow-listed" ;;
  3) echo "  Inbound : client → App GW WAF → Azure Firewall → webserver"
     echo "  Egress  : webserver → Azure Firewall (SNAT ${EGRESS_PIP}) → Internet, FQDN allow-listed" ;;
  4) echo "  Inbound : client → App GW WAF → NVA trust → DNAT → webserver"
     echo "  Egress  : webserver → NVA dmz → MASQUERADE (SNAT ${EGRESS_PIP}) → Internet, L4 port allow-listed" ;;
esac
echo ""
exit $(( FAIL_N > 0 ? 1 : 0 ))
