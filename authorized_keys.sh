#!/usr/bin/env bash
# =============================================================================
# authorized_keys.sh — Add authorized SSH keys if not already present.
# Safe console/TTY — no blank screen. Idempotent — safe to re-run.
#
# Run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys.sh)"
# =============================================================================

set -euo pipefail

SSH_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx"
)

AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys"

# Ensure ~/.ssh exists with correct permissions
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

# Ensure authorized_keys exists with correct permissions
touch "${AUTHORIZED_KEYS}"
chmod 600 "${AUTHORIZED_KEYS}"

added=0
skipped=0

for key in "${SSH_KEYS[@]}"; do
    # Extract the key material (second field) for comparison
    key_material=$(echo "${key}" | awk '{print $2}')

    if grep -qF "${key_material}" "${AUTHORIZED_KEYS}"; then
        echo "[SKIP] Already authorized: ${key}"
        (( skipped++ ))
    else
        echo "${key}" >> "${AUTHORIZED_KEYS}"
        echo "[ADDED] Key added: ${key}"
        (( added++ ))
    fi
done

echo ""
echo "Done. Added: ${added}, Skipped (already present): ${skipped}"
