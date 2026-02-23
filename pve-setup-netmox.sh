#!/bin/bash
set -e
# =====================================================
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-setup-netmox.sh)"
# Version .03
# =====================================================

# Fancy header banner
echo -e "\e[34m╔══════════════════════════════════════════════════════════════╗\e[0m"
echo -e "\e[34m║              pve-setup-netmox.sh (v0.03)                     ║\e[0m"
echo -e "\e[34m╟──────────────────────────────────────────────────────────────╢\e[0m"

# ==================== CONFIG (edit only these two things) ====================
CLUSTER_NAME="netbird-cluster"

PRIMARY_NODE="pve-00.netbird.selfhosted"   # ← change ONLY if your primary has a different name

# All nodes in your cluster (add or remove as needed)
NODES=(
  "pve-00.netbird.selfhosted"
  "pve-01.netbird.selfhosted"
  "pve-02.netbird.selfhosted"
  "pve-03.netbird.selfhosted"
)
# ===========================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"

# ==================== AUTO-DETECTION (no more mistakes) ====================
THIS_NODE="$(hostname).netbird.selfhosted"
IS_PRIMARY=$([[ "$THIS_NODE" == "$PRIMARY_NODE" ]] && echo true || echo false)

log "Detected this node → $THIS_NODE (Primary: $IS_PRIMARY)"

# Safety check
if ! printf '%s\n' "${NODES[@]}" | grep -qx "$THIS_NODE"; then
  err "This node ($THIS_NODE) is not in the NODES list. Please update the config."
fi

get_nb_ip() {
  netbird status --json 2>/dev/null | jq -r '.NetBirdIP' | cut -d/ -f1 || echo ""
}

resolve_ip() {
  getent hosts "$1" | awk '{print $1}' | head -n1
}

is_prepared() { [ -f "/root/.netmox-prepared" ]; }
is_clustered() { pvecm status 2>/dev/null | grep -q "Cluster Name:"; }

# ==================== PREPARE ====================
prepare() {
  log "=== Netmox Prepare ==="
  command -v netbird >/dev/null || err "netbird not found"
  netbird status | grep -q "Connected" || err "NetBird is not connected"

  MY_IP=$(get_nb_ip)
  [[ -z "$MY_IP" ]] && err "Could not get NetBird IP"

  # /etc/hosts
  log "Updating /etc/hosts..."
  cp /etc/hosts /etc/hosts.netmox.bak 2>/dev/null || true
  sed -i '/# Netmox NetBird Cluster/d' /etc/hosts
  sed -i '/\.netbird\.selfhosted/d' /etc/hosts 2>/dev/null || true
  echo "# Netmox NetBird Cluster" >> /etc/hosts
  for node in "${NODES[@]}"; do
    ip=$(resolve_ip "$node")
    if [[ -n "$ip" ]]; then
      short=${node%%.*}
      echo "$ip   $node   $short" >> /etc/hosts
      log "  $node → $ip"
    else
      warn "Could not resolve $node"
    fi
  done

  # Firewall
  log "Adding Corosync firewall rules..."
  apt-get install -y iptables-persistent net-tools
  IFACE="wt0"
  iptables -I INPUT  -i "$IFACE" -p udp --dport 5404:5405 -j ACCEPT 2>/dev/null || true
  iptables -I OUTPUT -o "$IFACE" -p udp --sport 5404:5405 -j ACCEPT 2>/dev/null || true
  netfilter-persistent save

  touch "/root/.netmox-prepared"
  log "✅ Prepare completed"
}

# ==================== CREATE ====================
create() {
  [[ "$IS_PRIMARY" != true ]] && err "Not the primary node"
  log "=== Creating cluster ==="
  MY_IP=$(get_nb_ip)
  pvecm create "$CLUSTER_NAME" --link0 "$MY_IP"
  log "✅ Cluster created!"
}

# ==================== JOIN ====================
join() {
  [[ "$IS_PRIMARY" == true ]] && err "Primary node does not join"
  log "=== Joining cluster ==="
  PRIMARY_IP=$(resolve_ip "$PRIMARY_NODE")
  [[ -z "$PRIMARY_IP" ]] && err "Cannot resolve $PRIMARY_NODE"
  MY_IP=$(get_nb_ip)
  pvecm add "$PRIMARY_IP" --link0 "$MY_IP"
  log "✅ Successfully joined the cluster!"
}

# ==================== STATUS ====================
status() {
  echo "=== NetBird ==="
  netbird status
  echo -e "\n=== Cluster ==="
  pvecm status 2>/dev/null || echo "No cluster yet"
}

# ==================== WIZARD MODE (just run the script) ====================
if [[ -n "$1" ]]; then
  case "$1" in
    prepare) prepare ;;
    create)  create ;;
    join)    join ;;
    status)  status ;;
    *)       echo "Usage: $0 [prepare|create|join|status]"; exit 1 ;;
  esac
  exit 0
fi

if ! is_prepared; then
  log "Prepare has not run yet → running automatically..."
  prepare
fi

if is_clustered; then
  log "This node is already in a cluster!"
  status
  exit 0
fi

# Not clustered → smart menu
log "Node is ready but not clustered yet."
echo ""
if [[ "$IS_PRIMARY" == true ]]; then
  echo "PRIMARY node ($THIS_NODE)"
  echo "  1) Create the cluster"
else
  echo "Secondary node ($THIS_NODE)"
  echo "  1) Join the cluster"
fi
echo "  2) Show status"
echo "  3) Quit"
echo ""
read -p "Choose [1-3]: " choice

case "$choice" in
  1)
    if [[ "$IS_PRIMARY" == true ]]; then create; else join; fi
    ;;
  2) status ;;
  *) log "Exiting. Run the script again anytime." ;;
esac
