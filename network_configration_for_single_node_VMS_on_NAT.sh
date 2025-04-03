#!/usr/bin/env bash
# filepath: /Users/jgrewal/projects/iso/bitbucket/proxmox/network_configration.sh

## CREATES A ROUTED vmbr0 AND NAT vmbr1 NETWORK CONFIGURATION FOR PROXMOX
# Autodetects the correct settings (interface, gateway, netmask, etc.)
# Supports IPv4 and IPv6, Private Network uses configurable NAT subnet
#
# Also installs and configures the isc-dhcp-server for VM networking

# Set strict error handling
set -euo pipefail

# Set locale for consistent script behavior
export LANG="en_US.UTF-8"
export LC_ALL="C"

# -------------------------------------------------------------------
# Configuration variables - modify these if needed
# -------------------------------------------------------------------
# Network configuration files
NETWORK_INTERFACES_FILE="/etc/network/interfaces"
SYSCTL_CONF_FILE="/etc/sysctl.d/99-proxmox-networking.conf"

# NAT network configuration - change these if they conflict with existing networks
NAT_NETWORK="10.50.10.0/24"
NAT_IP="10.50.10.1"
NAT_NETMASK="255.255.255.0"
NAT_DHCP_RANGE_START="10.50.10.100"
NAT_DHCP_RANGE_END="10.50.10.200"

# DNS servers for DHCP clients
DNS_SERVERS="1.1.1.1,8.8.8.8"

# Helper script details
HELPER_SCRIPT="network-addiprange.sh"
HELPER_SCRIPT_URL="https://bitbucket.org/jsgrewal/proxmox/raw/main/network-addiprange.sh"

# DHCP configuration files
DHCP_DEFAULT_FILE="/etc/default/isc-dhcp-server"
DHCP_CONF_FILE="/etc/dhcp/dhcpd.conf"
DHCP_HOSTS_FILE="/etc/dhcp/hosts.public"

# -------------------------------------------------------------------
# Logging functions with color output
# -------------------------------------------------------------------
# ANSI color codes for terminal output
readonly ANSI_RESET="\033[0m"
readonly ANSI_RED="\033[0;31m"
readonly ANSI_GREEN="\033[0;32m"
readonly ANSI_YELLOW="\033[0;33m"
readonly ANSI_BLUE="\033[0;34m"
readonly ANSI_BOLD="\033[1m"

# Print informational message in green
log_info() {
    echo -e "${ANSI_GREEN}[INFO]${ANSI_RESET} $1"
}

# Print warning message in yellow (to stderr for visibility)
log_warn() {
    echo -e "${ANSI_YELLOW}[WARNING]${ANSI_RESET} $1" >&2
}

# Print error message in red (to stderr)
log_error() {
    echo -e "${ANSI_RED}[ERROR]${ANSI_RESET} $1" >&2
    # No explicit return code - let the script continue in some cases
}

# Print success message with bold green text
log_success() {
    echo -e "${ANSI_GREEN}${ANSI_BOLD}[SUCCESS]${ANSI_RESET} $1"
}

# -------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------

# Convert CIDR notation to netmask
# Example: cdr2mask 24 returns 255.255.255.0
cdr2mask() {
    local cidr="$1"

    # Validate input
    if [[ ! "$cidr" =~ ^[0-9]+$ ]] || [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
        log_error "Invalid CIDR value: $cidr"
        echo "255.255.255.0" # Return a safe default
        return 0
    fi

    # Use binary math to calculate the netmask
    # This is more efficient than the previous implementation
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_octet=$((cidr % 8))

    # Process each octet of the mask
    for i in {0..3}; do
        if [ "$i" -lt $full_octets ]; then
            # Full octet (all 1's)
            mask+="255"
        elif [ "$i" -eq $full_octets ] && [ $partial_octet -gt 0 ]; then
            # Partial octet - calculate value using binary math
            # Create a binary number with the needed 1's and then convert to decimal
            # Example: For CIDR 24, we need 0 partial bits
            #          For CIDR 25, we need 1 partial bit (10000000 = 128)
            #          For CIDR 26, we need 2 partial bits (11000000 = 192)
            local value=$((256 - 2 ** (8 - partial_octet)))
            mask+="$value"
        else
            # Empty octet (all 0's)
            mask+="0"
        fi

        # Add dots between octets, except after the last one
        if [ "$i" -lt 3 ]; then
            mask+="."
        fi
    done

    echo "$mask"
}

# Check if a command exists and is executable
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Create a timestamped backup of a file
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup="${file}.$(date +"%Y-%m-%d_%H-%M-%S")"
        log_info "Creating backup of $file to $backup"
        cp "$file" "$backup" || {
            log_error "Failed to backup $file"
            return 1
        }
    fi
    return 0
}

