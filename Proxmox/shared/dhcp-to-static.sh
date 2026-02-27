#!/bin/bash
# =============================================================================
# dhcp-to-static.sh
# Automatically detects DHCP network settings and locks them in as static IP.
#
# Compatible with:
#   - Proxmox Virtual Environment (PVE)
#   - Proxmox Backup Server (PBS)
#   - Proxmox Mail Gateway (PMG)
#
# USAGE:
#   First-time install (from GitHub):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared/dhcp-to-static.sh)"
#
#   Run manually (already installed):
#     /usr/local/sbin/dhcp-to-static.sh --run
#
#   Uninstall:
#     /usr/local/sbin/dhcp-to-static.sh --uninstall
#
# On first run (install mode), the script:
#   1. Downloads and saves itself to /usr/local/sbin/ (used by systemd)
#   2. Saves an offline copy to /root/
#   3. Embeds and writes the systemd service file
#   4. Enables the service so it runs on every future reboot
#
# On every reboot (run mode, called by systemd):
#   1. Waits for NICs to initialize
#   2. Requests a fresh DHCP lease
#   3. Writes the obtained IP+gateway as static config
#   4. Applies the IP live (no extra reboot needed)
#   5. Updates /etc/hosts
# =============================================================================

# =============================================================================
# CONFIGURATION — All user-tunable settings live here
# =============================================================================

# GitHub raw URL where this script is hosted.
# Used to download fresh copies of itself during installation.
GITHUB_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared/dhcp-to-static.sh"

# Where the script installs itself — this is what systemd calls on each reboot.
INSTALL_PATH="/usr/local/sbin/dhcp-to-static.sh"

# Offline backup copy saved here for manual access without internet.
OFFLINE_COPY_PATH="/root/dhcp-to-static.sh"

# Systemd service file path.
SERVICE_FILE="/etc/systemd/system/dhcp-to-static.service"

# Network interface to configure.
# "auto" = auto-detect based on Proxmox product (recommended).
# Or set explicitly: "vmbr0", "ens18", "eth0", etc.
INTERFACE="auto"

# Seconds to wait after script start before the first DHCP attempt.
# Gives NICs/bridges time to fully initialize after boot.
INITIAL_WAIT=20

# Seconds between DHCP retry attempts on failure.
RETRY_INTERVAL=10

# Total seconds to keep retrying DHCP before giving up.
MAX_RETRY_DURATION=120

# Update /etc/hosts with the new IP and hostname? (true/false)
# Recommended: true — Proxmox relies on /etc/hosts for internal resolution.
UPDATE_HOSTS=true

# Run product-specific post-config checks? (true/false)
# e.g. Warns PVE cluster users if corosync.conf may need updating.
UPDATE_PRODUCT_CONFIG=true

# Log file path.
LOG_FILE="/var/log/dhcp-to-static.log"

# Max log file size in bytes before it is rotated. Default: 1MB.
LOG_MAX_SIZE=1048576

# =============================================================================
# INTERNAL — Do not edit below unless you know what you are doing
# =============================================================================

SCRIPT_VERSION="1.1"

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}
log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok()    { log "OK   " "$@"; }

