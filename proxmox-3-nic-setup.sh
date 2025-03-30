#!/bin/bash

# Script: convert_to_linux_network.sh
# Purpose: Remove OVS networking and convert to Linux native bridging

# Author: Proxmox Guru Jatinder Grewal https://github.com/iamgrewal
# Use: Choose to apply Linux-style network config interactively
#
# Standard /etc/network/interfaces with:
# bond0 = Linux bonding
# vmbr0 = Management bridge
# vlan50 and vlan55 = Debian-style VLANs
# No more ovs-vsctl or OVS* entries
# Working, testable config for migration/recovery

set -x # Exit immediately if a command exits with a non-zero status.

LOG_FILE="/var/log/network_migration.log"

# --- Logging Functions ---

log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - INFO: $1" >>"$LOG_FILE"
    echo "INFO: $1" # Also print to console
}

log_warning() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - WARNING: $1" >>"$LOG_FILE"
    echo "WARNING: $1" >&2 # Print to stderr
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR: $1" >>"$LOG_FILE"
    echo "ERROR: $1" >&2
}

# --- Helper Functions ---

# Pause for user input
pause() {
    if [[ -z "$1" ]]; then
        log_error "pause: argument is empty"
        return 1
    fi
    read -rp "$1"
}

# Validate IPv4 address
is_valid_ip() {
    local ip="$1"

    # Check for null pointer references
    if [[ -z "$ip" ]]; then
        log_error "is_valid_ip: ip is empty"
        return 1
    fi

    # Check for unhandled exceptions
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS=. read -ra octets <<<"$ip"
        for octet in "${octets[@]}"; do
            if ((octet < 0 || octet > 255)); then
                log_error "is_valid_ip: octet $octet is out of range"
                return 1
            fi
        done
    else
        log_error "is_valid_ip: invalid IP address format"
        return 1
    fi

    return 0
}

# Check if an interface exists
interface_exists() {
    local interface="$1"

    if [[ -z "$interface" ]]; then
        log_error "interface_exists: interface name is empty"
        return 1
    fi

    ip link show "$interface" >/dev/null 2>&1
    return $?
}

# Install packages
install_packages() {
    local packages=("$@")
    local log_file="/var/log/install-packages.log"

    if [[ -z "$packages" ]]; then
        log_error "install_packages: packages is empty"
        return 1
    fi

    mkdir -pv /var/log
    touch "$log_file"
    chmod 644 "$log_file"

    log_info "Installing packages: ${packages[*]}"

    if ! apt-get update -y; then
        log_error "Failed to update package list."
        return 1
    fi
    if ! apt-get install -y "${packages[@]}"; then
        log_error "Failed to install packages."
        return 1
    fi
    apt-get install -f -y || log_warning "Failed to install -f" # Non-critical failure
    apt-get autoremove -y || log_warning "Failed to autoremove" # Non-critical failure
    apt-get autoclean -y || log_warning "Failed to autoclean"   # Non-critical failure

    log_info "Packages installed successfully."
    return 0
}

