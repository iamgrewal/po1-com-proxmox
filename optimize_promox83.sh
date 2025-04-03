#!/bin/bash

# Proxmox VE 8.3+ Kernel & Network Optimization Tool
# Author: Proxmox Guru
# Version: 2025.04
# Description: This script optimizes Proxmox VE 8.3+ for better performance and security.
# It includes essential tasks for fresh installs and new nodes, such as removing the subscription nag,
# switching to the no-subscription repository, enabling ifupdown2, tuning system performance,
# installing the QEMU guest agent, setting vm.swappiness, setting ZFS ARC limits,
# enabling NTP or Chrony for time sync, enabling kernel panic auto-reboot, and installing fail2ban.
# It provides safe defaults and aligns with upstream 8.x recommendations.

# Set -euo pipefail: exit immediately if a command exits with a non-zero status,
# or if a pipe fails.  Also prevents errors from being masked.
set -euo pipefail

# Redirect stderr to stdout for better logging
exec 2>&1

# Log file
LOG_FILE="/var/log/proxmox_optimizer.log"

# Script version
SCRIPT_VERSION="2025.04"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Function to log messages
log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to backup a file
backup_file() {
    if [[ -f "$1" ]]; then
        cp -p "$1" "${1}.bak.$(date +'%Y%m%d%H%M%S')"
        log_message "Backed up $1 to ${1}.bak.$(date +'%Y%m%d%H%M%S')"
    else
        log_message "File $1 does not exist, skipping backup."
    fi
}

# Function to restore a file from backup
restore_file() {
    if [[ -f "${1}.bak" ]]; then
        cp -p "${1}.bak" "$1"
        log_message "Restored $1 from ${1}.bak"
    else
        log_message "Backup file ${1}.bak does not exist, cannot restore."
    fi
}

# Function to remove subscription nag
remove_subscription_nag() {
    log_message "Removing subscription nag..."
    backup_file /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    sed -i "s/data.status !== 'Active'/false/" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    systemctl restart pveproxy
    log_message "Subscription nag removed."
    sleep 2
    show_menu
}

# Function to switch to no-subscription repository
switch_to_no_subscription_repo() {
    log_message "Switching to no-subscription repository..."
    backup_file /etc/apt/sources.list.d/pve-enterprise.list
    sed -i "s/^deb/#deb/" /etc/apt/sources.list.d/pve-enterprise.list
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    apt update
    log_message "Switched to no-subscription repository."
    sleep 2
    show_menu
}

# Function to enable ifupdown2
enable_ifupdown2() {
    log_message "Enabling ifupdown2..."
    apt update -y
    apt install -y ifupdown2
    log_message "ifupdown2 enabled."
    sleep 2
    show_menu
}

# Function to install qemu guest agent
install_qemu_guest_agent() {
    log_message "Installing QEMU guest agent..."
    apt update -y
    apt install -y qemu-guest-agent
    systemctl enable qemu-guest-agent --now
    log_message "QEMU guest agent installed."
    sleep 2
    show_menu
}

# Function to set vm.swappiness
set_vm_swappiness() {
    log_message "Setting vm.swappiness=10..."
    backup_file /etc/sysctl.d/99-swappiness.conf
    echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
    sysctl -p /etc/sysctl.d/99-swappiness.conf
    log_message "vm.swappiness set to 10."
    sleep 2
    show_menu
}

# Function to set zfs arc limits
tune_zfs_arc() {
    log_message "Applying ZFS ARC limit..."

    read -rp "Enter desired ARC max (GiB): " arc_gib

    # Validate user input
    if ! [[ "$arc_gib" =~ ^[0-9]+$ ]]; then
        log_message "Invalid input: ARC size must be a number."
        sleep 2
        show_menu
        return
    fi

    arc_bytes=$((arc_gib * 1024 * 1024 * 1024))
    arc_min=$((arc_bytes - 1))

    # Ensure arc_bytes is at least 64 MiB
    if (( arc_bytes < 67108864 )); then
        log_message "Error: ARC max must be at least 64 MiB."
        sleep 2
        show_menu
        return
    fi

    # Backup the original file
    backup_file /etc/modprobe.d/zfs.conf

    cat <<EOF | tee /etc/modprobe.d/zfs.conf
options zfs zfs_arc_min=$arc_min
options zfs zfs_arc_max=$arc_bytes
EOF

    update-initramfs -u -k all
    log_message "ZFS ARC size capped at ${arc_gib} GiB. Reboot required to apply."
    sleep 2
    show_menu
}

