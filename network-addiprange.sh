#!/usr/bin/env bash
# filepath: /Users/jgrewal/projects/iso/bitbucket/proxmox/network-addiprange.sh

# =============================================================================
# Proxmox IP Range Addition Script
#
# This script is designed to add IP ranges to a specified network interface
# on a Proxmox server. It supports both temporary (until reboot) and permanent
# (via a persistence script) configurations. The script validates input,
# calculates network details, and ensures proper configuration.
# =============================================================================

# Set strict error handling to catch issues early
set -euo pipefail

# Set consistent locale for predictable text processing
export LANG="en_US.UTF-8"
export LC_ALL="C"

# =============================================================================
# Constants and configuration
# =============================================================================
readonly ROUTE_SCRIPT="/etc/network/if-up.d/route"
readonly DEFAULT_CIDR=32
readonly ANSI_RESET="\033[0m"
readonly ANSI_RED="\033[0;31m"
readonly ANSI_GREEN="\033[0;32m"
readonly ANSI_YELLOW="\033[0;33m"
readonly ANSI_BLUE="\033[0;34m"

# =============================================================================
# Helper functions for output formatting
# =============================================================================

# Print a formatted error message and exit
print_error() {
    echo -e "${ANSI_RED}ERROR:${ANSI_RESET} $1" >&2
    exit 1
}

# Print an informational message
print_info() {
    echo -e "${ANSI_BLUE}INFO:${ANSI_RESET} $1"
}

# Print a warning message
print_warning() {
    echo -e "${ANSI_YELLOW}WARNING:${ANSI_RESET} $1" >&2
}

# Print a success message
print_success() {
    echo -e "${ANSI_GREEN}SUCCESS:${ANSI_RESET} $1"
}

# Display usage information
show_usage() {
    echo "Usage: $(basename "$0") <ip/cidr> [interface]"
    echo
    echo "Examples:"
    echo "  $(basename "$0") 192.168.1.0/24 vmbr0     # Add 192.168.1.0/24 network to vmbr0"
    echo "  $(basename "$0") 10.0.0.5 eth0            # Add single IP 10.0.0.5 to eth0 (assumes /32)"
    echo "  $(basename "$0") 10.0.0.1 / 29 vmbr0      # Alternative syntax for 10.0.0.1/29 on vmbr0"
    echo
    echo "If interface is omitted, the script will use vmbr0 if available,"
    echo "otherwise it will use the default gateway interface."
}

# =============================================================================
# Validation functions
# =============================================================================

# Validate an IPv4 address
# Returns 0 if valid, 1 if invalid
validate_ipv4() {
    local ip="$1"

    # Check format using regex for IPv4 (xxx.xxx.xxx.xxx)
    if ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi

    # Validate each octet is between 0-255
    IFS='.' read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 || $octet -lt 0 ]]; then
            return 1
        fi
    done

    return 0
}

