#!/usr/bin/env bash
# =============================================================================
# test-lab.sh — Clientm asymmetric routing lab end-to-end test runner
#
# Usage:
#   ./test-lab.sh            # run all phases
#   ./test-lab.sh --phase 2  # jump to a specific phase (1-5)
#   ./test-lab.sh --wait     # poll until VMs are reachable, then exit
#
# Requirements: terraform, curl, ssh (key loaded in ssh-agent or at ~/.ssh/id_rsa)
# =============================================================================
set -euo pipefail

# ── colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
pass()    { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
info()    { echo -e "       $*"; }
section() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
}
pause()   { echo -e "\n${YELLOW}Press Enter to continue...${NC}"; read -r; }

# ── parse args ────────────────────────────────────────────────────────────────
START_PHASE=1
WAIT_ONLY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --phase) START_PHASE=$2; shift 2 ;;
    --wait)  WAIT_ONLY=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── terraform outputs ─────────────────────────────────────────────────────────
section "Reading Terraform outputs"
NVA1_IP=$(terraform output -raw nva1_public_ip)
NVA2_IP=$(terraform output -raw nva2_public_ip)
ELB_IP=$(terraform output -raw external_lb_public_ip)
APPGW_IP=$(terraform output -raw appgw_public_ip)
APPGW_PRIVATE_IP=$(terraform output -raw appgw_private_ip)
WEBSERVER_IP=$(terraform output -raw webserver_ip)
ADMIN_USER="azureuser"

log "NVA1 public IP       : $NVA1_IP"
log "NVA2 public IP       : $NVA2_IP"
log "External LB public IP: $ELB_IP"
log "App Gateway public IP: $APPGW_IP"
log "App Gateway private  : $APPGW_PRIVATE_IP   (NVAs DNAT 443 here)"
log "Webserver private IP : $WEBSERVER_IP   (App GW backend, reached via VNet peering)"

# UserKnownHostsFile=/dev/null skips the known_hosts check entirely. NVA public
# IPs get reused across destroy/apply cycles but the host keys regenerate,
# which makes StrictHostKeyChecking=no insufficient (it auto-accepts new keys
# but blocks on changed ones).
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
# Auto-include the lab key if it exists and isn't already loaded in the agent.
# Without this the script hangs on Phase 0 in shells that don't have the agent.
LAB_KEY="${HOME}/.ssh/milbank_lab"
if [[ -f "$LAB_KEY" ]]; then
  SSH_OPTS="$SSH_OPTS -i $LAB_KEY -o IdentitiesOnly=yes"
fi
SSH1="ssh $SSH_OPTS ${ADMIN_USER}@${NVA1_IP}"
SSH2="ssh $SSH_OPTS ${ADMIN_USER}@${NVA2_IP}"

nva_ssh() {
  # nva_ssh <1|2> <command>
  local nva=$1; shift
  if [[ $nva == "1" ]]; then
    $SSH1 "$@"
  else
    $SSH2 "$@"
  fi
}

# ── phase 0: wait for VMs ─────────────────────────────────────────────────────
section "Phase 0 — Waiting for VMs to accept SSH"

wait_ssh() {
  local host=$1 label=$2
  local attempts=0
  while ! ssh $SSH_OPTS ${ADMIN_USER}@${host} true 2>/dev/null; do
    attempts=$((attempts+1))
    if [[ $attempts -ge 60 ]]; then
      fail "$label ($host) unreachable after 5 minutes"; exit 1
    fi
    echo -ne "\r  Waiting for $label ($host)... attempt $attempts"
    sleep 5
  done
  echo ""
  pass "$label ($host) is reachable"
}

wait_ssh "$NVA1_IP" "NVA1"
wait_ssh "$NVA2_IP" "NVA2"

$WAIT_ONLY && { log "VMs are up. Exiting (--wait mode)."; exit 0; }

# ── phase 1: verify components ────────────────────────────────────────────────
[[ $START_PHASE -le 1 ]] || { log "Skipping phase 1"; }