# Function to enable ntp or chrony
enable_ntp_or_chrony() {
    log_message "Enabling NTP or Chrony..."
    apt update -y
    apt install -y chrony
    systemctl enable chrony --now
    log_message "NTP or Chrony enabled."
    sleep 2
    show_menu
}

# Function to enable kernel panic auto-reboot
enable_kernel_panic_auto_reboot() {
    log_message "Enabling kernel panic auto-reboot..."
    backup_file /etc/sysctl.d/99-kernelpanic.conf
    cat <<EOF > /etc/sysctl.d/99-kernelpanic.conf
kernel.panic = 10
kernel.panic_on_oops = 1
EOF
    log_message "Kernel panic auto-reboot enabled."
    sleep 2
    show_menu
}

# Function to install fail2ban
install_fail2ban() {
    log_message "Installing fail2ban..."
    apt update -y
    apt install -y fail2ban
    systemctl enable fail2ban --now
    log_message "fail2ban installed."
    sleep 2
    show_menu
}

tune_network() {
    log_message "Applying network optimizations..."

    # Backup the original file
    backup_file /etc/sysctl.d/99-pve-net.conf

    # Ensure /etc/sysctl.d exists
    mkdir -p /etc/sysctl.d

    cat <<EOF | tee /etc/sysctl.d/99-pve-net.conf
# Shorten TCP FIN timeout
net.ipv4.tcp_fin_timeout = 10

# Shorten conntrack timeout in FIN_WAIT
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 5

# Optimize TCP Keepalive to detect dead peers faster
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Increase connection limits
net.core.somaxconn = 262144
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 50000

# Use BBR congestion control and fq queue for latency-sensitive workloads
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_codel

# Expand ephemeral port range
net.ipv4.ip_local_port_range = 10000 59999

# Protect against SYN flood and orphaned sockets
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_orphan_retries = 2

# Disable reuse of TIME_WAIT (for compatibility)
net.ipv4.tcp_tw_reuse = 0

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1

# Increase ARP neighbor table thresholds
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
EOF

    # Apply the settings
    sysctl --system

    # Disable IPv6 persistently
    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
        update-grub
        log_message "Persistent IPv6 disablement added to GRUB."
    fi

    log_message "Network optimizations applied."
    sleep 2
    show_menu
}

tune_memory() {
    log_message "Applying memory tuning..."

    # Backup the original file
    backup_file /etc/sysctl.d/99-pve-mem.conf

    # Ensure /etc/sysctl.d exists
    mkdir -p /etc/sysctl.d

    cat <<EOF | tee /etc/sysctl.d/99-pve-mem.conf
# Use RAM as priority, not swap
vm.swappiness = 10

# Overcommit memory for containers/VMs
vm.overcommit_memory = 1

# Reduce inode/dentry cache reclaim aggressiveness
vm.vfs_cache_pressure = 300

# Flush dirty pages less aggressively to improve SSD lifespan
vm.dirty_writeback_centisecs = 3000
vm.dirty_expire_centisecs = 18000
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF

    # Apply the settings
    sysctl --system

    log_message "Memory tuning applied."
    sleep 2
    show_menu
}

tune_swap() {
    log_message "Applying swap behavior optimization..."

    # Backup the original file
    backup_file /etc/sysctl.d/99-pve-swap.conf

    # Ensure /etc/sysctl.d exists
    mkdir -p /etc/sysctl.d

    cat <<EOF | tee -a /etc/sysctl.d/99-pve-swap.conf
# Avoid swap unless necessary
vm.swappiness = 10
EOF

    # Apply the settings
    sysctl --system

    log_message "Swap behavior optimized."
    sleep 2
    show_menu
}

tune_security() {
    log_message "Applying security hardening..."

    # Backup the original file
    backup_file /etc/sysctl.d/99-pve-sec.conf

    # Ensure /etc/sysctl.d exists
    mkdir -p /etc/sysctl.d

    cat <<EOF | tee /etc/sysctl.d/99-pve-sec.conf
# Harden BPF (prevents privilege escalation)
kernel.unprivileged_bpf_disabled = 1

# Protect against fragmented packet abuse
net.ipv4.ipfrag_high_thresh = 262144
net.ipv4.ipfrag_low_thresh = 196608
net.ipv6.ip6frag_high_thresh = 262144
net.ipv6.ip6frag_low_thresh = 196608

# Enable RFC1337 protection (drops stray RST packets)
net.ipv4.tcp_rfc1337 = 1

# Disable TCP SACK and MTU probing (rarely beneficial, potential CVEs)
net.ipv4.tcp_sack = 0
net.ipv4.tcp_mtu_probing = 0
EOF

    # Apply the settings
    sysctl --system

    log_message "Security hardening applied."
    sleep 2
    show_menu
}