rotate_log() {
    if [ -f "$LOG_FILE" ] && \
       [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log_info "Log rotated."
    fi
}

# =============================================================================
# PROXMOX PRODUCT DETECTION
# =============================================================================

detect_proxmox_product() {
    if   command -v pveversion            &>/dev/null; then echo "PVE"
    elif command -v proxmox-backup-manager &>/dev/null; then echo "PBS"
    elif command -v pmgconfig              &>/dev/null; then echo "PMG"
    elif dpkg -l pve-manager              &>/dev/null 2>&1; then echo "PVE"
    elif dpkg -l proxmox-backup           &>/dev/null 2>&1; then echo "PBS"
    elif dpkg -l proxmox-mailgateway      &>/dev/null 2>&1; then echo "PMG"
    else echo "UNKNOWN"
    fi
}

# =============================================================================
# INTERFACE RESOLUTION
# =============================================================================

resolve_interface() {
    local product="$1"

    # User specified an interface — validate it exists
    if [ "$INTERFACE" != "auto" ]; then
        if ip link show "$INTERFACE" &>/dev/null; then
            echo "$INTERFACE"; return 0
        else
            log_error "Configured interface '$INTERFACE' does not exist."
            return 1
        fi
    fi

    # PVE uses a Linux bridge
    if [ "$product" = "PVE" ]; then
        for iface in vmbr0 vmbr1 vmbr2; do
            if ip link show "$iface" &>/dev/null; then
                echo "$iface"; return 0
            fi
        done
        log_warn "No vmbr bridge found for PVE — falling back to physical NIC."
    fi

    # PBS / PMG / fallback: find first physical NIC with an active carrier
    local candidates
    candidates=$(ip -o link show \
        | awk -F': ' '{print $2}' \
        | grep -v '^lo$' \
        | grep -v '^vmbr' \
        | grep -v '^docker' \
        | grep -v '^virbr')

    for iface in $candidates; do
        local carrier
        carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo "0")
        if [ "$carrier" = "1" ]; then
            echo "$iface"; return 0
        fi
    done

    # No carrier detected — return first candidate anyway
    echo "$candidates" | head -1
}

# =============================================================================
# DHCP
# =============================================================================

prepare_interface_for_dhcp() {
    local iface="$1"
    log_info "Bringing up interface $iface..."
    ip link set "$iface" up 2>/dev/null
    sleep 2

    # For PVE bridges: also bring up all bridge member ports
    if [[ "$iface" == vmbr* ]]; then
        local slaves
        slaves=$(ls /sys/class/net/"$iface"/brif/ 2>/dev/null)
        for slave in $slaves; do
            log_info "Bringing up bridge member: $slave"
            ip link set "$slave" up 2>/dev/null
        done
        sleep 2
    fi
}

release_existing_lease() {
    local iface="$1"
    log_info "Releasing any existing DHCP lease on $iface..."

    # Ensure /var/lib/dhcp exists (may be absent on fresh PBS/PMG installs)
    mkdir -p /var/lib/dhcp 2>/dev/null

    # Release any active lease
    dhclient -r "$iface" 2>/dev/null

    # Remove stale lease and PID files that could interfere with the next request.
    # dhclient -r should clean the PID file but may not if it was already dead.
    rm -f "/var/lib/dhcp/dhclient.${iface}.leases" 2>/dev/null
    rm -f "/run/dhclient.${iface}.pid" 2>/dev/null

    sleep 1
}