# Backup interfaces file
backup_interfaces() {
    local filename="interfaces_backup"
    local date_part=$(date "+%Y-%m-%d_%H-%M-%S")
    local backup_dir="/root/network_backups"
    local backup="${backup_dir}/${filename}_${date_part}.bak"

    # Check for null pointer references
    if [[ -z "$filename" ]]; then
        log_error "backup_interfaces: filename is empty"
        return 1
    fi

    if [[ -z "$date_part" ]]; then
        log_error "backup_interfaces: date_part is empty"
        return 1
    fi

    if [[ -z "$backup_dir" ]]; then
        log_error "backup_interfaces: backup_dir is empty"
        return 1
    fi

    if [[ -z "$backup" ]]; then
        log_error "backup_interfaces: backup is empty"
        return 1
    fi

    # Check for unhandled exceptions
    if ! mkdir -p "$backup_dir"; then
        log_error "Failed to create backup directory: $backup_dir"
        return 1
    fi

    if ! cp /etc/network/interfaces "$backup"; then
        log_error "Failed to backup interfaces file to: $backup"
        return 1
    fi

    # Keep only last 5 backups
    ls -t "$backup_dir"/interfaces_backup_*.bak 2>/dev/null | tail -n +6 | xargs rm -f --

    log_info "Backed up current interfaces file to: $backup"
    return 0
}
# Enable IP forwarding persistently
#
# This function enables IP forwarding by setting the required kernel
# parameters and applying the changes persistently.
#
# Parameters:
#   None
#
# Returns:
#   0 on success
#   1 if the IP forwarding is already enabled
configure_ip_forwarding() {
    local sysctl_config_file="/etc/sysctl.conf"
    local ipv4_forwarding_enabled="net.ipv4.ip_forward = 1"
    local ipv6_disabled_all="net.ipv6.conf.all.disable_ipv6 = 1"
    local ipv6_disabled_default="net.ipv6.conf.default.disable_ipv6 = 1"

    # Check for null pointer references
    if [[ -z "$sysctl_config_file" ]]; then
        log_error "sysctl_config_file is not set"
        return 1
    fi

    # Check if the file exists
    if [[ ! -f "$sysctl_config_file" ]]; then
        log_error "$sysctl_config_file does not exist"
        return 1
    fi

    if grep -q "$ipv4_forwarding_enabled" "$sysctl_config_file" &&
        grep -q "$ipv6_disabled_all" "$sysctl_config_file" &&
        grep -q "$ipv6_disabled_default" "$sysctl_config_file"; then
        log_info "IP forwarding already configured."
        return 0
    fi

    local original_permissions
    original_permissions=$(stat -c "%a" "$sysctl_config_file")
    if [[ -z "$original_permissions" ]]; then
        log_error "Failed to obtain original permissions of $sysctl_config_file"
        return 1
    fi

    if [[ "$original_permissions" != "666" ]]; then
        if ! chmod 666 "$sysctl_config_file"; then
            log_error "Failed to change permissions of $sysctl_config_file"
            return 1
        fi
    fi

    if ! printf '%s\n%s\n%s\n' "$ipv4_forwarding_enabled" "$ipv6_disabled_all" "$ipv6_disabled_default" >>"$sysctl_config_file"; then
        log_error "Failed to write to $sysctl_config_file"
        return 1
    fi

    if [[ "$original_permissions" != "666" ]]; then
        if ! chmod "$original_permissions" "$sysctl_config_file"; then
            log_error "Failed to restore original permissions of $sysctl_config_file"
            return 1
        fi
    fi

    if ! sysctl -p "$sysctl_config_file"; then
        log_error "Failed to apply sysctl changes"
        return 1
    fi

    log_info "IP forwarding configuration applied."
    return 0
}
# Restore interfaces from backup
restore_interfaces() {
    local backup_dir="/root/network_backups"
    local backups=()
    local choice

    # Check for null pointer references
    if [[ -z "$backup_dir" ]]; then
        log_error "backup_dir is not set"
        return 1
    fi

    # Check if backup directory exists
    if [ ! -d "$backup_dir" ]; then
        log_error "Backup directory $backup_dir does not exist"
        return 1
    fi

    # Get list of available backups
    backups=($(ls -t "$backup_dir"/interfaces_backup_*.bak 2>/dev/null))

    # Check for null pointer references
    if [[ -z "${backups[@]}" ]]; then
        log_error "No backups found in $backup_dir"
        return 1
    fi

    # Display available backups
    echo "Available backups:"
    for i in "${!backups[@]}"; do
        echo "  $((i + 1))) ${backups[$i]##*/}"
    done

    # Get user selection
    read -p "Select backup to restore [1-${#backups[@]}]: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        log_error "Invalid selection"
        return 1
    fi

    local selected_backup="${backups[$((choice - 1))]}"

    # Check for null pointer references
    if [[ -z "$selected_backup" ]]; then
        log_error "selected_backup is not set"
        return 1
    fi

    # Confirm restore
    read -p "Are you sure you want to restore from $selected_backup? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log_info "Restore cancelled"
        return 0
    fi

    # Perform restore
    if ! cp "$selected_backup" /etc/network/interfaces; then
        log_error "Failed to restore from $selected_backup"
        return 1
    fi

    log_info "Successfully restored from $selected_backup"
    return 0
}