rollback_changes() {
    log_message "Rolling back changes..."

    # Restore backed up files
    restore_file /etc/sysctl.d/99-pve-net.conf
    restore_file /etc/sysctl.d/99-pve-mem.conf
    restore_file /etc/sysctl.d/99-pve-swap.conf
    restore_file /etc/sysctl.d/99-pve-sec.conf
    restore_file /etc/modprobe.d/zfs.conf
    restore_file /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    restore_file /etc/apt/sources.list.d/pve-enterprise.list
    restore_file /etc/sysctl.d/99-swappiness.conf
    restore_file /etc/sysctl.d/99-kernelpanic.conf
    restore_file /etc/default/grub

    # Apply the settings
    sysctl --system

    log_message "Rollback completed. Please reboot to ensure all changes are reverted."
    sleep 2
    show_menu
}

# Function to verify settings after reboot
verify_settings() {
    log_message "Verifying settings after reboot..."

    # Check sysctl values
    sysctl net.ipv4.tcp_fin_timeout
    sysctl vm.swappiness

    # Check if ARC values are loaded
    cat /sys/module/zfs/parameters/zfs_arc_max

    # Check if services are active
    systemctl is-active chrony
    systemctl is-active fail2ban
    systemctl is-active qemu-guest-agent

    log_message "Settings verified."
    sleep 2
    show_menu
}

# Menu-based interactive usage
show_menu() {
    clear
    echo "Proxmox VE Optimization Menu (v$SCRIPT_VERSION)"
    echo "--------------------------------------"
    echo "1. Remove Subscription Nag"
    echo "2. Switch to No-Subscription Repository"
    echo "3. Enable ifupdown2 (Dynamic Networking)"
    echo "4. Install QEMU Guest Agent on VMs"
    echo "5. Set vm.swappiness=10"
    echo "6. Apply ZFS ARC Limit (Interactive)"
    echo "7. Enable NTP or Chrony for Time Sync"
    echo "8. Enable Kernel Panic Auto-Reboot"
    echo "9. Install fail2ban (UI Protection)"
    echo "10. Apply Network Optimizations"
    echo "11. Apply Memory Tuning"
    echo "12. Apply Swap Behavior"
    echo "13. Apply Security Hardening"
    echo "14. Rollback Changes"
    echo "15. Verify Settings After Reboot"
    echo "16. Exit"
    echo
    read -rp "Choose an option: " choice
    case $choice in
        1) remove_subscription_nag ;;
        2) switch_to_no_subscription_repo ;;
        3) enable_ifupdown2 ;;
        4) install_qemu_guest_agent ;;
        5) set_vm_swappiness ;;
        6) tune_zfs_arc ;;
        7) enable_ntp_or_chrony ;;
        8) enable_kernel_panic_auto_reboot ;;
        9) install_fail2ban ;;
        10) tune_network ;;
        11) tune_memory ;;
        12) tune_swap ;;
        13) tune_security ;;
        14) rollback_changes ;;
        15) verify_settings ;;
        16) exit 0 ;;
        *) log_message "Invalid choice."; sleep 2; show_menu ;;
    esac
}

# Handle command-line arguments for non-interactive usage
if [[ $# -gt 0 ]]; then
    case $1 in
        --remove-subscription-nag) remove_subscription_nag ;;
        --switch-to-no-subscription-repo) switch_to_no_subscription_repo ;;
        --enable-ifupdown2) enable_ifupdown2 ;;
        --install-qemu-guest-agent) install_qemu_guest_agent ;;
        --set-vm-swappiness) set_vm_swappiness ;;
        --zfs-arc) tune_zfs_arc ;;
        --enable-ntp-or-chrony) enable_ntp_or_chrony ;;
        --enable-kernel-panic-auto-reboot) enable_kernel_panic_auto_reboot ;;
        --install-fail2ban) install_fail2ban ;;
        --network) tune_network ;;
        --memory) tune_memory ;;
        --swap) tune_swap ;;
        --security) tune_security ;;
        --rollback) rollback_changes ;;
        --verify) verify_settings ;;
        *) echo "Invalid argument. Use --remove-subscription-nag, --switch-to-no-subscription-repo, --enable-ifupdown2, --install-qemu-guest-agent, --set-vm-swappiness, --zfs-arc, --enable-ntp-or-chrony, --enable-kernel-panic-auto-reboot, --install-fail2ban, --network, --memory, --swap, --security, --rollback, or --verify."; exit 1 ;;
    esac
else
    # Start the menu
    show_menu
fi