if [[ $START_PHASE -le 1 ]]; then
  section "Phase 1 — Component health checks"

  # 1a. NVA1 firewall service
  log "Checking NVA1 firewall service..."
  if $SSH1 "systemctl is-active --quiet nva-firewall.service"; then
    pass "NVA1 nva-firewall.service is active"
  else
    fail "NVA1 nva-firewall.service is NOT active"
    $SSH1 "sudo journalctl -u nva-firewall.service --no-pager -n 30" || true
  fi

  # 1b. NVA2 firewall service
  log "Checking NVA2 firewall service..."
  if $SSH2 "systemctl is-active --quiet nva-firewall.service"; then
    pass "NVA2 nva-firewall.service is active"
  else
    fail "NVA2 nva-firewall.service is NOT active"
    $SSH2 "sudo journalctl -u nva-firewall.service --no-pager -n 30" || true
  fi

  # 1c. IP forwarding on both NVAs
  log "Checking IP forwarding..."
  for nva in 1 2; do
    val=$(nva_ssh $nva "sysctl -n net.ipv4.ip_forward")
    if [[ $val == "1" ]]; then
      pass "NVA${nva} ip_forward=1"
    else
      fail "NVA${nva} ip_forward=$val (should be 1)"
    fi
  done

  # 1d. conntrack loose=0 (required to reproduce the bug)
  log "Checking conntrack tcp_loose..."
  for nva in 1 2; do
    val=$(nva_ssh $nva "sysctl -n net.netfilter.nf_conntrack_tcp_loose 2>/dev/null || echo missing")
    if [[ $val == "0" ]]; then
      pass "NVA${nva} nf_conntrack_tcp_loose=0 (strict mode — bug will reproduce)"
    elif [[ $val == "1" ]]; then
      warn "NVA${nva} nf_conntrack_tcp_loose=1 (loose mode — bug will NOT reproduce as dramatically)"
    else
      warn "NVA${nva} nf_conntrack_tcp_loose=$val"
    fi
  done

  # 1e. Webserver reachable from NVA1 (direct via eth2 in DMZ subnet — bypasses LBs)
  log "Checking webserver reachability from NVA1 (direct via eth2)..."
  if $SSH1 "curl -sk --max-time 5 https://${WEBSERVER_IP}/healthz -o /dev/null -w '%{http_code}'" | grep -q "200"; then
    pass "Webserver responds 200 on /healthz (NVA1 direct via eth2)"
  else
    fail "Webserver not responding from NVA1 — check nginx on the webserver VM"
    info "Try: ssh $ADMIN_USER@$NVA1_IP 'curl -vk https://${WEBSERVER_IP}/healthz'"
  fi

  # 1f. App GW listener reachable from NVA1 (validates DNAT target + peering route)
  log "Checking App GW private listener reachability from NVA1..."
  if $SSH1 "curl -sk --max-time 5 --resolve connect.clientmworkspace.com:443:${APPGW_PRIVATE_IP} https://connect.clientmworkspace.com/healthz -o /dev/null -w '%{http_code}'" | grep -q "2[05]2\|200"; then
    pass "App GW listener responding from NVA1 (via eth1 + VNet peering)"
  else
    warn "App GW listener not returning 2xx — likely the bug: backend (webserver) marked unhealthy"
    info "App GW returns 502 when its backend probe fails — that IS the production failure mode"
  fi

  # 1f. External LB responds
  log "Checking external LB..."
  HTTP_CODE=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
    --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
    "https://connect.clientmworkspace.com/healthz" || echo "000")
  if [[ $HTTP_CODE == "200" ]]; then
    pass "External LB → NVA → webserver /healthz returned 200"
  else
    warn "External LB returned HTTP $HTTP_CODE (may be normal if the bug is actively dropping packets)"
    info "This is expected during bug reproduction — continue to Phase 2"
  fi
fi

