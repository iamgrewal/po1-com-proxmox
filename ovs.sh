#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Configuration (modify as needed)
readonly GATEWAY='192.168.0.1'
readonly DNS_SERVERS='192.168.0.1'
readonly DOMAIN='po1.me'
readonly VLAN_TAGS=(10 20 30 40)
readonly BOND_MODE='balance-tcp'  # Use LACP (requires switch configuration)

# Logging setup
LOG_FILE="/var/log/proxmox-network-setup.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

check_root() {
    [[ $EUID -ne 0 ]] && log_error "This script must be run as root"
}

validate_octet() {
    local octet
    read -r -p "Enter last octet for mgmt IP (e.g., 231 for 192.168.0.231): " octet
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && (( octet >= 1 && octet <= 254 )) || log_error "Invalid octet"
    readonly OCT="$octet"
}

detect_interfaces() {
    mapfile -t PHYSICAL_NICS < <(find /sys/class/net -mindepth 1 -maxdepth 1 -name 'en*' -exec basename {} \; | sort)
    ((${#PHYSICAL_NICS[@]} >= 2)) || log_error "At least 2 physical interfaces required"
}

select_interfaces() {
    PS3=$'\nSelect management interface (1-'"${#PHYSICAL_NICS[@]}"'): '
    select mgmt_iface in "${PHYSICAL_NICS[@]}"; do
        [[ -n "$mgmt_iface" ]] && break
    done
    
    local remaining=("${PHYSICAL_NICS[@]/$mgmt_iface}")
    PS3=$'\nSelect bond members (space-separated): '
    select -o bond_members in "${remaining[@]}"; do
        ((${#bond_members[@]} >= 1)) && break
    done
    
    readonly MGMT_IFACE="$mgmt_iface"
    readonly BOND_MEMBERS=("${bond_members[@]}")
    readonly VLAN_IFACE="${bond_members[0]}"  # For single NIC VLAN testing
}

calculate_ips() {
    readonly MGMT_IP="192.168.0.${OCT}/24"
    readonly HOSTNAME="pve${OCT}.${DOMAIN}"
    readonly PRETTY_HOST="pve${OCT}"
}

install_dependencies() {
    apt-get update
    apt-get install -y openvswitch-switch ifupdown2
}

configure_host() {
    # Hostname configuration
    hostnamectl set-hostname "$HOSTNAME"
    echo "$HOSTNAME" > /etc/hostname
    
    # /etc/hosts
    printf "%s\t%s %s\n" "127.0.0.1" "localhost" > /etc/hosts
    printf "%s\t%s %s\n" "$MGMT_IP" "$HOSTNAME" "$PRETTY_HOST" >> /etc/hosts
}

backup_config() {
    cp /etc/network/interfaces "/etc/network/interfaces.bak-$(date +%s)"
}

write_network_config() {
    cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

# Management interface
auto $MGMT_IFACE
iface $MGMT_IFACE inet manual

# OVS Bond configuration
auto bond0
iface bond0 inet manual
    ovs_bridge vmbr1
    ovs_type OVSBond
    ovs_bonds ${BOND_MEMBERS[*]}
    ovs_options bond_mode=$BOND_MODE lacp=active trunks=${VLAN_TAGS[*]}

# Main bridge for management
auto vmbr0
iface vmbr0 inet static
    address $MGMT_IP
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
    dns-search $DOMAIN
    bridge-ports $MGMT_IFACE
    bridge-stp off
    bridge-fd 0
    mtu 1500

# OVS Bridge for VLANs
auto vmbr1
iface vmbr1 inet manual
    ovs_type OVSBridge
    ovs_ports bond0
    mtu 9000
EOF

    # VLAN interfaces
    for tag in "${VLAN_TAGS[@]}"; do
        cat >> /etc/network/interfaces <<EOF

# VLAN $tag
allow-vmbr1 vlan$tag
auto vlan$tag
iface vlan$tag inet static
    ovs_type OVSIntPort
    ovs_bridge vmbr1
    ovs_options tag=$tag
    address 10.10.${tag}.${OCT}/24
    mtu 9000
EOF
    done
}

apply_config() {
    systemctl restart networking
    ovs-vsctl set Open_vSwitch . other_config:mtu=9000
    systemctl restart openvswitch-switch
    netplan apply 2>/dev/null || true
}

verify_config() {
    log_info "Verifying OVS configuration:"
    ovs-vsctl show
    ovs-appctl bond/show bond0
    log_info "\nNetwork status:"
    ip -br a
    ip route
}

main() {
    check_root
    validate_octet
    detect_interfaces
    select_interfaces
    calculate_ips
    install_dependencies
    backup_config
    configure_host
    write_network_config
    apply_config
    verify_config
}

main "$@"
