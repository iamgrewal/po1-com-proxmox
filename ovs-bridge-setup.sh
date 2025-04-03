#!/bin/bash
# Proxmox VE OVS Network Configuration Generator
# This script configures Open vSwitch networking for Proxmox VE
# It creates the /etc/network/interfaces file with proper OVS configuration
# Includes logging and rollback mechanisms

# Set up logging
LOG_DIR="/var/log/ovs-setup"
LOG_FILE="$LOG_DIR/ovs-setup-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/etc/network/interfaces.d/backups"
BACKUP_FILE="$BACKUP_DIR/interfaces-$(date +%Y%m%d-%H%M%S).bak"
INTERFACES_FILE="/etc/network/interfaces"
TEMP_INTERFACES_FILE="/tmp/interfaces.new"

# Create log and backup directories if they don't exist
mkdir -p "$LOG_DIR" "$BACKUP_DIR"

# Log function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handling function
handle_error() {
    local error_message="$1"
    log "ERROR" "$error_message"
    echo -e "\n[ERROR] $error_message"
    
    # Ask if user wants to rollback
    if [[ -f "$BACKUP_FILE" ]]; then
        read -r -p "Do you want to restore the previous network configuration? [Y/n]: " ROLLBACK
        ROLLBACK="${ROLLBACK,,}"
        if [[ "$ROLLBACK" != "n" && "$ROLLBACK" != "no" ]]; then
            log "INFO" "Rolling back to previous configuration: $BACKUP_FILE"
            if cp "$BACKUP_FILE" "$INTERFACES_FILE"; then
                log "SUCCESS" "Rollback successful"
                echo "[SUCCESS] Rollback successful. Previous configuration restored."
            else
                log "ERROR" "Rollback failed"
                echo "[ERROR] Rollback failed. Manual intervention required."
                echo "Previous configuration is available at: $BACKUP_FILE"
            fi
        else
            log "INFO" "User declined rollback"
            echo "Previous configuration is available at: $BACKUP_FILE"
        fi
    fi
    
    exit 1
}