# ── phase 2: reproduce the bug ────────────────────────────────────────────────
if [[ $START_PHASE -le 2 ]]; then
  section "Phase 2 — Reproduce the asymmetric routing bug"

  echo ""
  echo "Topology: App Gateway is NATed behind the firewalls."
  echo "  Client → Front LB → NVA eth0 (DNAT :443 → ${APPGW_PRIVATE_IP})"
  echo "                    → NVA eth1 (SNAT) → App Gateway listener"
  echo "  App GW backend = webserver (${WEBSERVER_IP}), reached DIRECTLY via VNet peering."
  echo ""
  echo "The bug: App-GW → webserver bypasses NVAs (peering direct). Webserver replies"
  echo "to App GW go via DMZ default route → DMZ LB → NVA eth2. That NVA has no"
  echo "conntrack entry for the App-GW→webserver flow → nf_conntrack_tcp_loose=0 marks"
  echo "the SYN-ACK INVALID → DROP. App GW backend probe fails, then front LB probe"
  echo "(which DNATs through to App GW) fails → backend unhealthy → 502/timeout to client."
  echo ""

  log "Clearing conntrack tables on both NVAs..."
  $SSH1 "sudo conntrack -F 2>/dev/null || true"
  $SSH2 "sudo conntrack -F 2>/dev/null || true"
  pass "Conntrack flushed"

  log "Sending 20 HTTPS requests through the external LB (expect intermittent failures)..."
  PASS_COUNT=0; FAIL_COUNT=0
  for i in $(seq 1 20); do
    CODE=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
      --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
      "https://connect.clientmworkspace.com/healthz" || echo "000")
    if [[ $CODE == "200" ]]; then
      PASS_COUNT=$((PASS_COUNT+1))
      echo -n "."
    else
      FAIL_COUNT=$((FAIL_COUNT+1))
      echo -n "X"
    fi
  done
  echo ""

  if [[ $FAIL_COUNT -gt 0 ]]; then
    pass "Bug reproduced: $FAIL_COUNT/20 requests failed (asymmetric routing drops)"
  else
    warn "All 20 requests succeeded — the LB may have consistently hashed to one NVA."
    warn "Try running the loop below for a longer period to catch the asymmetry."
    info "for i in \$(seq 1 100); do curl -sk --max-time 3 -o /dev/null -w '%{http_code}\\n' --resolve connect.clientmworkspace.com:443:${ELB_IP} https://connect.clientmworkspace.com/healthz; done | sort | uniq -c"
  fi
fi

# ── phase 3: observe the bug ──────────────────────────────────────────────────
if [[ $START_PHASE -le 3 ]]; then
  section "Phase 3 — Observe asymmetric routing on the NVAs"

  echo ""
  echo "We will:"
  echo "  1. Watch conntrack state on NVA1 and NVA2"
  echo "  2. Send a burst of traffic"
  echo "  3. Check for INVALID drops in the iptables FORWARD chain"
  echo ""

  log "Snapshot NVA1 FORWARD chain drop counter (before traffic)..."
  NVA1_DROP_BEFORE=$($SSH1 "sudo iptables -L FORWARD -v -n | awk '/DROP/{print \$1}' | head -1")
  log "Snapshot NVA2 FORWARD chain drop counter (before traffic)..."
  NVA2_DROP_BEFORE=$($SSH2 "sudo iptables -L FORWARD -v -n | awk '/DROP/{print \$1}' | head -1")

  log "Sending 50 requests through the external LB..."
  for i in $(seq 1 50); do
    curl -sk --max-time 3 -o /dev/null \
      --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
      "https://connect.clientmworkspace.com/healthz" || true
    echo -n "."
  done
  echo ""

  log "NVA1 FORWARD chain after traffic:"
  $SSH1 "sudo iptables -L FORWARD -v -n --line-numbers"
  echo ""

  log "NVA2 FORWARD chain after traffic:"
  $SSH2 "sudo iptables -L FORWARD -v -n --line-numbers"
  echo ""

  log "NVA1 conntrack (App GW + webserver flows):"
  $SSH1 "sudo conntrack -L 2>/dev/null | grep -E '${APPGW_PRIVATE_IP}|${WEBSERVER_IP}' || echo '  (none)'"
  echo ""

  log "NVA2 conntrack (App GW + webserver flows):"
  $SSH2 "sudo conntrack -L 2>/dev/null | grep -E '${APPGW_PRIVATE_IP}|${WEBSERVER_IP}' || echo '  (none)'"
  echo ""

  echo "What to look for:"
  echo "  * Conntrack on either NVA: client→AppGW flows (DNATted, SNATted via eth1)."
  echo "  * NEITHER NVA should have App-GW→webserver flows in conntrack — that leg"
  echo "    bypasses the NVAs via VNet peering. That's the root of the asymmetry."
  echo "  * The NVA that the DMZ LB hashes webserver replies to will show INVALID drops"
  echo "    (rule 2 in the FORWARD chain) — those are SYN-ACKs from the webserver"
  echo "    arriving on eth2 with no matching conntrack entry."
  echo ""
  echo "  Live capture of the bug on eth2:"
  echo "    ssh $ADMIN_USER@${NVA1_IP} \"sudo tcpdump -i eth2 -nn 'host ${WEBSERVER_IP} and host ${APPGW_PRIVATE_IP}'\""
  echo "    ssh $ADMIN_USER@${NVA2_IP} \"sudo tcpdump -i eth2 -nn 'host ${WEBSERVER_IP} and host ${APPGW_PRIVATE_IP}'\""
