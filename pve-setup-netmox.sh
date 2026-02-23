#!/bin/bash
set -e
# =====================================================
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-setup-netmox.sh)"
# Version .08
# =====================================================

echo -e "\e[34m╔══════════════════════════════════════════════════════════════╗\e[0m"
echo -e "\e[34m║              pve-setup-netmox.sh (v0.08)                     ║\e[0m"
echo -e "\e[34m╟──────────────────────────────────────────────────────────────╢\e[0m"
echo -e "\e[34m║      Proxmox Cluster Setup over NetBird                      ║\e[0m"
echo -e "\e[34m╚══════════════════════════════════════════════════════════════╝\e[0m"

# ==================== CONFIG ====================
CLUSTER_NAME="netbird-cluster"

PRIMARY_NODE="pve-00.netbird.selfhosted"

NODES=(
  "pve-00.netbird.selfhosted"
  "pve-01.netbird.selfhosted"
  "pve-02.netbird.selfhosted"
  "pve-03.netbird.selfhosted"
)
# ===============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"

get_nb_ip() {
  local ip=$(netbird status --json 2>/dev/null | jq -r '.NetBirdIP // empty' | cut -d/ -f1)
  if [[ -z "$ip" || "$ip" == "null" ]]; then
    ip=$(ip -4 addr show wt0 2>/dev/null | grep -oP '(?<=inet\s)100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d+\.\d+' | head -n1)
  fi
  [[ -z "$ip" ]] && err "Could not detect NetBird IP (check netbird status)"
  echo "$ip"
}

resolve_ip() {
  getent hosts "$1" | awk '{print $1}' | head -n1
}

is_prepared() { [ -f "/root/.netmox-prepared" ]; }
is_clustered() { pvecm status 2>/dev/null | grep -q "Cluster Name:"; }

# ==================== AUTO DETECTION ====================
THIS_NODE="$(hostname).netbird.selfhosted"
IS_PRIMARY=$([[ "$THIS_NODE" == "$PRIMARY_NODE" ]] && echo true || echo false)

log "Detected this node → $THIS_NODE (Primary: $IS_PRIMARY)"

if ! printf '%s\n' "${NODES[@]}" | grep -qx "$THIS_NODE"; then
  err "This node ($THIS_NODE) is not in the NODES list!"
fi

# ==================== PREPARE (REBUILDS /etc/hosts) ====================
prepare() {
  log "=== Netmox Prepare ==="
  command -v netbird >/dev/null || err "netbird not found"
  netbird status | grep -q "Connected" || err "NetBird is not connected"

  MY_IP=$(get_nb_ip)
  SHORT=$(hostname -s)
  log "This node's NetBird IP = $MY_IP"

  log "Rebuilding /etc/hosts — forcing NetBird IP only (no more 10.0.4.77!)"
  cp /etc/hosts /etc/hosts.netmox.bak 2>/dev/null || true

  cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters

# Netmox NetBird Cluster - ONLY NetBird IPs
$MY_IP   $THIS_NODE   $SHORT

EOF

  for node in "${NODES[@]}"; do
    if [[ "$node" != "$THIS_NODE" ]]; then
      ip=$(resolve_ip "$node")
      if [[ -n "$ip" ]]; then
        short=${node%%.*}
        echo "$ip   $node   $short" >> /etc/hosts
        log "  $short → $ip"
      fi
    fi
  done

  log "Adding Corosync firewall rules..."
  apt-get install -y iptables-persistent net-tools jq
  IFACE="wt0"
  iptables -I INPUT  -i "$IFACE" -p udp --dport 5404:5405 -j ACCEPT 2>/dev/null || true
  iptables -I OUTPUT -o "$IFACE" -p udp --sport 5404:5405 -j ACCEPT 2>/dev/null || true
  netfilter-persistent save

  touch "/root/.netmox-prepared"
  log "✅ Prepare completed (hosts rebuilt)"
}

# ==================== CREATE / JOIN ====================
create() {
  [[ "$IS_PRIMARY" != true ]] && err "Not the primary node"
  log "=== Creating cluster ==="
  MY_IP=$(get_nb_ip)
  log "Using NetBird IP: $MY_IP"
  pvecm create "$CLUSTER_NAME" --link0 "$MY_IP" || err "pvecm create failed"
  log "✅ Cluster created successfully!"
}

join() {
  [[ "$IS_PRIMARY" == true ]] && err "Primary node does not join"
  log "=== Joining cluster ==="

  PRIMARY_IP=$(resolve_ip "$PRIMARY_NODE")
  [[ -z "$PRIMARY_IP" ]] && err "Cannot resolve primary $PRIMARY_NODE"

  MY_IP=$(get_nb_ip)
  log "Primary IP   = $PRIMARY_IP"
  log "This node IP = $MY_IP"

  pvecm add "$PRIMARY_IP" --link0 "$MY_IP" || err "pvecm add failed - check the errors above"
  log "✅ Successfully joined the cluster!"
  echo ""
  log "Waiting 6 seconds for sync..."
  sleep 6
  log "Restarting cluster services..."
  systemctl restart corosync pve-cluster
}

# ==================== STATUS ====================
status() {
  echo "=== NetBird ==="
  netbird status
  echo -e "\n=== Cluster ==="
  pvecm status 2>/dev/null || echo "No cluster yet"
}

# ==================== WIZARD ====================
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
  log "First run → running prepare automatically..."
  prepare
fi

if is_clustered; then
  log "This node is already in a cluster!"
  status
  exit 0
fi

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
    status
    ;;
  2) status ;;
  *) log "Exiting. Run again anytime." ;;
esac