# Validates IPv4 format
is_valid_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$ ]]; then
        return 1
    fi
    
    local IFS=.
    local -a parts=("$ip")
    for octet in "${parts[@]}"; do
        [[ "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
        [[ "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
    done
    return 0
}

# Check if interface exists
interface_exists() { 
    ip link show "$1" >/dev/null 2>&1 
}

# Validate interface
validate_interface() {
    local interface="$1"
    if [[ -z "$interface" ]]; then
        handle_error "Interface name cannot be empty"
    fi
    
    if ! interface_exists "$interface"; then
        echo "[WARNING] Interface $interface does not appear to exist"
        read -r -p "Continue anyway? [y/N]: " CONTINUE
        CONTINUE="${CONTINUE,,}"
        if [[ "$CONTINUE" != "y" && "$CONTINUE" != "yes" ]]; then
            handle_error "Invalid interface: $interface"
        else
            log "WARNING" "User chose to continue with non-existent interface: $interface"
        fi
    fi
    return 0
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        handle_error "This script must be run as root"
    fi
    
    # Check if Open vSwitch is installed
    if ! command -v ovs-vsctl >/dev/null 2>&1; then
        handle_error "Open vSwitch is not installed. Please install it first with: apt-get install openvswitch-switch"
    fi
    
    # Check if interfaces file exists
    if [[ ! -f "$INTERFACES_FILE" ]]; then
        handle_error "/etc/network/interfaces not found"
    fi
    
    # Check write permissions
    if [[ ! -w /etc/network/ ]]; then
        handle_error "No write permissions to /etc/network/"
    fi
    
    log "INFO" "All prerequisites met"
}

# Create backup of current interfaces file
create_backup() {
    log "INFO" "Creating backup of current interfaces file"
    
    if cp "$INTERFACES_FILE" "$BACKUP_FILE"; then
        log "SUCCESS" "Backup created at $BACKUP_FILE"
        echo "[INFO] Backup saved to $BACKUP_FILE"
    else
        handle_error "Failed to create backup. Ensure sufficient permissions and disk space."
    fi
}

# Main function
main() {
    echo "=== Proxmox VE OVS Network Configuration Generator ==="
    log "INFO" "Starting OVS Network Configuration Generator"
    
    # Check prerequisites
    check_prerequisites
    
    # Create backup
    create_backup
    
    # Show interfaces
    echo -e "\nDetected interfaces:"
    ip -br link show | grep -v "lo" | awk '{print "- " $1}'
    echo
    
    # Node name
    while true; do
        read -r -p "Enter node name (e.g., pve1, only alphanumeric and dashes allowed): " NODE_NAME
        if [[ ! "$NODE_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
            echo "[ERROR] Node name can only contain alphanumeric characters and dashes."
            continue
        fi
        [[ -n "$NODE_NAME" ]] && break || echo "[ERROR] Cannot be empty."
    done
    log "INFO" "Node name set to: $NODE_NAME"
    
    # Subnet confirmation
    echo "Default subnets:"
    echo "  VLAN1  ➜  192.168.51.0/24 (Management)"
    echo "  VLAN50 ➜  10.50.10.0/24 (Cluster)"
    echo "  VLAN55 ➜  10.55.10.0/24 (Ceph)"
    read -r -p "Use these subnets? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM,,}"
    
    if [[ "$CONFIRM" != "n" && "$CONFIRM" != "no" ]]; then
        MGMT_PREFIX="192.168.51"
        CLUSTER_PREFIX="10.50.10"
        CEPH_PREFIX="10.55.10"
        log "INFO" "Using default subnets"
    else
        log "INFO" "User chose custom subnets"
        # Management subnet
        while true; do
            read -r -p "Enter Management subnet prefix (e.g., 192.168.51): " MGMT_PREFIX
            if [[ -z "$MGMT_PREFIX" ]]; then
                echo "[ERROR] Subnet prefix cannot be empty."
                continue
            fi
            if is_valid_ip "$MGMT_PREFIX.1"; then
                break
            else
                echo "[ERROR] Invalid subnet prefix. Please enter a valid IPv4 prefix."
            fi
        done
        
        # Cluster subnet
        while true; do
            read -r -p "Enter Cluster subnet prefix (e.g., 10.50.10): " CLUSTER_PREFIX
            if [[ -z "$CLUSTER_PREFIX" ]]; then
                echo "[ERROR] Subnet prefix cannot be empty."
                continue
            fi
            if is_valid_ip "$CLUSTER_PREFIX.1"; then
                break
            else
                echo "[ERROR] Invalid subnet prefix. Please enter a valid IPv4 prefix."
            fi
        done
        
        # Ceph subnet
        while true; do
            read -r -p "Enter Ceph subnet prefix (e.g., 10.55.10): " CEPH_PREFIX
            if [[ -z "$CEPH_PREFIX" ]]; then
                echo "[ERROR] Subnet prefix cannot be empty."
                continue
            fi
            if is_valid_ip "$CEPH_PREFIX.1"; then
                break
            else
                echo "[ERROR] Invalid subnet prefix. Please enter a valid IPv4 prefix."
            fi
        done
    fi
    
    # IP inputs
    while true; do 
        read -r -p "Last octet for Management IP (e.g., 200): " MGMT_OCT
        if [[ -z "$MGMT_OCT" ]]; then
            echo "[ERROR] IP octet cannot be empty."
            continue
        fi
        if is_valid_ip "$MGMT_PREFIX.$MGMT_OCT"; then
            break
        else
            echo "[ERROR] Invalid IP octet. Please enter a number between 1 and 254."
        fi
    done
    MGMT_IP="$MGMT_PREFIX.$MGMT_OCT"
    MGMT_NETMASK="255.255.255.0"
    MGMT_GW="$MGMT_PREFIX.1"
    log "INFO" "Management IP set to: $MGMT_IP"
    
    while true; do 
        read -r -p "Last octet for Cluster IP (e.g., 11): " CLUSTER_OCT
        if [[ -z "$CLUSTER_OCT" ]]; then
            echo "[ERROR] IP octet cannot be empty."
            continue
        fi
        if is_valid_ip "$CLUSTER_PREFIX.$CLUSTER_OCT"; then
            break
        else
            echo "[ERROR] Invalid IP octet. Please enter a number between 1 and 254."
        fi
    done
    CLUSTER_IP="$CLUSTER_PREFIX.$CLUSTER_OCT"
    CLUSTER_NETMASK="255.255.255.0"
    log "INFO" "Cluster IP set to: $CLUSTER_IP"
    
    while true; do 
        read -r -p "Last octet for Ceph IP (e.g., 21): " CEPH_OCT
        if [[ -z "$CEPH_OCT" ]]; then
            echo "[ERROR] IP octet cannot be empty."
            continue
        fi
        if is_valid_ip "$CEPH_PREFIX.$CEPH_OCT"; then
            break
        else
            echo "[ERROR] Invalid IP octet. Please enter a number between 1 and 254."
        fi
    done
    CEPH_IP="$CEPH_PREFIX.$CEPH_OCT"
    CEPH_NETMASK="255.255.255.0"
    log "INFO" "Ceph IP set to: $CEPH_IP"
    
    # Network adapter selection
    echo -e "\nSelect network adapters for your configuration:"
    
    # First NIC for bond
    while true; do
        read -r -p "First NIC for bond (e.g., enp6s6f0): " ADAPTER1
        if validate_interface "$ADAPTER1"; then
            break
        fi
    done
    log "INFO" "First bond NIC set to: $ADAPTER1"
    
    # Second NIC for bond
    while true; do
        read -r -p "Second NIC for bond (e.g., enp6s6f1): " ADAPTER2
        if [[ "$ADAPTER2" == "$ADAPTER1" ]]; then
            echo "[ERROR] Second NIC cannot be the same as the first NIC."
            continue
        fi
        if validate_interface "$ADAPTER2"; then
            break
        fi
    done
    log "INFO" "Second bond NIC set to: $ADAPTER2"
    
    # NIC for Ceph/Cluster
    while true; do
        read -r -p "NIC for Ceph/Cluster (e.g., enp6s5): " ADAPTER3
        if [[ "$ADAPTER3" == "$ADAPTER1" || "$ADAPTER3" == "$ADAPTER2" ]]; then
            echo "[ERROR] Ceph/Cluster NIC cannot be the same as bond NICs."
            continue
        fi
        if validate_interface "$ADAPTER3"; then
            break
        fi
    done
    log "INFO" "Ceph/Cluster NIC set to: $ADAPTER3"
    
    # DNS server
    read -r -p "DNS server IP (default: $MGMT_GW): " DNS_SERVER
    if [[ -z "$DNS_SERVER" ]]; then
        DNS_SERVER="$MGMT_GW"
    elif ! is_valid_ip "$DNS_SERVER"; then
        echo "[WARNING] Invalid DNS server IP. Using default: $MGMT_GW"
        DNS_SERVER="$MGMT_GW"
    fi
    log "INFO" "DNS server set to: $DNS_SERVER"
    
    # MTU size
    read -r -p "MTU size (default: 9000): " MTU_SIZE
    if [[ -z "$MTU_SIZE" ]]; then
        MTU_SIZE="9000"
    elif ! [[ "$MTU_SIZE" =~ ^[0-9]+$ ]] || [[ "$MTU_SIZE" -lt 1500 || "$MTU_SIZE" -gt 9000 ]]; then
        echo "[WARNING] Invalid MTU size. Using default: 9000"
        MTU_SIZE="9000"
    fi
    log "INFO" "MTU size set to: $MTU_SIZE"
    
    # Generate interfaces file
    log "INFO" "Generating new interfaces file"
    
    cat <<EOF > "$TEMP_INTERFACES_FILE"
# Network configuration for Proxmox VE node: $NODE_NAME
# Generated by OVS Network Configuration Generator on $(date)
# DO NOT EDIT THIS FILE MANUALLY

auto lo
iface lo inet loopback

# Bond NICs
auto $ADAPTER1
iface $ADAPTER1 inet manual
    ovs_type OVSPort
    ovs_bridge vmbr0
    ovs_mtu $MTU_SIZE

auto $ADAPTER2
iface $ADAPTER2 inet manual
    ovs_type OVSPort
    ovs_bridge vmbr0
    ovs_mtu $MTU_SIZE

# Bond configuration
auto bond0
iface bond0 inet manual
    ovs_type OVSBond
    ovs_bridge vmbr0
    ovs_bonds $ADAPTER1 $ADAPTER2
    ovs_options bond_mode=balance-tcp lacp=active other_config:lacp-time=fast
    ovs_mtu $MTU_SIZE

# Management bridge
auto vmbr0
iface vmbr0 inet manual
    ovs_type OVSBridge
    ovs_ports bond0 vlan1
    ovs_mtu $MTU_SIZE
    up ovs-vsctl set Bridge \$IFACE rstp_enable=true

# Management VLAN
auto vlan1
iface vlan1 inet static
    address $MGMT_IP
    netmask $MGMT_NETMASK
    gateway $MGMT_GW
    ovs_type OVSIntPort
    ovs_bridge vmbr0
    ovs_options tag=1 vlan_mode=access
    dns-nameservers $DNS_SERVER
    metric 10

# Cluster/Ceph NIC
auto $ADAPTER3
iface $ADAPTER3 inet manual
    ovs_type OVSPort
    ovs_bridge vmbr1
    ovs_mtu $MTU_SIZE

# Cluster/Ceph bridge
auto vmbr1
iface vmbr1 inet manual
    ovs_type OVSBridge
    ovs_ports $ADAPTER3 vlan50 vlan55
    ovs_mtu $MTU_SIZE
    up ovs-vsctl set Bridge \$IFACE rstp_enable=true

# Cluster VLAN
auto vlan50
iface vlan50 inet static
    address $CLUSTER_IP
    netmask $CLUSTER_NETMASK
    ovs_type OVSIntPort
    ovs_bridge vmbr1
    ovs_options tag=50
    dns-nameservers $DNS_SERVER
    ovs_mtu $MTU_SIZE

# Ceph VLAN
auto vlan55
iface vlan55 inet static
    address $CEPH_IP
    netmask $CEPH_NETMASK
    ovs_type OVSIntPort
    ovs_bridge vmbr1
    ovs_options tag=55
    dns-nameservers $DNS_SERVER
    ovs_mtu $MTU_SIZE
EOF
    
    # Review configuration
    echo -e "\n=== Configuration Review ==="
    echo "Node Name: $NODE_NAME"
    echo "Management IP: $MGMT_IP/24 (Gateway: $MGMT_GW)"
    echo "Cluster IP: $CLUSTER_IP/24"
    echo "Ceph IP: $CEPH_IP/24"
    echo "Bond NICs: $ADAPTER1 + $ADAPTER2"
    echo "Cluster/Ceph NIC: $ADAPTER3"
    echo "DNS Server: $DNS_SERVER"
    echo "MTU Size: $MTU_SIZE"
    
    # Confirm and apply
    read -r -p "Apply this configuration? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM,,}"
    
    if [[ "$CONFIRM" != "n" && "$CONFIRM" != "no" ]]; then
        log "INFO" "Applying new configuration"
        
        if cp "$TEMP_INTERFACES_FILE" "$INTERFACES_FILE"; then
            log "SUCCESS" "Configuration written to $INTERFACES_FILE"
            echo -e "\n[SUCCESS] Configuration written to $INTERFACES_FILE"
            echo "[INFO] A backup of the previous configuration is available at: $BACKUP_FILE"
            echo "[INFO] Logs are available at: $LOG_FILE"
            echo -e "\n[NEXT STEP] Run 'systemctl restart networking' or reboot to apply."
            echo "[WARNING] Restarting networking may cause a temporary loss of connectivity."
            echo "          Ensure you have physical access to the machine or an alternative way to connect."
        else
            handle_error "Failed to write configuration to $INTERFACES_FILE"
        fi
    else
        log "INFO" "User cancelled configuration"
        echo "[INFO] Configuration cancelled. No changes were made."
        echo "[INFO] A backup of the current configuration is available at: $BACKUP_FILE"
        echo "[INFO] The generated configuration is available at: $TEMP_INTERFACES_FILE"
    fi
}

# Run main function
main