# Returns "IP GATEWAY PREFIX" on success, empty string on failure
get_dhcp_lease() {
    local iface="$1"
    log_info "Requesting DHCP lease on $iface..."

    mkdir -p /var/lib/dhcp 2>/dev/null
    dhclient -v -1 \
        -pf "/run/dhclient.${iface}.pid" \
        -lf "/var/lib/dhcp/dhclient.${iface}.leases" \
        "$iface" >> "$LOG_FILE" 2>&1

    sleep 2

    local leased_ip leased_prefix leased_gw

    leased_ip=$(ip -4 addr show "$iface" \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    leased_prefix=$(ip -4 addr show "$iface" \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\K\d+' | head -1)
    leased_gw=$(ip route show default dev "$iface" 2>/dev/null \
        | awk '{print $3}' | head -1)

    # Fallback to global default route if per-interface lookup fails
    if [ -z "$leased_gw" ]; then
        leased_gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    fi

    if [ -n "$leased_ip" ] && [ -n "$leased_gw" ]; then
        leased_prefix="${leased_prefix:-24}"
        log_ok "Lease obtained: IP=$leased_ip/$leased_prefix  GW=$leased_gw"
        echo "$leased_ip $leased_gw $leased_prefix"
    else
        log_warn "DHCP attempt returned no usable IP/gateway."
        echo ""
    fi
}

# =============================================================================
# STATIC NETWORK CONFIG
# =============================================================================

apply_static_network_config() {
    local iface="$1" new_ip="$2" gateway="$3" prefix="$4" product="$5"

    log_info "Writing static config: $iface -> $new_ip/$prefix via $gateway"

    local backup="/etc/network/interfaces.bak.$(date '+%Y%m%d%H%M%S')"
    cp /etc/network/interfaces "$backup"
    log_info "Backup saved: $backup"

    local tmpfile
    tmpfile=$(mktemp)

    # Carry forward existing DNS settings if present
    local dns_servers dns_search
    dns_servers=$(grep -oP '(?<=dns-nameservers\s).*' /etc/network/interfaces 2>/dev/null | head -1)
    dns_search=$(grep -oP '(?<=dns-search\s).*'       /etc/network/interfaces 2>/dev/null | head -1)

    # Preserve everything that is NOT our target interface's block.
    # Strategy: track when we enter our interface's block and suppress
    # all lines until we hit the next top-level directive or EOF.
    awk -v iface="$iface" '
        BEGIN { skip=0 }
        # A top-level directive line (not indented)
        /^[^[:space:]]/ {
            # Is this the start of our target interface block?
            if (/^(auto|iface|allow-[a-z]+)[[:space:]]/ && $2 == iface) {
                skip=1
                next
            }
            # It is a different top-level line — stop skipping and print it
            skip=0
            print
            next
        }
        # Indented/continuation line — suppress if we are inside our block
        skip { next }
        # Everything else — print
        { print }
    ' /etc/network/interfaces > "$tmpfile"

    # Append new static block
    {
        echo ""
        echo "auto $iface"
        echo "iface $iface inet static"
        echo "        address $new_ip/$prefix"
        echo "        gateway $gateway"
        [ -n "$dns_servers" ] && echo "        dns-nameservers $dns_servers"
        [ -n "$dns_search"  ] && echo "        dns-search $dns_search"

        # PVE bridges need bridge options preserved
        if [ "$product" = "PVE" ] && [[ "$iface" == vmbr* ]]; then
            local ports
            ports=$(ls /sys/class/net/"$iface"/brif/ 2>/dev/null \
                | tr '\n' ' ' | sed 's/ $//')
            [ -n "$ports" ] && echo "        bridge-ports $ports"
            echo "        bridge-stp off"
            echo "        bridge-fd 0"
        fi
    } >> "$tmpfile"

    mv "$tmpfile" /etc/network/interfaces
    log_ok "/etc/network/interfaces updated."
}

apply_ip_live() {
    local iface="$1" new_addr="$2" gateway="$3" prefix="$4"
    log_info "Applying new IP live on $iface (no reboot needed)..."
    ip addr flush dev "$iface" 2>/dev/null
    ip addr add "$new_addr/$prefix" dev "$iface" 2>/dev/null
    ip route del default 2>/dev/null
    ip route add default via "$gateway" dev "$iface" 2>/dev/null
    log_ok "Live: $new_addr/$prefix via $gateway on $iface"
}

update_hosts_file() {
    local new_ip="$1"
    local hostname fqdn
    hostname=$(hostname -s 2>/dev/null || hostname)
    fqdn=$(hostname --fqdn 2>/dev/null || echo "$hostname")

    log_info "Updating /etc/hosts -> $new_ip  $fqdn  $hostname"
    cp /etc/hosts "/etc/hosts.bak.$(date '+%Y%m%d%H%M%S')"

    # Escape regex special chars in hostname/fqdn before using in sed patterns.
    # Dots in FQDNs (e.g. "pve.local") must be literal, not wildcards.
    local hn_esc fqdn_esc
    hn_esc=$(printf '%s' "$hostname" | sed 's/[][.*^$\\]/\\&/g')
    fqdn_esc=$(printf '%s' "$fqdn"   | sed 's/[][.*^$\\]/\\&/g')

    # Remove existing non-loopback entries for this hostname/fqdn.
    # Line 1: replace hostname in any non-127.x line with a space (cleaned up by line 3).
    # Line 2: delete any line containing the fqdn (catches old IP entries).
    # Line 3: delete lines that are now a bare IPv4 address with no hostname.
    # NOTE: 127.x and ::1 loopback lines are never touched.
    sed -i "/^127\./!s/[[:space:]]${hn_esc}\([[:space:]]\|$\)/ /g" /etc/hosts
    sed -i "/^127\./!{/[[:space:]]${fqdn_esc}\([[:space:]]\|$\)/d}" /etc/hosts
    sed -i '/^[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}[[:space:]]*$/d' /etc/hosts

    echo "$new_ip    $fqdn $hostname" >> /etc/hosts
    log_ok "/etc/hosts updated."
}

apply_product_specific_config() {
    local new_ip="$1" product="$2"
    [ "$UPDATE_PRODUCT_CONFIG" != "true" ] && return

    if [ "$product" = "PVE" ] && [ -f /etc/pve/corosync.conf ]; then
        log_warn "PVE CLUSTER DETECTED: /etc/pve/corosync.conf exists."
        log_warn "If the cluster communication IP changed, manually update"
        log_warn "ring0_addr in /etc/pve/corosync.conf to: $new_ip"
    fi
}

# =============================================================================
# INSTALL MODE
# =============================================================================

write_service_file() {
    log_info "Writing systemd service file: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=DHCP-to-Static IP Configurator (PVE/PBS/PMG)
After=network.target
Before=network-online.target
ConditionVirtualization=!container

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --run
TimeoutStartSec=300s
RemainAfterExit=yes
Restart=no
User=root
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
    chmod 644 "$SERVICE_FILE"
    log_ok "Service file written."
}

save_script_copy() {
    local dest="$1"
    local label="$2"

    log_info "Saving script to $dest ($label)..."

    # Write the already-downloaded script content held in SCRIPT_CONTENT
    if [ -n "$SCRIPT_CONTENT" ]; then
        printf '%s\n' "$SCRIPT_CONTENT" > "$dest"
        chmod +x "$dest"
        log_ok "Saved -> $dest"
        return 0
    fi

    log_error "Could not save script to $dest — SCRIPT_CONTENT is empty."
    log_error "Please manually copy the script to: $dest"
    return 1
}

do_install() {
    echo ""
    echo "========================================================"
    echo "  dhcp-to-static.sh v${SCRIPT_VERSION} — INSTALLER"
    echo "========================================================"
    echo ""

    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Must be run as root (try: sudo bash -c \"\$(curl ...)\")"
        exit 1
    fi

    local product
    product=$(detect_proxmox_product)

    echo "  Proxmox product  : $product"
    echo "  Install path     : $INSTALL_PATH"
    echo "  Offline copy     : $OFFLINE_COPY_PATH"
    echo "  Service file     : $SERVICE_FILE"
    echo "  Log file         : $LOG_FILE"
    echo "  INITIAL_WAIT     : ${INITIAL_WAIT}s"
    echo "  RETRY_INTERVAL   : ${RETRY_INTERVAL}s"
    echo "  MAX_RETRY        : ${MAX_RETRY_DURATION}s"
    echo ""

    read -r -p "Proceed with installation? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi

    echo ""
    touch "$LOG_FILE"
    rotate_log

    log_info "========================================================"
    log_info "INSTALLATION STARTED — dhcp-to-static.sh v${SCRIPT_VERSION}"
    log_info "========================================================"

    # Download the script content ONCE from GitHub and hold it in memory.
    # Both paths are written from this same content — one network call,
    # guaranteed identical copies, no risk of partial failure.
    # NOTE: SCRIPT_CONTENT is intentionally a global variable so that
    # save_script_copy() can access it without it being passed as an argument.
    log_info "Downloading script from: $GITHUB_URL"
    SCRIPT_CONTENT=$(curl -fsSL "$GITHUB_URL" 2>>"$LOG_FILE")
    if [ -z "$SCRIPT_CONTENT" ]; then
        log_error "Download failed. Check your internet connection and the URL."
        echo ""
        echo "ERROR: Could not download script from GitHub. Installation aborted."
        exit 1
    fi
    log_ok "Downloaded successfully (${#SCRIPT_CONTENT} bytes)."

    # Save to systemd install path
    save_script_copy "$INSTALL_PATH" "systemd path"

    # Save offline copy to /root
    save_script_copy "$OFFLINE_COPY_PATH" "offline /root copy"

    # Write the embedded service file
    write_service_file

    # Enable the service
    log_info "Enabling systemd service..."
    systemctl daemon-reload              >> "$LOG_FILE" 2>&1
    systemctl enable dhcp-to-static      >> "$LOG_FILE" 2>&1
    log_ok "Service enabled — will run on every reboot."

    # Offer to run immediately
    echo ""
    read -r -p "Run the DHCP-to-static configuration right now? [y/N] " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
        echo ""
        log_info "Starting service now..."
        systemctl start dhcp-to-static
        echo ""
        systemctl status dhcp-to-static --no-pager
    fi

    echo ""
    echo "========================================================"
    echo "  Installation complete!"
    echo ""
    echo "  Script (systemd) : $INSTALL_PATH"
    echo "  Offline copy     : $OFFLINE_COPY_PATH"
    echo "  Service          : dhcp-to-static  [enabled]"
    echo "  Log              : $LOG_FILE"
    echo ""
    echo "  The script runs automatically on every reboot."
    echo "  Move to a new network, reboot — done."
    echo ""
    echo "  Useful commands:"
    echo "    systemctl status dhcp-to-static"
    echo "    journalctl -u dhcp-to-static"
    echo "    cat $LOG_FILE"
    echo "    $INSTALL_PATH --run        # trigger manually"
    echo "    $INSTALL_PATH --uninstall  # remove everything"
    echo "========================================================"
    echo ""
}

# =============================================================================
# UNINSTALL MODE
# =============================================================================

do_uninstall() {
    echo ""
    echo "========================================================"
    echo "  dhcp-to-static.sh — UNINSTALLER"
    echo "========================================================"
    echo ""

    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Must be run as root."
        exit 1
    fi

    read -r -p "Remove dhcp-to-static service and all installed files? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi

    echo ""
    echo "Stopping and disabling service..."
    systemctl stop    dhcp-to-static 2>/dev/null
    systemctl disable dhcp-to-static 2>/dev/null

    echo "Removing service file: $SERVICE_FILE"
    rm -f "$SERVICE_FILE"

    echo "Removing installed script: $INSTALL_PATH"
    rm -f "$INSTALL_PATH"

    echo "Removing offline copy: $OFFLINE_COPY_PATH"
    rm -f "$OFFLINE_COPY_PATH"

    systemctl daemon-reload

    echo ""
    echo "  Uninstall complete."
    echo "  Note: /etc/network/interfaces and /etc/hosts were NOT modified."
    echo "  Your current static IP config remains active."
    echo "  Timestamped backups remain in /etc/network/ and /etc/."
    echo "========================================================"
    echo ""
}

# =============================================================================
# RUN MODE — executed by systemd on every reboot
# =============================================================================

do_run() {
    # Ensure log file exists before any log calls
    touch "$LOG_FILE" 2>/dev/null || true
    rotate_log

    log_info "========================================================"
    log_info "dhcp-to-static.sh v${SCRIPT_VERSION} — RUN MODE (systemd)"
    log_info "========================================================"

    if [ "$(id -u)" -ne 0 ]; then
        log_error "Must be run as root. Exiting."
        exit 1
    fi

    for tool in dhclient ip awk grep sed; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Required tool '$tool' not found. Exiting."
            exit 1
        fi
    done

    local product iface
    product=$(detect_proxmox_product)
    log_info "Proxmox product: $product"

    iface=$(resolve_interface "$product")
    if [ -z "$iface" ]; then
        log_error "Could not determine a valid network interface. Exiting."
        exit 1
    fi
    log_info "Target interface: $iface"
    log_info "Settings: INITIAL_WAIT=${INITIAL_WAIT}s | RETRY_INTERVAL=${RETRY_INTERVAL}s | MAX_RETRY_DURATION=${MAX_RETRY_DURATION}s"

    # Wait for hardware to settle
    log_info "Waiting ${INITIAL_WAIT}s for NICs/bridges to initialize..."
    sleep "$INITIAL_WAIT"

    prepare_interface_for_dhcp "$iface"
    release_existing_lease "$iface"

    # ---- Retry loop ---------------------------------------------------------
    local elapsed=0
    local lease_result=""
    local loop_start
    loop_start=$(date +%s)

    while true; do
        # Check total elapsed wall-clock time before each attempt
        local now
        now=$(date +%s)
        elapsed=$((now - loop_start))

        if [ "$elapsed" -ge "$MAX_RETRY_DURATION" ]; then
            log_warn "Max retry duration of ${MAX_RETRY_DURATION}s reached."
            break
        fi

        lease_result=$(get_dhcp_lease "$iface")

        if [ -n "$lease_result" ]; then
            now=$(date +%s)
            elapsed=$((now - loop_start))
            log_ok "Lease acquired after ${elapsed}s total."
            break
        fi

        now=$(date +%s)
        elapsed=$((now - loop_start))
        local remaining=$((MAX_RETRY_DURATION - elapsed))

        if [ "$remaining" -le 0 ]; then
            log_warn "Max retry duration of ${MAX_RETRY_DURATION}s reached."
            break
        fi

        local wait_time=$RETRY_INTERVAL
        if [ "$remaining" -lt "$RETRY_INTERVAL" ]; then
            wait_time=$remaining
        fi

        log_warn "Retry in ${wait_time}s... (${elapsed}s elapsed, ${remaining}s remaining)"
        sleep "$wait_time"
    done

    if [ -z "$lease_result" ]; then
        log_error "No DHCP lease obtained after ${MAX_RETRY_DURATION}s."
        log_error "Network configuration has NOT been changed."
        exit 1
    fi

    local new_ip new_gw new_prefix
    new_ip=$(    echo "$lease_result" | awk '{print $1}')
    new_gw=$(    echo "$lease_result" | awk '{print $2}')
    new_prefix=$(echo "$lease_result" | awk '{print $3}')

    apply_static_network_config "$iface" "$new_ip" "$new_gw" "$new_prefix" "$product"
    apply_ip_live               "$iface" "$new_ip" "$new_gw" "$new_prefix"

    [ "$UPDATE_HOSTS" = "true" ] && update_hosts_file "$new_ip"

    apply_product_specific_config "$new_ip" "$product"

    log_ok "========================================================"
    log_ok "Complete. Product=$product | Interface=$iface"
    log_ok "         IP=$new_ip/$new_prefix | GW=$new_gw"
    log_ok "========================================================"
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

case "${1:-}" in
    --run)
        # Called by systemd on reboot, or triggered manually
        do_run
        ;;
    --uninstall)
        do_uninstall
        ;;
    --help|-h)
        echo ""
        echo "dhcp-to-static.sh v${SCRIPT_VERSION}"
        echo ""
        echo "Usage:"
        echo "  Install:   bash -c \"\$(curl -fsSL $GITHUB_URL)\""
        echo "  Run:       $INSTALL_PATH --run"
        echo "  Uninstall: $INSTALL_PATH --uninstall"
        echo "  Help:      $INSTALL_PATH --help"
        echo ""
        ;;
    *)
        # No argument = curl invocation = install mode
        do_install
        ;;
esac