# Parse a CIDR notation network (e.g., 10.0.0.0/24) into components
# Returns: IP CIDR NETMASK in space-separated format
parse_cidr_network() {
    local cidr_notation="$1"
    local ip="${cidr_notation%/*}"
    local cidr="${cidr_notation#*/}"

    # Validate IP and CIDR
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid IP address format in CIDR notation: $cidr_notation"
        return 1
    fi

    if [[ ! "$cidr" =~ ^[0-9]+$ ]] || [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
        log_error "Invalid CIDR value in CIDR notation: $cidr_notation"
        return 1
    fi

    # Calculate netmask
    local netmask
    netmask=$(cdr2mask "$cidr")

    echo "$ip $cidr $netmask"
}

# -------------------------------------------------------------------
# Dependency installation and verification
# -------------------------------------------------------------------
install_dependencies() {
    log_info "Checking and installing dependencies..."

    # Required packages list
    local packages=("isc-dhcp-server" "curl" "net-tools")
    local missing_packages=()

    # Check for each required package
    for pkg in "${packages[@]}"; do
        case "$pkg" in
        "isc-dhcp-server")
            if ! command_exists dhcpd; then
                missing_packages+=("$pkg")
            fi
            ;;
        *)
            if ! command_exists "$pkg"; then
                missing_packages+=("$pkg")
            fi
            ;;
        esac
    done

    # Install missing packages if needed
    if [ ${#missing_packages[@]} -gt 0 ]; then
        log_info "Installing missing packages: ${missing_packages[*]}"

        # Update package lists first
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
            log_error "Failed to update package lists"
            return 1
        }

        # Install packages with minimal output and non-interactive mode
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::='--force-confdef' \
            -o Dpkg::Options::='--force-confold' \
            "${missing_packages[@]}" || {
            log_error "Failed to install required packages"
            return 1
        }
    fi

    # Download helper script if missing or verify its integrity
    if [ ! -f "$HELPER_SCRIPT" ]; then
        log_info "Downloading $HELPER_SCRIPT from repository..."
        curl -sS -o "$HELPER_SCRIPT" "$HELPER_SCRIPT_URL" || {
            log_error "Failed to download $HELPER_SCRIPT"
            return 1
        }
        chmod +x "$HELPER_SCRIPT" || {
            log_error "Failed to make $HELPER_SCRIPT executable"
            return 1
        }
    fi

    # Verify helper script integrity
    if ! grep -q '#!/usr/bin/env bash' "$HELPER_SCRIPT"; then
        log_error "$HELPER_SCRIPT is invalid or corrupted"
        return 1
    fi

    log_success "All dependencies satisfied"
    return 0
}