fi

# ── phase 4: apply the fix ────────────────────────────────────────────────────
if [[ $START_PHASE -le 4 ]]; then
  section "Phase 4 — Apply the fix"

  echo ""
  echo "Three options to make the routing symmetric:"
  echo ""
  echo "  A) Drop the DMZ UDR (route-tables.tf). Webserver replies to App GW go"
  echo "     back via VNet peering — same direct path App GW used inbound."
  echo "     Trade-off: firewalls no longer see App-GW→webserver traffic."
  echo ""
  echo "  B) Restore an AppGW-subnet UDR forcing 10.0.0.0/16 → back LB internal"
  echo "     frontend (10.0.4.4). Inbound App-GW→webserver then goes through an"
  echo "     NVA, conntrack created, return via DMZ LB matches. Catch: back LB"
  echo "     internal rule has enable_floating_ip=false (prod parity), so packet"
  echo "     hits NVA's local INPUT chain — needs eth1:443 DNAT or floating IP on."
  echo ""
  echo "  C) Azure Gateway Load Balancer (Microsoft-recommended). Not in repo."
  echo ""
  echo "Quickest live demonstration (Option A, live on the running webserver):"
  echo "    sudo ip route del default && sudo ip route add default via 10.0.3.1"
  echo "  This drops the UDR-installed default route on the webserver OS so its"
  echo "  reply to App GW uses Azure default routing (peering) instead of DMZ LB."
  echo ""

  read -rp "Apply Option A live on the webserver now (route swap via ProxyJump)? [y/N]: " APPLY
  if [[ ${APPLY,,} == "y" ]]; then
    log "Swapping webserver default route via NVA1 ProxyJump..."
    ssh $SSH_OPTS -J ${ADMIN_USER}@${NVA1_IP} ${ADMIN_USER}@${WEBSERVER_IP} \
      "sudo ip route del default 2>/dev/null; sudo ip route add default via 10.0.3.1 && ip route show default"
    pass "Default route swapped — proceed to Phase 5"
    info "(Reverts on webserver reboot, or by removing the DMZ subnet UDR in Terraform for a permanent fix)"
  else
    warn "Skipping — apply manually, then re-run with --phase 5"
    exit 0
  fi
fi

# ── phase 5: verify the fix ───────────────────────────────────────────────────
if [[ $START_PHASE -le 5 ]]; then
  section "Phase 5 — Verify the fix"

  log "Clearing conntrack tables..."
  $SSH1 "sudo conntrack -F 2>/dev/null || true"
  $SSH2 "sudo conntrack -F 2>/dev/null || true"

  log "Sending 50 requests through the external LB (expect all to succeed)..."
  PASS_COUNT=0; FAIL_COUNT=0
  for i in $(seq 1 50); do
    CODE=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
      --resolve "connect.clientmworkspace.com:443:${ELB_IP}" \
      "https://connect.clientmworkspace.com/healthz" || echo "000")
    if [[ $CODE == "200" ]]; then
      PASS_COUNT=$((PASS_COUNT+1))
      echo -n "."
    else
      FAIL_COUNT=$((FAIL_COUNT+1))
      echo -n "X"
    fi
  done
  echo ""

  if [[ $FAIL_COUNT -eq 0 ]]; then
    pass "Fix confirmed: all 50/50 requests succeeded"
  else
    fail "Still seeing failures: $FAIL_COUNT/50 — check NVA trace output below"
  fi

  echo ""
  log "NVA1 final state:"
  $SSH1 "sudo nva-trace"
  echo ""
  log "NVA2 final state:"
  $SSH2 "sudo nva-trace"
fi

section "Done"
echo ""
echo "NVA1 SSH:  ssh ${ADMIN_USER}@${NVA1_IP}"
echo "NVA2 SSH:  ssh ${ADMIN_USER}@${NVA2_IP}"
echo "Ext LB:    https://${ELB_IP}/healthz (with SNI connect.clientmworkspace.com)"
echo "AppGW:     https://${APPGW_IP}/ (public frontend)"
echo ""
