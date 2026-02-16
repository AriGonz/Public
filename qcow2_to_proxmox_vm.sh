#!/bin/bash

# Script Name: import_qcow2_to_proxmox.sh
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/qcow2_to_proxmox_vm.sh)"

# Description: Interactive Bash script to import a QCOW2 disk image into a Proxmox VE node.
#              Creates a new VM, imports the disk, and configures basic settings.
# Author: Grok AI (generated)
# Version: 1.1
# Requirements: Must run as root. Uses whiptail for dialogs (installs if missing).
# Notes: This script is idempotent where possible (e.g., checks for existing VM ID).
#        It handles errors gracefully and prompts for confirmation before actions.
#        Scans /var/lib/vz/template/qcow/ for QCOW2 files and offers selection or manual entry.

# Exit immediately if a command exits with a non-zero status
set -e

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root." >&2
        exit 1
    fi
}

# Function to install whiptail if not present
install_whiptail() {
    if ! command -v whiptail &> /dev/null; then
        echo "whiptail not found. Installing..."
        apt update -y
        apt install -y whiptail
    fi
}

# Function to get user input via whiptail
get_input() {
    local prompt="$1"
    local default="$2"
    local input
    input=$(whiptail --inputbox "$prompt" 8 78 "$default" --title "Input Required" 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus = 0 ]; then
        echo "$input"
    else
        echo "User cancelled. Exiting." >&2
        exit 0
    fi
}

# Function to display menu and get selection
get_menu_selection() {
    local title="$1"
    local prompt="$2"
    shift 2
    local options=("$@")
    local selection
    selection=$(whiptail --title "$title" --menu "$prompt" 15 60 6 "${options[@]}" 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus = 0 ]; then
        echo "$selection"
    else
        echo "User cancelled. Exiting." >&2
        exit 0
    fi
}

# Function to confirm inputs
confirm_inputs() {
    local summary="$1"
    if whiptail --title "Confirmation" --yesno "$summary\n\nProceed with VM creation?" 20 78; then
        return 0
    else
        echo "Operation cancelled by user." >&2
        exit 0
    fi
}

# Function to get available storages dynamically
get_available_storages() {
    local storages=()
    while IFS= read -r line; do
        if [[ $line =~ ^([a-zA-Z0-9_-]+)\ +([a-zA-Z0-9_-]+)\ +([0-9]+)\ +([0-9.]+)\ +([0-9.]+)\ +([0-9.]+%)\ +active ]]; then
            storages+=("${BASH_REMATCH[1]}" "${BASH_REMATCH[1]} (Type: ${BASH_REMATCH[2]}, Free: ${BASH_REMATCH[4]})")
        fi
    done < <(pvesm status | tail -n +2)
    echo "${storages[@]}"
}