# --- Configuration Functions ---

# Configure loopback
configure_loopback() {
    local interfaces_file="/etc/network/interfaces"

    # Check for null pointer references
    if [[ -z "$interfaces_file" ]]; then
        log_error "interfaces_file is not set"
        return 1
    fi

    # Check if interfaces file is writable
    if [[ ! -w "$interfaces_file" ]]; then
        log_error "No write permissions for $interfaces_file"
        return 1
    fi

    # Append loopback configuration
    if ! cat <<EOF >>"$interfaces_file"; then
auto lo
iface lo inet loopback
EOF
        log_error "Failed to write loopback configuration to $interfaces_file"
        return 1
    fi

    log_info "Loopback interface configured."
    return 0
}

# Configure bonding
configure_bonding() {
    local BOND_IFACE1="$1"
    local BOND_IFACE2="$2"

    # Check for null pointer references
    if [[ -z "$BOND_IFACE1" || -z "$BOND_IFACE2" ]]; then
        log_error "Bond interfaces are not set"
        return 1
    fi

    # Check if interfaces exist
    if ! interface_exists "$BOND_IFACE1" || ! interface_exists "$BOND_IFACE2"; then
        log_error "Interfaces $BOND_IFACE1 or $BOND_IFACE2 do not exist."
        return 1
    fi

    # Check if /etc/network/interfaces is writable
    if [[ ! -w /etc/network/interfaces ]]; then
        log_error "No write permissions for /etc/network/interfaces"
        return 1
    fi

    if ! cat <<EOF >>/etc/network/interfaces; then
auto $BOND_IFACE1
iface $BOND_IFACE1 inet manual
    bond-master bond0

auto $BOND_IFACE2
iface $BOND_IFACE2 inet manual
    bond-master bond0

auto bond0
iface bond0 inet manual
    bond-slaves $BOND_IFACE1 $BOND_IFACE2
    bond-miimon 100
    bond-mode balance-alb
    bond-xmit-hash-policy layer3+4
    offload-rxvlan off
    offload-txvlan off
    offload-tso off
    offload-rx-vlan-filter off
EOF
        log_error "Failed to write bonding configuration to /etc/network/interfaces"
        return 1
    fi

    log_info "Bonding configured with $BOND_IFACE1 and $BOND_IFACE2."
    return 0
}

# Configure bridge interfaces
configure_bridge() {
    local MGMT_IP="$1"
    local MGMT_NETMASK="$2"
    local MGMT_GW="$3"
    local DNS="$4"
    local MGMT_IFACE="$5"

    # Check for null pointer references
    if [[ -z "$MGMT_IP" || -z "$MGMT_NETMASK" || -z "$MGMT_GW" || -z "$DNS" || -z "$MGMT_IFACE" ]]; then
        log_error "One of the required parameters is not set"
        return 1
    fi

    # Check if interfaces exist
    if ! interface_exists "$MGMT_IFACE"; then
        log_error "Interface $MGMT_IFACE does not exist."
        return 1
    fi

    # Check if /etc/network/interfaces is writable
    if [[ ! -w /etc/network/interfaces ]]; then
        log_error "No write permissions for /etc/network/interfaces"
        return 1
    fi

    # Configure bridge interfaces
    if ! cat <<EOF >>/etc/network/interfaces; then
auto vmbr0
iface vmbr0 inet static
    address $MGMT_IP
    netmask $MGMT_NETMASK
    gateway $MGMT_GW
    bridge_ports bond0
    bridge_stp off
    bridge_fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
    dns-nameservers $DNS

auto vmbr1
iface vmbr1 inet manual
    bridge_ports $MGMT_IFACE
    bridge_stp off
    bridge_fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
    dns-nameservers $DNS
EOF
        log_error "Failed to write bridge configuration to /etc/network/interfaces"
        return 1
    fi

    log_info "Bridge interfaces vmbr0 and vmbr1 configured."
    return 0
}