# -------------------------------------------------------------------
# Configure system for IP forwarding
# -------------------------------------------------------------------
configure_ip_forwarding() {
    log_info "Configuring IP forwarding..."

    # Detect primary interface for more specific configuration
    local primary_interface="${1:-eth0}"

    # Create sysctl configuration file if it doesn't exist
    if [ ! -f "$SYSCTL_CONF_FILE" ]; then
        log_info "Creating $SYSCTL_CONF_FILE"

        # Create configuration with detailed comments
        cat >"$SYSCTL_CONF_FILE" <<EOF
# Proxmox VE Network Configuration
# Generated on $(date)
# This file enables IP forwarding and other networking optimizations

# --- IPv4 Configuration ---
# Enable IPv4 packet forwarding (required for routing/NAT)
net.ipv4.ip_forward = 1

# Prevent source routing which can be used for attacks
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects to prevent routing loops
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.${primary_interface}.send_redirects = 0

# Enable reverse path filtering to prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# --- IPv6 Configuration ---
# Enable IPv6 forwarding (if you use IPv6)
net.ipv6.conf.all.forwarding = 1

# Disable IPv6 autoconfiguration on the main interface
net.ipv6.conf.${primary_interface}.autoconf = 0

# --- Kernel Network Optimizations ---
# Increase connection tracking table size
net.netfilter.nf_conntrack_max = 262144

# Increase the local port range for outgoing connections
net.ipv4.ip_local_port_range = 32768 65535

# Increase TCP performance with larger buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF

        # Apply configuration immediately
        if ! sysctl -p "$SYSCTL_CONF_FILE"; then
            log_warn "Some sysctl settings may not have been applied. Check for errors above."
            # We continue despite errors, as some settings might require reboot
        else
            log_success "IP forwarding configured successfully"
        fi
    else
        log_info "$SYSCTL_CONF_FILE already exists, checking for required settings"

        # Check if ip_forward is enabled
        if ! grep -q "net.ipv4.ip_forward = 1" "$SYSCTL_CONF_FILE"; then
            log_warn "IP forwarding may not be enabled in $SYSCTL_CONF_FILE"
            log_info "Adding missing IP forwarding configuration"

            # Append the key setting if missing
            echo "# Added by network configuration script" >>"$SYSCTL_CONF_FILE"
            echo "net.ipv4.ip_forward = 1" >>"$SYSCTL_CONF_FILE"
            echo "net.ipv6.conf.all.forwarding = 1" >>"$SYSCTL_CONF_FILE"

            # Apply only the added configuration
            sysctl -w net.ipv4.ip_forward=1
            sysctl -w net.ipv6.conf.all.forwarding=1
        fi
    fi
}

# -------------------------------------------------------------------
# Network detection functions
# -------------------------------------------------------------------

