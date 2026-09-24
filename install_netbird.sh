#!/usr/bin/env bash
# =============================================================================
# Compatibility wrapper -> install-netbird-client.sh
#
# Keeps old one-liners working. Defaults to --no-ui (safe for Proxmox/servers).
# Main script enables NetBird --allow-server-ssh and OpenSSH by default.
#
# Preferred:
#   curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/install-netbird-client.sh \
#     | sudo bash -s -- --no-ui --setup-key "$NETBIRD_SETUP_KEY"
# =============================================================================
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/install-netbird-client.sh"

if [[ ${EUID:-0} -ne 0 ]]; then
  echo "Run as root (sudo)" >&2
  exit 1
fi

args=("$@")
has_ui_flag=0
for a in "${args[@]+"${args[@]}"}"; do
  case "$a" in --ui|--no-ui) has_ui_flag=1 ;; esac
done
if [[ $has_ui_flag -eq 0 ]]; then
  args=(--no-ui "${args[@]+"${args[@]}"}")
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$RAW_URL" -o "$tmp"
chmod +x "$tmp"
exec bash "$tmp" "${args[@]}"
