#!/usr/bin/env bash
# =============================================================================
# NetBird Client Troubleshooting (read-only by default)
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/netbird-troubleshoot.sh)"
#
# Examples:
#   curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/netbird-troubleshoot.sh | bash
#   curl -fsSL ... | bash -s -- --management-url https://netbird.arigonz.com
#   MANAGEMENT_URL=https://netbird.example.com bash netbird-troubleshoot.sh
#   bash netbird-troubleshoot.sh --fix-hints
#
# Safe: does not modify NetBird state, does not use setup keys, does not join.
# Script-Revision: 2026-09-04c (/proc process check + bash watchdog status timeout)
# =============================================================================

set -u

# ──── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$(tput setaf 1 2>/dev/null || printf '\033[0;31m')
  GREEN=$(tput setaf 2 2>/dev/null || printf '\033[0;32m')
  YELLOW=$(tput setaf 3 2>/dev/null || printf '\033[1;33m')
  BLUE=$(tput setaf 4 2>/dev/null || printf '\033[0;34m')
  NC=$(tput sgr0 2>/dev/null || printf '\033[0m')
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

pass() { echo -e "${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}⚠${NC} $1"; WARN=$((WARN + 1)); }
info() { echo -e "${BLUE}→${NC} $1"; }
section() { echo -e "\n${YELLOW}$1${NC}\n$(printf '%.0s─' {1..48})"; }