# Detect default network interface using multiple strategies
detect_default_interface() {
    log_info "Detecting primary network interface..."

    # Array to store potential interfaces in order of preference
    local potential_interfaces=()

    # Strategy 1: Get interface from default route to common public DNS servers
    for dns in "8.8.8.8" "1.1.1.1"; do
        local route_if
        route_if=$(ip -o route get "$dns" 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}')
        if [ -n "$route_if" ]; then
            potential_interfaces+=("$route_if")
            break # Found a working route
        fi
    done

    # Strategy 2: Use default route interface if strategy 1 failed
    if [ ${#potential_interfaces[@]} -eq 0 ]; then
        local default_if
        default_if=$(ip -o route | grep default | awk '{print $5}' | head -n1)
        if [ -n "$default_if" ]; then
            potential_interfaces+=("$default_if")
        fi
    fi

    # Strategy 3: Find physical interfaces that are UP
    # This approach uses a cleaner implementation than complex sed chains
    if [ ${#potential_interfaces[@]} -eq 0 ]; then
        # Get all interfaces that are UP, excluding loopback and virtual interfaces
        while read -r line; do
            local if_name
            if_name=$(echo "$line" | awk '{print $2}')

            # Skip virtual and special interfaces
            if [[ "$if_name" != lo && "$if_name" != veth* &&
                "$if_name" != vmbr* && "$if_name" != tap* &&
                "$if_name" != docker* && "$if_name" != br* ]]; then
                potential_interfaces+=("$if_name")
            fi
        done < <(ip -br link show up)
    fi

    # Strategy 4: Last resort - get any non-loopback interface
    if [ ${#potential_interfaces[@]} -eq 0 ]; then
        while read -r line; do
            local if_name
            if_name=$(echo "$line" | awk '{print $2}')

            if [[ "$if_name" != lo ]]; then
                potential_interfaces+=("$if_name")
            fi
        done < <(ip -br link show)
    fi

    # Verify we have a valid interface
    if [ ${#potential_interfaces[@]} -eq 0 ]; then
        log_error "Failed to detect any network interface"
        return 1
    fi

    # Use the first detected interface
    local selected_interface="${potential_interfaces[0]}"

    # Check if using old-style ethX names and newer alternative exists
    if [[ $selected_interface == eth* ]]; then
        local alt_name
        alt_name=$(ip link show "$selected_interface" | grep -o 'altname [^ ]*' | awk '{print $2}')
        # Use alternative name if available and not empty
        if [ -n "$alt_name" ] && [ "$alt_name" != " " ]; then
            selected_interface="$alt_name"
        fi
    fi

    # Verify interface exists and is operational
    if ! ip link show dev "$selected_interface" &>/dev/null; then
        log_error "Selected interface '$selected_interface' does not exist"
        return 1
    fi

    log_success "Detected interface: $selected_interface"
    echo "$selected_interface"
}

# Detect IPv4 network configuration for an interface
detect_ipv4_config() {
    local interface="$1"
    log_info "Detecting IPv4 configuration for $interface..."

    # Get IP and CIDR mask - use grep to ensure we get primary IPv4 address
    local ipcidr
    ipcidr=$(ip -4 addr show dev "$interface" | grep 'inet ' | grep -v 'scope host' | head -n1 | awk '{print $2}')

    # Check if we found the IP address
    if [ -z "$ipcidr" ]; then
        log_error "No IPv4 address found for interface $interface"
        return 1
    fi

    # Parse IP and CIDR
    local ip="${ipcidr%/*}"
    local cidr="${ipcidr#*/}"

    # Get gateway from default route
    local gateway
    gateway=$(ip route | grep "default.*$interface" | awk '{print $3}' | head -n1)

    # Validate gateway - critical for proper routing
    if [ -z "$gateway" ]; then
        log_error "No default gateway found for interface $interface"
        return 1
    fi

    # Calculate netmask from CIDR
    local netmask
    netmask=$(cdr2mask "$cidr")

    # Return as colon-separated string (easier to parse than spaces)
    echo "$ip:$netmask:$gateway:$cidr"
}

# Detect IPv6 configuration if available
detect_ipv6_config() {
    local interface="$1"
    log_info "Detecting IPv6 configuration for $interface..."

    # Get global IPv6 address and mask - only interested in global addresses
    local ipv6cidr
    ipv6cidr=$(ip -6 addr show dev "$interface" | grep 'inet6' | grep 'scope global' | head -n1 | awk '{print $2}')

    # If no IPv6 is configured, return empty
    if [ -z "$ipv6cidr" ]; then
        log_info "No global IPv6 address found for $interface"
        return 0
    fi

    local ipv6="${ipv6cidr%/*}"
    local mask="${ipv6cidr#*/}"

    # Get IPv6 gateway
    local gateway
    gateway=$(ip -6 route | grep "default.*$interface" | awk '{print $3}' | head -n1)

    # Only return if we have complete configuration
    if [ -n "$ipv6" ] && [ -n "$mask" ] && [ -n "$gateway" ]; then
        echo "$ipv6:$mask:$gateway"
    else
        log_warn "Incomplete IPv6 configuration found, skipping IPv6 setup"
    fi
}

# -------------------------------------------------------------------
# Network configuration functions
# -------------------------------------------------------------------

# Generate the interfaces file
create_interfaces_file() {
    local interface="$1"
    local ipv4_config="$2"
    local ipv6_config="$3"

    log_info "Generating network interfaces configuration..."

    # Parse IPv4 configuration
    IFS=':' read -r ip netmask gateway cidr <<<"$ipv4_config"

    # Create array of IP address octets for DHCP configuration
    IFS='.' read -r -a ip_array <<<"$ip"

    # First backup the existing file
    backup_file "$NETWORK_INTERFACES_FILE"

    # Create new interfaces file with header
    cat >"$NETWORK_INTERFACES_FILE" <<EOF
# Proxmox VE Network Configuration
# Generated on $(date) by Proxmox Network Configuration Script
# DO NOT EDIT MANUALLY - This file is managed by scripts

### LOOPBACK ###
auto lo
iface lo inet loopback
iface lo inet6 loopback

### PRIMARY PHYSICAL INTERFACE ###
# Interface: ${interface}
auto ${interface}
iface ${interface} inet static
  address ${ip}
  netmask ${netmask}
  gateway ${gateway}

### PROXMOX ROUTING BRIDGE ###
# This is a virtual bridge for routing traffic to VMs with public IPs
# No physical interfaces are bridged - used for IP routing only
auto vmbr0
iface vmbr0 inet static
  address ${ip}
  netmask ${netmask}
  bridge_ports none
  bridge_stp off
  bridge_fd 0
  bridge_maxwait 0

### PRIVATE NAT NETWORK ###
# This creates an internal NAT network for VMs without public IPs
# VMs on this network will use NAT through the host to access the internet
auto vmbr1
iface vmbr1 inet static
  address ${NAT_IP}
  netmask ${NAT_NETMASK}
  bridge_ports none
  bridge_stp off
  bridge_fd 0
  bridge_maxwait 0
  # NAT configuration using iptables
  post-up   iptables -t nat -A POSTROUTING -s '${NAT_NETWORK}' -o ${interface} -j MASQUERADE
  post-down iptables -t nat -D POSTROUTING -s '${NAT_NETWORK}' -o ${interface} -j MASQUERADE

### HIGH-PERFORMANCE PRIVATE LAN (OPTIONAL) ###
# Uncomment and adjust this section if you have a dedicated NIC for VM-to-VM traffic
#auto enp1s0
#iface enp1s0 inet manual
#
#auto vmbr2
#iface vmbr2 inet static
#  address 10.10.10.1
#  netmask 255.255.255.0
#  bridge_ports enp1s0
#  bridge_stp off
#  bridge_fd 0
#  # Jumbo frames for better performance (adjust if your hardware supports it)
#  post-up ip link set \$IFACE mtu 9000
#  # Enable faster VM-to-VM traffic with hardware offload if supported
#  post-up ethtool -K enp1s0 tso on gso on gro on
#
# # To enable migrations via the private LAN, run:
# # echo "migration: insecure,network=10.10.10.0/24" >> /etc/pve/datacenter.cfg

### INCLUDE ADDITIONAL CONFIGURATIONS ###
source /etc/network/interfaces.d/*

EOF

    # Add IPv6 configuration if available
    if [ -n "$ipv6_config" ]; then
        IFS=':' read -r ipv6 ipv6mask ipv6gateway <<<"$ipv6_config"

        cat >>"$NETWORK_INTERFACES_FILE" <<EOF
### IPv6 CONFIGURATION ###
iface ${interface} inet6 static
  address ${ipv6}
  netmask ${ipv6mask}
  gateway ${ipv6gateway}

# Mirror IPv6 configuration to vmbr0 for VM routing
iface vmbr0 inet6 static
  address ${ipv6}
  netmask ${ipv6mask}
  # No gateway specified - traffic routes through primary interface

EOF
    fi

    # Add section for extra IP ranges
    cat >>"$NETWORK_INTERFACES_FILE" <<EOF
### ADDITIONAL IP RANGES ###
# To add IP ranges or additional IPs, use the ${HELPER_SCRIPT} script:
#   ./${HELPER_SCRIPT} <ip/cidr> [interface]
#
# Examples:
#   ./${HELPER_SCRIPT} 192.168.100.0/24 vmbr0  # Add a subnet
#   ./${HELPER_SCRIPT} 203.0.113.5/32 vmbr0    # Add a single IP

EOF

    log_success "Network interfaces configuration created successfully"
}

# Configure DHCP server for VM networking
configure_dhcp() {
    local ipv4_config="$1"

    log_info "Configuring DHCP server..."

    # Parse IPv4 configuration
    IFS=':' read -r ip netmask gateway cidr <<<"$ipv4_config"

    # Create array of IP address octets for DHCP configuration
    IFS='.' read -r -a ip_array <<<"$ip"

    # Parse NAT network
    local nat_network_components
    nat_network_components=$(parse_cidr_network "$NAT_NETWORK")
    read -r nat_network_ip nat_network_cidr nat_network_netmask <<<"$nat_network_components"

    # Backup existing DHCP configuration files
    backup_file "$DHCP_DEFAULT_FILE"
    backup_file "$DHCP_CONF_FILE"

    # Configure DHCP server interfaces
    cat >"$DHCP_DEFAULT_FILE" <<EOF
# DHCP Server Configuration for Proxmox VE
# Generated on $(date) by Proxmox Network Configuration Script
# Defines which interfaces the DHCP server listens on

# Path to dhcpd's config file (default: /etc/dhcp/dhcpd.conf)
DHCPDv4_CONF=${DHCP_CONF_FILE}

# Path to dhcpd's PID file (default: /var/run/dhcpd.pid)
DHCPDv4_PID=/var/run/dhcpd.pid

# Additional options to start dhcpd with
# Don't use options -cf or -pf here; use DHCPD_CONF/DHCPD_PID instead
OPTIONS=""

# Interfaces on which the DHCP server should listen
# The server will ONLY respond to requests from these interfaces
INTERFACESv4="vmbr1"
EOF

    # Create DHCP configuration for VMs
    cat >"$DHCP_CONF_FILE" <<EOF
# DHCP Server Configuration for Proxmox VE
# Generated on $(date) by Proxmox Network Configuration Script
# See https://linux.die.net/man/5/dhcpd.conf for configuration details

# Global DHCP server configuration
ddns-update-style none;
default-lease-time 600;       # 10 minutes default lease time
max-lease-time 7200;          # 2 hours maximum lease time
log-facility local7;          # Use local7 for logging

# Define custom routing options
option rfc3442-classless-static-routes code 121 = array of integer 8;
option ms-classless-static-routes code 249 = array of integer 8;

# DNS servers for all clients
option domain-name-servers ${DNS_SERVERS};

# NAT/Private network configuration (vmbr1: ${NAT_NETWORK})
subnet ${nat_network_ip} netmask ${nat_network_netmask} {
  # DHCP range for private network clients
  range ${NAT_DHCP_RANGE_START} ${NAT_DHCP_RANGE_END};
  authoritative;
  
  # Lease times
  default-lease-time 3600;       # 1 hour default lease
  max-lease-time 86400;          # 24 hours maximum lease
  
  # Network configuration
  option routers ${NAT_IP};      # NAT gateway
  option subnet-mask ${NAT_NETMASK};
  option broadcast-address ${NAT_IP%.*}.255;
  option domain-name "private.proxmox.local";
  
  # Time zone offset (adjust as needed)
  option time-offset -18000;    # Eastern Time (-5 hours)
}

# Host-specific configurations for vmbr0 (public network)
# These are static assignments for VMs with public IPs
group {
  # Use long lease times for static public IP assignments
  default-lease-time 604800;     # 1 week default lease
  max-lease-time 2592000;        # 30 days maximum lease
  
  # Router is the Proxmox host's public IP
  option routers ${ip};
  
  # Point-to-point networking for public IPs
  option subnet-mask 255.255.255.255;
  
  # Include host definitions from external file
  include "${DHCP_HOSTS_FILE}";
}
EOF

    # Create DHCP hosts file with examples if it doesn't exist
    if [ ! -f "$DHCP_HOSTS_FILE" ]; then
        cat >"$DHCP_HOSTS_FILE" <<EOF
# Static DHCP Host Definitions for Public IP Addresses
# Add entries here for VMs that need static public IP assignments
# Generated on $(date) by Proxmox Network Configuration Script

# ==============================================
# EXAMPLES - REMOVE OR ADJUST FOR YOUR ENVIRONMENT
# ==============================================

# Example: VM with hostname web-server.example.com and MAC 52:54:00:12:34:56
#host web-server.example.com {
#  hardware ethernet 52:54:00:12:34:56;
#  fixed-address 203.0.113.10;
#  option host-name "web-server.example.com";
#}

# Example: VM with hostname db-server.example.com and MAC 52:54:00:AB:CD:EF
#host db-server.example.com {
#  hardware ethernet 52:54:00:AB:CD:EF;
#  fixed-address 203.0.113.20;
#  option host-name "db-server.example.com";
#}

# ==============================================
# USAGE NOTES
# ==============================================
# 1. VM Configuration:
#    - Set VM network to DHCP
#    - Example config for Linux:
#      auto eth0
#      iface eth0 inet dhcp
#
# 2. MAC Address Format:
#    - Use lowercase with colons (aa:bb:cc:dd:ee:ff)
#    - Proxmox default MAC format is 52:54:00:xx:xx:xx
#
# 3. Testing:
#    - After adding entries, restart DHCP server:
#      systemctl restart isc-dhcp-server
#    - Check logs with:
#      journalctl -u isc-dhcp-server
EOF
    fi

    # Enable and start DHCP server
    systemctl enable isc-dhcp-server || log_warn "Failed to enable DHCP server at boot"

    # Don't start the service now - wait until network is properly configured
    log_success "DHCP server configured successfully"
}

# -------------------------------------------------------------------
# Parallel processing of configuration tasks
# -------------------------------------------------------------------
# This function demonstrates using parallel processing for independent tasks
run_parallel_tasks() {
    log_info "Running configuration tasks in parallel for faster setup..."

    # Create a temporary directory for parallel task status
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Task 1: Configure IP forwarding
    {
        configure_ip_forwarding "$1" &&
            touch "$tmp_dir/task1_success" ||
            touch "$tmp_dir/task1_failure"
    } &

    # Task 2: Download helper script if needed
    {
        # Download helper script if missing
        if [ ! -f "$HELPER_SCRIPT" ]; then
            curl -sS -o "$HELPER_SCRIPT" "$HELPER_SCRIPT_URL" &&
                chmod +x "$HELPER_SCRIPT" &&
                touch "$tmp_dir/task2_success" ||
                touch "$tmp_dir/task2_failure"
        else
            touch "$tmp_dir/task2_success"
        fi
    } &

    # Wait for all background tasks to complete
    wait

    # Check task results
    local failed_tasks=0
    if [ -f "$tmp_dir/task1_failure" ]; then
        log_error "IP forwarding configuration failed"
        ((failed_tasks++))
    fi

    if [ -f "$tmp_dir/task2_failure" ]; then
        log_error "Helper script download failed"
        ((failed_tasks++))
    fi

    # Clean up temporary directory
    rm -rf "$tmp_dir"

    # Return success if all tasks succeeded
    return $failed_tasks
}

# -------------------------------------------------------------------
# Main function - orchestrates the entire configuration process
# -------------------------------------------------------------------
main() {
    # Display banner
    cat <<EOF
======================================================================
  Proxmox VE Network Configuration Script
  Creates Routed (vmbr0) and NAT (vmbr1) Networking Configuration
  Automatic Detection and Configuration of Network Settings
======================================================================
EOF

    # Install dependencies
    install_dependencies || {
        log_error "Failed to install dependencies. Please check the errors above."
        exit 1
    }

    # Detect the default network interface
    local default_interface
    default_interface=$(detect_default_interface) || {
        log_error "Failed to detect network interface. Exiting."
        exit 1
    }

    # Run some tasks in parallel to speed up configuration
    run_parallel_tasks "$default_interface"

    # These tasks must run sequentially because they depend on each other
    log_info "Detecting network configuration..."

    # Detect IPv4 configuration
    local ipv4_config
    ipv4_config=$(detect_ipv4_config "$default_interface") || {
        log_error "Failed to detect IPv4 configuration. Exiting."
        exit 1
    }

    # Detect IPv6 configuration (optional)
    local ipv6_config
    ipv6_config=$(detect_ipv6_config "$default_interface") || true

    # Create network interfaces file
    create_interfaces_file "$default_interface" "$ipv4_config" "$ipv6_config" || {
        log_error "Failed to create network interfaces file. Exiting."
        exit 1
    }

    # Configure DHCP server
    configure_dhcp "$ipv4_config" || {
        log_error "Failed to configure DHCP server. Exiting."
        exit 1
    }

    # Final instructions with highlighted commands
    cat <<EOF
======================================================================
${ANSI_GREEN}${ANSI_BOLD}NETWORK CONFIGURATION COMPLETE!${ANSI_RESET}

Your Proxmox system has been configured with:
  - Primary interface: ${default_interface}
  - Public IP: $(echo "$ipv4_config" | cut -d: -f1)
  - NAT network: ${NAT_NETWORK} (gateway: ${NAT_IP})
  - DHCP range: ${NAT_DHCP_RANGE_START} - ${NAT_DHCP_RANGE_END}

${ANSI_YELLOW}To apply changes, run:${ANSI_RESET}
  ${ANSI_BOLD}systemctl restart networking${ANSI_RESET}
  ${ANSI_BOLD}systemctl restart isc-dhcp-server${ANSI_RESET}

${ANSI_YELLOW}To add additional IPs or ranges:${ANSI_RESET}
  ${ANSI_BOLD}./${HELPER_SCRIPT} <ip/cidr> [interface]${ANSI_RESET}

${ANSI_YELLOW}For VM networking:${ANSI_RESET}
  - Use ${ANSI_BOLD}vmbr0${ANSI_RESET} for VMs with public IPs
  - Use ${ANSI_BOLD}vmbr1${ANSI_RESET} for VMs that need NAT

${ANSI_YELLOW}For more information:${ANSI_RESET}
  - Network config: ${NETWORK_INTERFACES_FILE}
  - DHCP config: ${DHCP_CONF_FILE}
  - DHCP hosts: ${DHCP_HOSTS_FILE}
======================================================================
EOF
}

# Execute main function with all passed arguments
main "$@"
