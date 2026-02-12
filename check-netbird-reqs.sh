#!/usr/bin/env bash
# NetBird Self-Hosted Pre-Installation Requirements Checker
# Checks hardware, network, software, and recommended setup items
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-netbird-reqs.sh)"

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "\n${YELLOW}NetBird Self-Hosted Installation Requirements Check${NC}"
echo "===================================================="
echo -e "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')\n"

# ────────────────────────────────────────────────────────────────
#  Helper functions
# ────────────────────────────────────────────────────────────────
fail() { echo -e "${RED}✗ $1${NC}"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

check_command() {
    local cmd="$1"
    local desc="$2"
    if command -v "$cmd" &>/dev/null; then
        pass "$desc is installed"
        return 0
    else
        fail "$desc is NOT installed"
        return 1
    fi
}

check_port_tcp() {
    local port="$1"
    local desc="$2"
    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        warn "Port $port/tcp is in use locally"
        return 1
    else
        pass "Port $port/tcp appears free locally"
        return 0
    fi
}

check_port_udp() {
    local port="$1"
    local desc="$2"
    # UDP check is trickier — we just warn if netstat/ss shows listener
    if command -v ss >/dev/null && ss -uln | grep -q ":$port "; then
        warn "Port $port/udp appears to be in use locally"
        return 1
    elif command -v netstat >/dev/null && netstat -uln 2>/dev/null | grep -q ":$port "; then
        warn "Port $port/udp appears to be in use locally"
        return 1
    else
        pass "Port $port/udp appears free locally (best-effort check)"
        return 0
    fi
}

# ────────────────────────────────────────────────────────────────
#  1. OS Check
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Operating System${NC}"
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
        pass "Ubuntu 24.04 LTS detected ($PRETTY_NAME)"
    else
        fail "This script expects Ubuntu 24.04 LTS (found: ${PRETTY_NAME:-unknown})"
        echo "   Continuing anyway — results may be inaccurate"
    fi
else
    fail "Cannot determine OS (/etc/os-release not found)"
fi

# ────────────────────────────────────────────────────────────────
#  2. Hardware
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Hardware Requirements${NC}"

# CPU cores
cores=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "unknown")
echo "CPU cores: $cores"
if [[ "$cores" =~ ^[0-9]+$ ]]; then
    if (( cores >= 2 )); then
        pass "≥ 2 CPU cores (recommended)"
    elif (( cores >= 1 )); then
        warn "Only $cores CPU core — meets minimum but below recommendation"
    else
        fail "Could not detect CPU cores"
    fi
else
    warn "Could not reliably detect CPU cores"
fi

# RAM (in MB)
ram_mb=$(free -m | awk '/^Mem:/{print $2}' 2>/dev/null || echo "unknown")
echo "Memory: ${ram_mb} MB"
if [[ "$ram_mb" =~ ^[0-9]+$ ]]; then
    if (( ram_mb >= 4000 )); then
        pass "≥ 4 GB RAM (recommended)"
    elif (( ram_mb >= 2000 )); then
        warn "${ram_mb} MB RAM — meets minimum (2 GB) but below recommendation"
    else
        fail "Less than 2 GB RAM detected"
    fi
else
    fail "Could not detect RAM amount"
fi

# Disk space (root partition)
disk_free_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G' 2>/dev/null || echo "unknown")
echo "Free disk space on /: ${disk_free_gb} GB"
if [[ "$disk_free_gb" =~ ^[0-9]+$ ]]; then
    if (( disk_free_gb >= 10 )); then
        pass "≥ 10 GB free (minimum met)"
    else
        fail "Only ${disk_free_gb} GB free — need at least 10 GB"
    fi
else
    fail "Could not detect free disk space"
fi

# ────────────────────────────────────────────────────────────────
#  3. Network
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Network Requirements${NC}"

# Public IP (basic check)
public_ip=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "failed")
if [[ "$public_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    pass "Public IPv4 detected: $public_ip"
elif [[ "$public_ip" == "failed" ]]; then
    warn "Could not detect public IP (check internet connectivity)"
else
    warn "Public IP detection returned unexpected result"
fi

# Ports (local listener check only — external reachability needs external tool)
echo "Local port availability check (TCP/UDP listeners):"
check_port_tcp 80  "TCP 80 (HTTP - Let's Encrypt)"  || true
check_port_tcp 443 "TCP 443 (HTTPS)"               || true
check_port_udp 3478 "UDP 3478 (STUN/TURN)"         || true

echo -e "  ${YELLOW}Note:${NC} This only checks local usage."
echo "  External reachability (firewall/cloud security group) must be verified separately."

# ────────────────────────────────────────────────────────────────
#  4. Required Software
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Required Software${NC}"
check_command curl "curl"           || true
check_command jq   "jq"             || true

# Docker
if command -v docker >/dev/null && docker --version >/dev/null 2>&1; then
    docker_ver=$(docker --version | cut -d' ' -f3 | tr -d ',')
    pass "Docker is installed ($docker_ver)"
else
    fail "Docker is NOT installed or not working"
fi

# Docker Compose v2 (modern 'docker compose' command)
if docker compose version >/dev/null 2>&1; then
    compose_ver=$(docker compose version --short 2>/dev/null || echo "unknown")
    pass "Docker Compose v2 is installed ($compose_ver)"
elif command -v docker-compose >/dev/null; then
    warn "Found legacy 'docker-compose' — NetBird prefers v2 'docker compose' plugin"
else
    fail "Docker Compose v2 plugin is NOT installed ('docker compose' command missing)"
fi

# ────────────────────────────────────────────────────────────────
#  5. Strongly Recommended
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Strongly Recommended${NC}"

# Domain name resolution
if [[ -n "${public_ip:-}" && "$public_ip" != "failed" ]]; then
    resolved_ip=$(dig +short whoami.cloudflare.com @1.1.1.1 TXT 2>/dev/null | tr -d '"' || echo "")
    if [[ -n "$resolved_ip" && "$resolved_ip" == "$public_ip" ]]; then
        pass "This server's public IP resolves correctly (via whoami.cloudflare.com)"
    else
        warn "Could not confirm reverse DNS / domain pointing to this server"
        echo "  Recommended: have a domain A record pointing to $public_ip"
    fi
fi

# Root / sudo
if [[ $EUID -eq 0 ]]; then
    pass "Running as root"
elif sudo -n true 2>/dev/null; then
    pass "User has passwordless sudo access"
else
    warn "No root privileges detected (some steps may require sudo)"
fi

echo -e "\n${YELLOW}Summary${NC}"
echo "Run this script again after fixing any ${RED}✗${NC} or ${YELLOW}⚠${NC} items."
echo -e "After all critical checks pass → proceed with NetBird installation.\n"

exit 0