PASS=0; FAIL=0; WARN=0
FIX_HINTS=0
MANAGEMENT_URL_DEFAULT="https://netbird.arigonz.com"
MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-$MANAGEMENT_URL_DEFAULT}"
HINTS=()
hint() {
  HINTS+=("$1")
  if [[ $FIX_HINTS -eq 1 ]]; then
    echo -e "    ${BLUE}fix:${NC} $1"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

run_sudo() {
  if [[ ${EUID:-0} -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    return 127
  fi
}


# Portable timeout (Synology often lacks GNU timeout / it won't kill sudo children)
run_with_timeout() {
  local secs="$1"; shift
  local out_file rc pid watchdog
  out_file=$(mktemp /tmp/nb-to.XXXXXX 2>/dev/null || echo "/tmp/nb-to.$$")
  "$@" >"$out_file" 2>&1 &
  pid=$!
  (
    sleep "$secs"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  ) &
  watchdog=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  cat "$out_file" 2>/dev/null || true
  rm -f "$out_file" 2>/dev/null || true
  # 143/137 = terminated by signal; treat as timeout if still running logic needed
  if [[ $rc -eq 143 || $rc -eq 137 || $rc -eq 9 ]]; then
    return 124
  fi
  return "$rc"
}

usage() {
  cat <<EOF
NetBird client troubleshooting (read-only)

Options:
  --management-url <url>   Management URL (default: $MANAGEMENT_URL_DEFAULT)
  --fix-hints              Print suggested fix commands after each finding
  -h, --help               Show help

Env:
  NETBIRD_MANAGEMENT_URL   Same as --management-url

This script never deletes config, never runs setup keys, and never joins.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --management-url)
        [[ $# -ge 2 ]] || { echo "Missing value for --management-url" >&2; exit 2; }
        MANAGEMENT_URL="$2"
        shift 2
        ;;
      --fix-hints)
        FIX_HINTS=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1 (use --help)" >&2
        exit 2
        ;;
    esac
  done
}

# Strip trailing slash
normalize_url() {
  local u="$1"
  u="${u%/}"
  echo "$u"
}

http_code() {
  local url="$1"
  local code=""
  if have curl; then
    code=$(curl -sS -m 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  else
    code="000"
  fi
  echo "$code"
}

resolve_host() {
  local host="$1"
  local out=""
  if have dig; then
    out=$(dig +short "$host" A 2>/dev/null | head -n 1 || true)
  fi
  if [[ -z "$out" ]] && have nslookup; then
    out=$(nslookup "$host" 2>/dev/null | awk '/^Address: / && !/#/ {print $2; exit}' || true)
  fi
  if [[ -z "$out" ]] && have host; then
    out=$(host "$host" 2>/dev/null | awk '/has address/ {print $4; exit}' || true)
  fi
  if [[ -z "$out" ]] && have getent; then
    out=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}' || true)
  fi
  if [[ -z "$out" ]] && have ping; then
    # Synology busybox ping sometimes prints resolved IP
    out=$(ping -c 1 -W 2 "$host" 2>/dev/null | head -n 1 | sed -n 's/.*(\([0-9.]*\)).*/\1/p' || true)
  fi
  echo "$out"
}

parse_args "$@"
MANAGEMENT_URL=$(normalize_url "$MANAGEMENT_URL")
MGMT_HOST=$(echo "$MANAGEMENT_URL" | sed -E 's#^https?://##; s#/.*##; s#:.*##')

echo ""
echo "${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
echo "${BLUE}│           NetBird Client Troubleshoot (read-only)            │${NC}"
echo "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""
info "Date: $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
info "Host: $(hostname 2>/dev/null || echo unknown)"
info "User: $(id -un 2>/dev/null || echo unknown) (uid=$(id -u 2>/dev/null || echo ?))"
info "Management URL: $MANAGEMENT_URL"
info "Mode: read-only$([ $FIX_HINTS -eq 1 ] && echo ' + fix hints' || true)"

# ──── 1. OS / platform ───────────────────────────────────────────────────────
section "1. Platform"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  pass "OS: ${PRETTY_NAME:-$NAME $VERSION_ID}"
  if [[ "${ID:-}" == "synology" ]] || grep -qi synology /etc/os-release 2>/dev/null; then
    info "Synology-like OS detected — some Linux tools may be missing (normal)"
  fi
elif [[ -r /etc.defaults/VERSION ]]; then
  # Older Synology
  pass "Synology DSM detected ($(cat /etc.defaults/VERSION 2>/dev/null | tr '\n' ' '))"
else
  warn "Could not determine OS"
fi
uname -a 2>/dev/null | sed 's/^/  /' || true

# Clock skew matters for TLS + peer login expiry
NOW_EPOCH=$(date +%s 2>/dev/null || echo 0)
if [[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] && (( NOW_EPOCH > 1700000000 )); then
  pass "System clock looks plausible (epoch $NOW_EPOCH)"
else
  fail "System clock looks wrong (epoch=${NOW_EPOCH}). Auth/TLS can fail."
  hint "Fix NAS time/NTP (DSM: Control Panel → Regional Options → Time), then retry netbird up"
fi

# ──── 2. Binary / versions ───────────────────────────────────────────────────
section "2. NetBird binary"
if have netbird; then
  NB_PATH=$(command -v netbird)
  pass "netbird found: $NB_PATH"
  NB_VER=$(netbird version 2>/dev/null || netbird --version 2>/dev/null || echo "unknown")
  info "Reported version: $NB_VER"
else
  fail "netbird not in PATH"
  hint "Install client, or use full path. Official: https://docs.netbird.io/how-to/installation/linux"
fi

# ──── 3. Privileges / service ────────────────────────────────────────────────
section "3. Service & privileges"
if [[ ${EUID:-0} -eq 0 ]]; then
  pass "Running as root"
elif have sudo; then
  if sudo -n true 2>/dev/null; then
    pass "Passwordless sudo available"
  else
    warn "sudo available but may prompt for a password for service/status"
  fi
else
  warn "Not root and no sudo — limited service checks"
fi

if have netbird; then
  if run_sudo netbird service status >/tmp/nb-svc-status.$$ 2>&1; then
    pass "netbird service status succeeded"
    sed 's/^/  /' /tmp/nb-svc-status.$$ 2>/dev/null || true
  else
    warn "netbird service status failed (exit $?). Output:"
    sed 's/^/  /' /tmp/nb-svc-status.$$ 2>/dev/null || true
    hint "Use: sudo netbird service status   (service stop/start also need sudo)"
  fi
  rm -f /tmp/nb-svc-status.$$ 2>/dev/null || true

  # Process presence via /proc (avoid hanging Synology ps)
  NB_PROCS=""
  for comm in /proc/[0-9]*/comm; do
    [[ -r "$comm" ]] || continue
    if grep -qi 'netbird' "$comm" 2>/dev/null; then
      pid=$(echo "$comm" | cut -d/ -f3)
      cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | head -c 200)
      NB_PROCS="${NB_PROCS}  pid=$pid ${cmdline:-netbird}\n"
    fi
  done
  if [[ -n "$NB_PROCS" ]]; then
    pass "NetBird-related process(es) visible"
    printf "%b" "$NB_PROCS"
  else
    fail "No netbird process found under /proc"
    hint "sudo netbird service start"
  fi
fi

# ──── 4. Client status ───────────────────────────────────────────────────────
section "4. netbird status"
STATUS_OUT=""
STATUS_TIMEOUT=15
STATUS_RC=0
if have netbird; then
  info "Fetching status (hard timeout ${STATUS_TIMEOUT}s) — wedged daemons hang here"
  # Prefer non-sudo first (faster); fall back to sudo with portable watchdog
  STATUS_OUT=$(run_with_timeout "$STATUS_TIMEOUT" netbird status) || STATUS_RC=$?
  if [[ -z "$STATUS_OUT" || $STATUS_RC -eq 124 ]]; then
    STATUS_RC=0
    if [[ ${EUID:-0} -eq 0 ]]; then
      STATUS_OUT=$(run_with_timeout "$STATUS_TIMEOUT" netbird status) || STATUS_RC=$?
    elif have sudo; then
      # -n: never prompt (password prompt in background = silent hang)
      STATUS_OUT=$(run_with_timeout "$STATUS_TIMEOUT" sudo -n netbird status) || STATUS_RC=$?
    fi
  fi
  if [[ $STATUS_RC -eq 124 ]]; then
    fail "netbird status timed out after ${STATUS_TIMEOUT}s (daemon likely wedged / gRPC hang)"
    hint "sudo netbird service stop; sudo rm -rf /var/lib/netbird/*; sudo netbird service start; then re-join with a fresh setup key"
    STATUS_OUT=""
  elif [[ -n "$STATUS_OUT" ]]; then
    echo "$STATUS_OUT" | sed 's/^/  /'
    echo "$STATUS_OUT" | grep -qi 'Management:.*Connected' && pass "Management Connected" || fail "Management not Connected"
    echo "$STATUS_OUT" | grep -qi 'Signal:.*Connected' && pass "Signal Connected" || fail "Signal not Connected"
    if echo "$STATUS_OUT" | grep -qi 'NeedsLogin\|login has expired\|Disconnected'; then
      warn "Status indicates login/connectivity problem"
      hint "If 'peer login has expired': sudo netbird service stop; sudo rm -rf /var/lib/netbird/*; sudo netbird service start; then re-join with a fresh setup key"
    fi
    if echo "$STATUS_OUT" | grep -qi 'NetBird IP:.*N/A\|NetBird IP: N/A'; then
      warn "No NetBird IP assigned yet"
    fi
  else
    fail "Could not get netbird status"
  fi
fi

# ──── 5. Local state files ───────────────────────────────────────────────────
section "5. Local state & logs"
for d in /etc/netbird /var/lib/netbird /var/log/netbird; do
  if [[ -d "$d" ]]; then
    pass "Directory exists: $d"
    if run_sudo ls -la "$d" >/tmp/nb-ls.$$ 2>&1; then
      sed 's/^/  /' /tmp/nb-ls.$$ | head -n 40
    else
      warn "Cannot list $d (permission?)"
      hint "sudo ls -la $d"
    fi
    rm -f /tmp/nb-ls.$$ 2>/dev/null || true
  else
    warn "Directory missing: $d"
  fi
done

# Common stale-state markers
for f in /etc/netbird/config.json /var/lib/netbird/default.json /var/lib/netbird/config.json /var/lib/netbird/active_profile.json /var/lib/netbird/state.json; do
  if run_sudo test -e "$f" 2>/dev/null; then
    info "Found: $f"
  fi
done

if run_sudo test -f /var/log/netbird/client.log 2>/dev/null; then
  SZ=$(run_sudo wc -c /var/log/netbird/client.log 2>/dev/null | awk '{print $1}')
  if [[ "${SZ:-0}" == "0" ]]; then
    warn "client.log exists but is empty (0 bytes)"
    hint "Reproduce with foreground logs: sudo netbird service stop; sudo netbird up -F --management-url $MANAGEMENT_URL --log-level debug"
  else
    pass "client.log size: ${SZ} bytes (last lines):"
    run_sudo tail -n 30 /var/log/netbird/client.log 2>/dev/null | sed 's/^/  /' || true
  fi
else
  warn "No /var/log/netbird/client.log"
fi

# Rotated logs present?
if run_sudo ls /var/log/netbird/client-*.log.gz >/dev/null 2>&1; then
  info "Rotated gzipped client logs present under /var/log/netbird/"
  hint "Inspect newest: sudo ls -lt /var/log/netbird/ | head; sudo zcat \$(sudo ls -t /var/log/netbird/client-*.log.gz | head -1) | tail -n 80"
fi

# ──── 6. TUN / WireGuard prerequisites ───────────────────────────────────────
section "6. TUN device"
if [[ -e /dev/net/tun ]]; then
  pass "/dev/net/tun exists"
  ls -l /dev/net/tun 2>/dev/null | sed 's/^/  /' || true
else
  fail "/dev/net/tun missing — WireGuard kernel mode will fail"
  hint "Synology: load TUN module / follow https://docs.netbird.io/get-started/install/synology reboot script notes"
fi

if have lsmod; then
  if lsmod 2>/dev/null | grep -qi '^tun\|wireguard'; then
    pass "Kernel modules related to tun/wireguard visible"
    lsmod 2>/dev/null | grep -iE 'tun|wireguard' | sed 's/^/  /' || true
  else
    warn "tun/wireguard modules not listed (may still use userspace)"
  fi
fi

# ──── 7. DNS + reachability to management ────────────────────────────────────
section "7. Reachability to management"
info "Resolving $MGMT_HOST ..."
RESOLVED=$(resolve_host "$MGMT_HOST")
if [[ -n "$RESOLVED" ]]; then
  pass "$MGMT_HOST resolves to $RESOLVED"
else
  fail "$MGMT_HOST did not resolve from this host"
  hint "Check DNS on the NAS; try: ping -c 2 $MGMT_HOST"
fi

if have curl; then
  CODE_OIDC=$(http_code "$MANAGEMENT_URL/oauth2/.well-known/openid-configuration")
  if [[ "$CODE_OIDC" == "200" ]]; then
    pass "OIDC discovery HTTP $CODE_OIDC ($MANAGEMENT_URL/oauth2/.well-known/openid-configuration)"
  else
    fail "OIDC discovery HTTP $CODE_OIDC (want 200)"
    hint "Management HTTPS must be reachable: curl -v $MANAGEMENT_URL/oauth2/.well-known/openid-configuration"
  fi

  CODE_API=$(http_code "$MANAGEMENT_URL/api/")
  info "GET $MANAGEMENT_URL/api/ → HTTP $CODE_API (404 can still be OK if server answers)"
  if [[ "$CODE_API" == "000" ]]; then
    fail "No HTTP response from management API path"
  elif [[ "$CODE_API" =~ ^[45] ]]; then
    warn "API path returned $CODE_API — server reachable but path may differ"
  else
    pass "Management API path responded ($CODE_API)"
  fi

  # TLS detail (best effort)
  if curl -sS -m 10 -o /dev/null -w "tls_http=%{http_code} ssl_verify=%{ssl_verify_result} time=%{time_total}s\n" "$MANAGEMENT_URL/" 2>/tmp/nb-curl-err.$$; then
    :
  fi
  if [[ -s /tmp/nb-curl-err.$$ ]]; then
    warn "curl stderr: $(tr '\n' ' ' </tmp/nb-curl-err.$$)"
  fi
  rm -f /tmp/nb-curl-err.$$ 2>/dev/null || true
else
  fail "curl not installed — cannot test HTTPS"
  hint "Install curl, then re-run this script"
fi

# TCP 443 check via bash /dev/tcp if available
if timeout 3 bash -c "echo >/dev/tcp/${MGMT_HOST}/443" 2>/dev/null; then
  pass "TCP ${MGMT_HOST}:443 is open from this host"
else
  warn "Could not confirm TCP ${MGMT_HOST}:443 via /dev/tcp (may be normal on busybox)"
fi

info "Note: HTTPS 200 does not prove gRPC/Signal works. Hanging 'netbird up' with DeadlineExceeded often means gRPC/WebSocket paths are broken on the reverse proxy."

# ──── 8. Common failure signatures ───────────────────────────────────────────
section "8. Interpretation"
cat <<EOF
  Common issues we see on Synology / self-hosted:
  • peer login has expired
      → stop service (sudo), wipe /var/lib/netbird/*, start service, re-join with setup key
      → also delete stale peer in the dashboard if it still exists
  • DeadlineExceeded / hanging netbird up
      → HTTPS works but management gRPC/signal/websocket may be blocked or mis-proxied
  • Management/Signal Disconnected, NetBird IP N/A
      → not joined yet, or daemon stuck mid-login
  • service stop exit status 4
      → almost always missing sudo (use: sudo netbird service stop)
  • empty client.log
      → use foreground: sudo netbird up -F --log-level debug --management-url $MANAGEMENT_URL
EOF

# ──── Summary ────────────────────────────────────────────────────────────────
section "Summary"
echo -e "  ${GREEN}PASS${NC}: $PASS   ${YELLOW}WARN${NC}: $WARN   ${RED}FAIL${NC}: $FAIL"
echo ""
if [[ $FAIL -gt 0 ]]; then
  echo "Next: fix ✗ items first, then re-run this script."
elif [[ $WARN -gt 0 ]]; then
  echo "No hard failures detected, but review ⚠ items."
else
  echo "All checks passed."
fi

if [[ ${#HINTS[@]} -gt 0 ]]; then
  echo ""
  echo "Suggested commands (review before running):"
  for h in "${HINTS[@]}"; do
    echo "  • $h"
  done
fi

echo ""
echo "Re-run:"
echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/netbird-troubleshoot.sh)\" -- --management-url $MANAGEMENT_URL --fix-hints"
echo ""

# Exit non-zero if hard failures (useful for automation)
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