# Configure VLAN interfaces
configure_vlans() {
    local CLUSTER_IP="$1"
    local CEPH_IP="$2"
    local DNS="$3"

    # Check for null pointer references
    if [[ -z "$CLUSTER_IP" || -z "$CEPH_IP" || -z "$DNS" ]]; then
        log_error "One of the required parameters is not set"
        return 1
    fi

    # Check if IP addresses are valid
    if ! is_valid_ip "$CLUSTER_IP" || ! is_valid_ip "$CEPH_IP"; then
        log_error "Invalid cluster or ceph IP address."
        return 1
    fi

    # Check if /etc/network/interfaces is writable
    if [[ ! -w /etc/network/interfaces ]]; then
        log_error "No write permissions for /etc/network/interfaces"
        return 1
    fi

    # Configure VLAN interfaces
    if ! cat <<EOF >>/etc/network/interfaces; then
auto vlan50
iface vlan50 inet static
    address $CLUSTER_IP
    netmask 255.255.255.0
    vlan-raw-device vmbr1
    dns-nameservers $DNS

auto vlan55
iface vlan55 inet static
    address $CEPH_IP
    netmask 255.255.255.0
    vlan-raw-device vmbr1
    dns-nameservers $DNS
EOF
        log_error "Failed to write VLAN configuration to /etc/network/interfaces"
        return 1
    fi

    log_info "VLAN interfaces vlan50 and vlan55 configured."
    return 0
}

# --- Main Configuration Function ---

apply_linux_config() {
    local BOND_IFACE1="$1"
    local BOND_IFACE2="$2"
    local MGMT_IP="$3"
    local MGMT_NETMASK="$4"
    local MGMT_GW="$5"
    local DNS="$6"
    local MGMT_IFACE="$7"
    local CLUSTER_IP="$8"
    local CEPH_IP="$9"

    # Check for null pointer references
    if [[ -z "$BOND_IFACE1" || -z "$BOND_IFACE2" || -z "$MGMT_IP" || -z "$MGMT_NETMASK" || -z "$MGMT_GW" || -z "$DNS" || -z "$MGMT_IFACE" || -z "$CLUSTER_IP" || -z "$CEPH_IP" ]]; then
        log_error "One of the required parameters is not set"
        return 1
    fi

    # Check for unhandled exceptions
    if [[ ! -e /etc/network/interfaces ]]; then
        log_error "Interfaces file does not exist"
        return 1
    fi

    # Install necessary packages
    if ! install_packages ifenslave bridge-utils ethtool iproute2 vlan; then
        log_error "Failed to install required packages. Aborting."
        return 1
    fi

    # Backup existing configuration
    if ! backup_interfaces; then
        log_error "Failed to backup existing network configuration. Aborting."
        return 1
    fi

    # Clear the interfaces file
    >/etc/network/interfaces

    # Configure the network interfaces
    configure_loopback || return 1
    configure_bonding "$BOND_IFACE1" "$BOND_IFACE2" || return 1
    configure_bridge "$MGMT_IP" "$MGMT_NETMASK" "$MGMT_GW" "$DNS" "$MGMT_IFACE" || return 1
    configure_vlans "$CLUSTER_IP" "$CEPH_IP" "$DNS" || return 1

    # Restart networking
    systemctl restart networking
    if [ $? -ne 0 ]; then
        log_error "Failed to restart networking. Check configuration."
        systemctl status networking >>"$LOG_FILE"
        return 1
    fi

    log_info "Network configuration applied and networking restarted."
    return 0
}

# --- Main Script Logic ---

# Check Port Names and Interfaces and IP Addresses
check_interfaces() {
    log_info "Checking interfaces and IP addresses..."

    echo "Detected Interfaces:"
    ip -o link show | awk -F': ' '{print "- " $2}' || log_error "Failed to list interfaces."

    echo "Detected IPs on Interfaces:"
    ip addr show | grep -w inet || {
        log_error "Failed to list IP addresses."
        return 1
    }
    ip addr show | grep -w inet | awk '{ print "- " $2 " on " $NF }' | sed 's:/[0-9]*$::'

    for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
        if [ -z "$iface" ]; then
            log_warning "Empty interface name detected."
            continue
        fi
        if ! interface_exists "$iface"; then
            log_warning "Interface $iface does not exist."
        fi
    done
}