# Validate CIDR notation (1-32)
# Returns 0 if valid, 1 if invalid
validate_cidr() {
    local cidr="$1"

    # Check if it's a number
    if ! [[ $cidr =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Check range 1-32
    if [[ $cidr -lt 1 || $cidr -gt 32 ]]; then
        return 1
    fi

    return 0
}

# Validate that a network interface exists and is up
# Returns 0 if valid, 1 if invalid
validate_interface() {
    local interface="$1"

    # Check if the interface exists
    if ! ip link show dev "$interface" &>/dev/null; then
        print_error "Interface '$interface' does not exist"
        return 1
    fi

    # Check if the interface is up
    if ! ip -br link show dev "$interface" | grep -q "UP"; then
        print_warning "Interface '$interface' exists but is not UP"
        # Continue anyway - this is just a warning
    fi

    return 0
}

# =============================================================================
# Network calculation functions
# =============================================================================

# Calculate netmask from CIDR notation
# More efficient implementation using bit manipulation
calculate_netmask() {
    local cidr="$1"
    local bits=$((32 - cidr))
    local mask=""

    # Calculate each octet of the netmask
    # This approach handles all CIDR values correctly
    for i in {0..3}; do
        local octet=0
        for j in {0..7}; do
            local bit=$((i * 8 + j))
            if [[ $bit -lt $bits ]]; then
                octet=$((octet | (1 << (7 - j))))
            fi
        done
        mask="${mask}$((255 - octet))"
        if [[ $i -lt 3 ]]; then
            mask="${mask}."
        fi
    done

    echo "$mask"
}

# Calculate network address from IP and CIDR
# This ensures we're using the correct network address
calculate_network_address() {
    local ip="$1"
    local cidr="$2"
    local mask

    # Get the netmask
    mask=$(calculate_netmask "$cidr")

    # Apply bitwise AND to get network address
    IFS='.' read -r -a ip_octets <<<"$ip"
    IFS='.' read -r -a mask_octets <<<"$mask"

    local network_octets=()
    for i in {0..3}; do
        network_octets+=($((ip_octets[i] & mask_octets[i])))
    done

    echo "${network_octets[0]}.${network_octets[1]}.${network_octets[2]}.${network_octets[3]}"
}

# =============================================================================
# Interface detection function
# =============================================================================

# Detect the best network interface to use
# Tries vmbr0 first, then falls back to default gateway interface
detect_interface() {
    local interfaces=()

    # Check if vmbr0 exists
    if ip link show dev vmbr0 &>/dev/null; then
        interfaces+=("vmbr0")
    fi

    # Get the interface used for default route as a fallback
    local default_if
    # Try multiple methods to find default interface
    default_if=$(ip -4 route show default | head -n1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

    if [[ -n "$default_if" && ! " ${interfaces[@]} " =~ " ${default_if} " ]]; then
        interfaces+=("$default_if")
    fi

    # If we have at least one interface, return the first one
    if [[ ${#interfaces[@]} -gt 0 ]]; then
        echo "${interfaces[0]}"
        return 0
    fi

    # No interface found
    return 1
}

# =============================================================================
# Route management functions
# =============================================================================

# Check if a route already exists
# This uses a much more robust check than piping multiple greps
check_route_exists() {
    local networkip="$1"
    local netmask="$2"
    local interface="$3"

    # Convert the route output to a format we can more easily match
    # and use a single grep with complete pattern to avoid false positives
    route -n | awk '{print $1" "$3" "$8}' | grep -q "^${networkip} ${netmask} ${interface}$"
}

# Add a route to the system
add_route() {
    local networkip="$1"
    local netmask="$2"
    local interface="$3"
    local route_cmd="$(command -v route)"

    # Use -n flag to prevent DNS lookups which can be slow
    if ! $route_cmd -n add -net "$networkip" netmask "$netmask" dev "$interface"; then
        print_error "Failed to add route. Check if the interface exists and is up."
    fi

    print_success "Route activated successfully"
}

# Add a route to the persistence script
add_route_to_persistence() {
    local networkip="$1"
    local netmask="$2"
    local interface="$3"
    local cidr="$4"
    local route_cmd="$(command -v route)"

    # Create the script if it doesn't exist
    if [[ ! -f "$ROUTE_SCRIPT" ]]; then
        print_info "Creating route persistence script at $ROUTE_SCRIPT"
        # Create with proper shebang and comments
        cat >"$ROUTE_SCRIPT" <<EOF
#!/usr/bin/env bash
# This file is automatically generated and updated by network scripts
# DO NOT EDIT MANUALLY unless you know what you are doing

EOF
        chmod +x "$ROUTE_SCRIPT"
    fi

    # Build the route command line with -n flag to prevent DNS lookups
    local route_cmd_line="${route_cmd} -n add -net ${networkip} netmask ${netmask} dev ${interface}"

    # Check if route already exists in the persistence script
    # -F enables fixed strings matching to avoid regex issues
    if grep -F -q "$route_cmd_line" "$ROUTE_SCRIPT"; then
        print_warning "Route already exists in $ROUTE_SCRIPT"
        return 1
    fi

    # Add the route to the script with descriptive comment
    print_info "Adding route to persistence script"
    {
        echo "# Added on $(date): ${networkip}/${cidr}"
        echo "$route_cmd_line"
        echo ""
    } >>"$ROUTE_SCRIPT"

    print_success "Route added to persistence script"
    return 0
}

# =============================================================================
# Main script logic
# =============================================================================

main() {
    # Check if we have the route command available
    local route_cmd
    if ! route_cmd=$(command -v route); then
        print_error "Required 'route' command is missing. Please install net-tools package."
    fi

    # Check for at least one argument
    if [[ $# -lt 1 ]]; then
        show_usage
        print_error "Missing required arguments"
    fi

    # Parse the input arguments using a more robust approach
    local input_ip="" cidr="" interface=""

    # Handle different input formats
    if [[ "$1" =~ "/" ]]; then
        # Format: ip/cidr [interface]
        input_ip="${1%/*}"
        cidr="${1#*/}"
        interface="${2:-}"
    elif [[ $# -ge 2 && "$2" == "/" && $# -ge 3 ]]; then
        # Format: ip / cidr [interface]
        input_ip="$1"
        cidr="$3"
        interface="${4:-}"
    else
        # Format: ip [interface]
        input_ip="$1"
        cidr="$DEFAULT_CIDR"
        print_info "IP missing CIDR notation, assigning default: $DEFAULT_CIDR"
        interface="${2:-}"
    fi

    # Validate IP address
    if ! validate_ipv4 "$input_ip"; then
        print_error "Invalid IP address: $input_ip. Use xxx.xxx.xxx.xxx format."
    fi

    # Validate CIDR
    if ! validate_cidr "$cidr"; then
        print_error "Invalid CIDR notation: $cidr. Must be an integer between 1 and 32."
    fi

    # Calculate network address to ensure we're using the correct network
    local networkip
    networkip=$(calculate_network_address "$input_ip" "$cidr")

    # Calculate total IPs and usable IPs
    local totalip=$((2 ** (32 - cidr)))
    local usableip

    # Handle special cases for network size calculations
    if [[ $cidr -eq 31 ]]; then
        # RFC 3021 allows /31 networks to have 2 usable IPs
        usableip=2
    elif [[ $cidr -eq 32 ]]; then
        # /32 is a single host
        usableip=1
    else
        # For normal networks, subtract network and broadcast addresses
        usableip=$((totalip - 2))
    fi

    # If interface wasn't specified, auto-detect it
    if [[ -z "$interface" ]]; then
        if ! interface=$(detect_interface); then
            print_error "Could not detect a suitable network interface"
        fi
        print_info "No interface specified, auto-detected: $interface"
    fi

    # Validate the interface exists
    validate_interface "$interface"

    # Calculate netmask from CIDR
    local netmask
    netmask=$(calculate_netmask "$cidr")

    # Display configuration summary
    echo "=============================================================="
    echo "Network Configuration Details:"
    echo "  Network IP:      $networkip"
    echo "  CIDR:            /$cidr"
    echo "  Netmask:         $netmask"
    echo "  Interface:       $interface"
    echo "  Total IPs:       $totalip"
    echo "  Usable IPs:      $usableip"
    echo "=============================================================="

    # Check if the route already exists using the robust check function
    if check_route_exists "$networkip" "$netmask" "$interface"; then
        print_warning "Route is already active"
    else
        print_info "Activating route until restart"
        add_route "$networkip" "$netmask" "$interface"
    fi

    # Add route to persistence script
    add_route_to_persistence "$networkip" "$netmask" "$interface" "$cidr"

    print_success "Configuration completed successfully"
}

# Execute the main function
main "$@"