# Function to get QCOW2 files from default directory
get_qcow2_files() {
    local dir="/var/lib/vz/template/qcow/"
    local files=()
    if [[ -d "$dir" ]]; then
        while IFS= read -r -d '' file; do
            files+=("$(basename "$file")" "$(basename "$file")")
        done < <(find "$dir" -maxdepth 1 -type f -name "*.qcow2" -print0)
    fi
    if [ ${#files[@]} -eq 0 ]; then
        whiptail --title "Info" --msgbox "No QCOW2 files found in $dir. Proceeding to manual entry." 8 78
        echo ""
    else
        files+=("manual" "Other (manual entry)")
        echo "${files[@]}"
    fi
}

# Main script execution
main() {
    check_root
    install_whiptail

    # Define variables with defaults where applicable
    local qcow2_path
    local vm_name
    local vm_id
    local os_type
    local target_storage
    local memory_mb="2048"  # Default suggestion
    local cpu_cores="2"     # Default suggestion

    # Prompt for QCOW2 selection
    local qcow_options
    qcow_options=($(get_qcow2_files))
    if [ ${#qcow_options[@]} -gt 0 ]; then
        local selected_file
        selected_file=$(get_menu_selection "QCOW2 File Selection" "Select a QCOW2 file or manual entry:" "${qcow_options[@]}")
        if [[ "$selected_file" == "manual" ]]; then
            qcow2_path=$(get_input "Enter the full path to the QCOW2 file:" "")
        else
            qcow2_path="/var/lib/vz/template/qcow/$selected_file"
        fi
    else
        qcow2_path=$(get_input "Enter the full path to the QCOW2 file:" "")
    fi

    # Validate the path exists
    if [[ ! -f "$qcow2_path" ]]; then
        whiptail --title "Error" --msgbox "File not found: $qcow2_path. Please check the path." 8 78
        exit 1
    fi

    # Prompt for other inputs
    vm_name=$(get_input "Enter the VM name:" "")
    vm_id=$(get_input "Enter a unique VM ID (integer):" "")

    # Check if VM ID already exists (idempotency)
    if qm list | grep -q "\b${vm_id}\b"; then
        whiptail --title "Error" --msgbox "VM ID ${vm_id} already exists. Please choose a different ID." 8 78
        exit 1
    fi

    # OS type menu
    local os_options=(
        "win10" "Windows 10/11"
        "win8" "Windows 8/2012/2012r2"
        "win7" "Windows 7/2008r2"
        "wxp" "Windows XP/2003/2008"
        "l26" "Linux 2.6 - 6.X"
        "solaris" "Solaris/OpenSolaris/OpenIndiana"
        "other" "Other OS types"
    )
    os_type=$(get_menu_selection "Guest OS Type" "Select the guest OS type:" "${os_options[@]}")

    # Target storage menu (dynamic)
    local storage_options
    storage_options=($(get_available_storages))
    if [ ${#storage_options[@]} -eq 0 ]; then
        whiptail --title "Error" --msgbox "No available storages found. Check 'pvesm status'." 8 78
        exit 1
    fi
    target_storage=$(get_menu_selection "Target Storage" "Select the target storage:" "${storage_options[@]}")

    # Memory and CPU
    memory_mb=$(get_input "Enter memory allocation in MB:" "$memory_mb")
    cpu_cores=$(get_input "Enter number of CPU cores:" "$cpu_cores")

    # Confirmation summary
    local summary="QCOW2 Path: $qcow2_path\nVM Name: $vm_name\nVM ID: $vm_id\nOS Type: $os_type\nTarget Storage: $target_storage\nMemory: $memory_mb MB\nCPU Cores: $cpu_cores"
    confirm_inputs "$summary"

    # Create the VM
    echo "Creating VM..."
    qm create "$vm_id" --name "$vm_name" --ostype "$os_type" --memory "$memory_mb" --cores "$cpu_cores" \
        --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci || { echo "Failed to create VM." >&2; exit 1; }

    # Import the disk
    echo "Importing disk..."
    local imported_disk="unused0"  # Default after import
    qm importdisk "$vm_id" "$qcow2_path" "$target_storage" -format qcow2 || { echo "Failed to import disk." >&2; qm destroy "$vm_id"; exit 1; }

    # Attach the imported disk as scsi0
    echo "Attaching disk..."
    qm set "$vm_id" --scsi0 "${target_storage}:vm-${vm_id}-disk-0" || { echo "Failed to attach disk." >&2; qm destroy "$vm_id"; exit 1; }

    # Set boot order to prioritize the disk
    echo "Setting boot order..."
    qm set "$vm_id" --boot "order=scsi0" || { echo "Failed to set boot order." >&2; qm destroy "$vm_id"; exit 1; }

    # Clean up unused disk reference if any
    qm set "$vm_id" --delete unused0 >/dev/null 2>&1 || true

    # Success message
    whiptail --title "Success" --msgbox "VM created successfully!\n\nTo start the VM, run:\nqm start $vm_id\n\nOr use the Proxmox web interface." 12 78
}

# Run main function
main