# Change hostname
change_hostname() {
    local CURRENT_HOSTNAME
    local NEW_NODE_NAME

    CURRENT_HOSTNAME=$(hostname)
    if [[ -z "$CURRENT_HOSTNAME" ]]; then
        log_error "Failed to retrieve current hostname."
        return 1
    fi

    read -p "Enter new node name (or leave blank to keep '$CURRENT_HOSTNAME'): " NEW_NODE_NAME
    if [[ -z "$NEW_NODE_NAME" ]]; then
        log_info "Node name remains as $CURRENT_HOSTNAME"
        return 0
    fi

    if [[ "$NEW_NODE_NAME" != "$CURRENT_HOSTNAME" ]]; then
        if ! hostnamectl set-hostname "$NEW_NODE_NAME"; then
            log_error "Failed to set new hostname."
            return 1
        fi

        if ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/hosts ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/hostname ||
            ! systemctl restart systemd-hostnamed ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/mailname ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/postfix/main.cf; then
            log_error "Failed to update system files with new hostname."
            return 1
        fi

        if ! find /var/lib/rrdcached/db/pve2-{node,storage} -type d -name "$CURRENT_HOSTNAME" -exec mv {} $(dirname {})/"$NEW_NODE_NAME" \; ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/pve/.membership ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/pve/cluster.conf ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/pve/storage.cfg ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/pve/user.cfg ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/pve/qemu-server/*.conf ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/pve/lxc/*.conf ||
            ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/pve/firewall/*.fw; then
            log_error "Failed to update Proxmox configuration files."
            return 1
        fi

        log_info "Node name changed to $NEW_NODE_NAME"
    else
        log_info "Node name remains as $CURRENT_HOSTNAME"
    fi

    return 0
}

# Get network configuration parameters from the user
get_network_params() {
    local CONFIRM
    local MGMT_PREFIX
    local CLUSTER_PREFIX
    local CEPH_PREFIX
    local MGMT_OCT
    local CLUSTER_OCT
    local CEPH_OCT
    local MGMT_IP
    local CLUSTER_IP
    local CEPH_IP
    local MGMT_NETMASK
    local MGMT_GW
    local DNS
    local MGMT_IFACE
    local BOND_IFACE1
    local BOND_IFACE2

    # Confirm default subnets
    echo "Use default subnets?"
    echo "  VLAN1: 192.168.51.0/24"
    echo "  VLAN50: 10.50.10.0/24"
    echo "  VLAN55: 10.55.10.0/24"
    read -p "[Y/n]: " CONFIRM
    CONFIRM="${CONFIRM,,}" # Convert to lowercase

    if [[ "$CONFIRM" != "n" && "$CONFIRM" != "no" ]]; then
        MGMT_PREFIX="192.168.51"
        CLUSTER_PREFIX="10.50.10"
        CEPH_PREFIX="10.55.10"
    else
        read -p "VLAN1 prefix: " MGMT_PREFIX
        read -p "VLAN50 prefix: " CLUSTER_PREFIX
        read -p "VLAN55 prefix: " CEPH_PREFIX
    fi

    # Validate subnets
    if [[ -z "$MGMT_PREFIX" ]]; then
        log_error "Subnet prefix for VLAN1 is undefined"
        return 1
    fi

    if [[ -z "$CLUSTER_PREFIX" ]]; then
        log_error "Subnet prefix for VLAN50 is undefined"
        return 1
    fi

    if [[ -z "$CEPH_PREFIX" ]]; then
        log_error "Subnet prefix for VLAN55 is undefined"
        return 1
    fi

    if ! is_valid_ip "$MGMT_PREFIX.1"; then
        log_error "Invalid subnet prefix for VLAN1"
        return 1
    fi

    if ! is_valid_ip "$CLUSTER_PREFIX.1"; then
        log_error "Invalid subnet prefix for VLAN50"
        return 1
    fi

    if ! is_valid_ip "$CEPH_PREFIX.1"; then
        log_error "Invalid subnet prefix for VLAN55"
        return 1
    fi

    # Get last octet of IPs
    read -p "Last octet for VLAN1: " MGMT_OCT
    read -p "Last octet for VLAN50: " CLUSTER_OCT
    read -p "Last octet for VLAN55: " CEPH_OCT

    MGMT_IP="$MGMT_PREFIX.$MGMT_OCT"
    CLUSTER_IP="$CLUSTER_PREFIX.$CLUSTER_OCT"
    CEPH_IP="$CEPH_PREFIX.$CEPH_OCT"

    # Validate IP addresses
    if ! is_valid_ip "$MGMT_IP"; then
        log_error "Invalid IP address for VLAN1"
        return 1
    fi

    if ! is_valid_ip "$CLUSTER_IP"; then
        log_error "Invalid IP address for VLAN50"
        return 1
    fi

    if ! is_valid_ip "$CEPH_IP"; then
        log_error "Invalid IP address for VLAN55"
        return 1
    fi

    MGMT_NETMASK="255.255.255.0"
    MGMT_GW="$MGMT_PREFIX.1"
    DNS="192.168.51.1"

    read -p "Management Interface (e.g., bond0, eno1): " MGMT_IFACE
    read -p "First NIC for bond: " BOND_IFACE1
    read -p "Second NIC for bond: " BOND_IFACE2

    # Validate interfaces
    if ! interface_exists "$MGMT_IFACE"; then
        log_error "Management interface $MGMT_IFACE does not exist"
        return 1
    fi

    if ! interface_exists "$BOND_IFACE1"; then
        log_error "First NIC for bond $BOND_IFACE1 does not exist"
        return 1
    fi

    if ! interface_exists "$BOND_IFACE2"; then
        log_error "Second NIC for bond $BOND_IFACE2 does not exist"
        return 1
    fi
}

# --- Main Script Execution ---

# Main Menu
while true; do
    clear
    echo "==============================="
    echo " Proxmox Network Recovery Tool"
    echo "==============================="
    echo " 1) Check Interfaces"
    echo " 2) Apply Linux bridge config"
    echo " 3) Change Hostname"
    echo " 4) Restore from backup"
    echo " 5) Configure IP Forwarding"
    echo " 6) Exit"
    echo
    read -rp "Choose an option [1-6]: " choice

    case "$choice" in
    1)
        check_interfaces
        pause "Press Enter to continue..."
        ;;
    2)
        get_network_params
        if [ $? -ne 0 ]; then
            log_error "Failed to get network parameters. Aborting."
            pause "Press Enter to continue..."
            continue
        fi
        apply_linux_config "$BOND_IFACE1" "$BOND_IFACE2" "$MGMT_IP" "$MGMT_NETMASK" "$MGMT_GW" "$DNS" "$MGMT_IFACE" "$CLUSTER_IP" "$CEPH_IP"
        if [ $? -ne 0 ]; then
            log_error "Failed to apply Linux bridge config. Review logs."
            pause "Press Enter to continue..."
        else
            pause "Press Enter to continue..."
        fi
        ;;
    3)
        change_hostname
        pause "Press Enter to continue..."
        ;;
    4)
        restore_interfaces
        if [ $? -ne 0 ]; then
            log_error "Failed to restore interfaces."
            pause "Press Enter to continue..."
        else
            pause "Press Enter to continue..."
        fi
        ;;
    5)
        configure_ip_forwarding
        if [ $? -ne 0 ]; then
            log_error "Failed to configure IP forwarding."
            pause "Press Enter to continue..."
        else
            pause "Press Enter to continue..."
        fi
        ;;
    6)
        echo "Exiting..."
        exit 0
        ;;
    *) echo "Invalid choice." && sleep 1 ;;
    esac
done

echo "[✔] New Linux-style network config written."

# Restart networking (moved to apply_linux_config)
#echo "[⚙️ ] Restarting networking..."
#systemctl restart networking

# Check status (moved to apply_linux_config)
#sleep 2
#ip a | grep -E 'inet(?!6)'
#ip a | grep inet | grep -v inet6

#Checking Status of the network interfaces (RSTP is irrelevant here)
#set protocols rstp bridge-priority 0
#set protocols rstp forward-delay 4
#set protocols rstp max-age 6
#Inspecting:

echo "[✅] Migration from OVS to Linux networking complete. Please verify the configuration manually to ensure everything is working as expected."
