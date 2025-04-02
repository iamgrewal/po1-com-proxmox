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

# Use strict error handling and better defaults
set -euo pipefail
IFS=$'\n\t'

# Script configuration constants - at top for easy modification
DEBUG=false   # Set to true to enable debug output
DRY_RUN=false # Set to true to show what would happen without making changes
LOG_FILE="/var/log/network_migration.log"
BACKUP_DIR="/root/network_backups" # Central location for all backups
INTERFACES_FILE="/etc/network/interfaces"
DEFAULT_DNS="192.168.51.1"
DEFAULT_NETMASK="255.255.255.0"
MAX_BACKUPS=5 # Maximum number of backups to keep

# Declare global variables used across functions
declare BOND_IFACE1 BOND_IFACE2 MGMT_IP MGMT_NETMASK MGMT_GW DNS MGMT_IFACE CLUSTER_IP CEPH_IP

# Advanced terminal handling - prevents "TERM not set" errors
setup_terminal() {
    # If TERM is not set or is invalid, set a safe default
    if [[ -z "${TERM:-}" || "$TERM" == "dumb" ]]; then
        export TERM=xterm-256color
    fi

    # Ensure we have color support
    if command -v tput >/dev/null 2>&1; then
        # Colors for pretty output
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        BLUE=$(tput setaf 4)
        RESET=$(tput sgr0)
    else
        # Fallback if tput is not available
        RED="\033[0;31m"
        GREEN="\033[0;32m"
        YELLOW="\033[0;33m"
        BLUE="\033[0;34m"
        RESET="\033[0m"
    fi
}

# Run terminal setup immediately
setup_terminal

# Set a default TERM if not defined (resolves "TERM environment variable not set" issues)
if [[ -z "$TERM" ]]; then
    export TERM=xterm
fi

# Function to ensure log directory exists
ensure_log_dir() {
    # Create log directory if it doesn't exist
    if [[ ! -d "$(dirname "$LOG_FILE")" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || {
            echo "${RED}ERROR: Cannot create log directory. Running with reduced logging.${RESET}"
            LOG_FILE="/tmp/network_migration.log"
        }
    fi

    # Make sure log file is writable
    touch "$LOG_FILE" 2>/dev/null || {
        echo "${RED}ERROR: Cannot write to log file. Running with reduced logging.${RESET}"
        LOG_FILE="/tmp/network_migration.log"
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
    }
}

# Call this function to ensure log file is available
ensure_log_dir

# --- Logging Functions ---

# Logs a debug message to the log file and console if DEBUG mode is enabled.
# This function helps in troubleshooting by providing detailed information about the script's execution.
#
# Args:
#   The debug message to log.
debug() {
    if [ "$DEBUG" = true ]; then
        local func_name="${FUNCNAME[1]:-main}"
        echo "$(date +'%Y-%m-%d %H:%M:%S') - DEBUG [${func_name}]: $*" >>"$LOG_FILE"
        echo "${BLUE}DEBUG [${func_name}]: $*${RESET}" >&2
    fi
}

# Logs an informational message to the log file and console.
# This function provides general information about the script's progress.
#
# Args:
#   The informational message to log.
log_info() {
    local func_name="${FUNCNAME[1]:-main}"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - INFO [${func_name}]: $1" >>"$LOG_FILE"
    echo "${GREEN}INFO [${func_name}]: $1${RESET}" # Also print to console
}

# Logs a warning message to the log file and console.
# This function highlights potential issues that do not necessarily halt the script's execution.
#
# Args:
#   The warning message to log.
log_warning() {
    local func_name="${FUNCNAME[1]:-main}"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - WARNING [${func_name}]: $1" >>"$LOG_FILE"
    echo "${YELLOW}WARNING [${func_name}]: $1${RESET}" >&2 # Print to stderr
}

# Logs an error message to the log file and console.
# This function indicates errors that may prevent the script from completing successfully.
#
# Args:
#   The error message to log.
log_error() {
    local func_name="${FUNCNAME[1]:-main}"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR [${func_name}]: $1" >>"$LOG_FILE"
    echo "${RED}ERROR [${func_name}]: $1${RESET}" >&2
}

pause() {
    # Default timeout of 60 seconds prevents hanging in automated scripts
    local timeout_seconds=60
    local prompt_message="$1"
    local custom_timeout="${2:-$timeout_seconds}"

    # Validate input parameters
    if [[ -z "$prompt_message" ]]; then
        log_error "pause: prompt message is empty"
        return 1
    fi

    # Check if running in non-interactive mode
    if [[ ! -t 0 ]]; then
        log_warning "Running in non-interactive mode, pause skipped after $custom_timeout seconds"
        sleep 3 # Brief pause for automated environments
        return 0
    fi

    # Use -r to prevent backslash interpretation issues
    # Use -t for timeout to prevent hanging in case of no user input
    read -r -t "$custom_timeout" -p "$prompt_message"

    # Check read exit status
    local read_status=$?
    if [[ $read_status -eq 142 ]]; then
        # Timeout occurred
        log_warning "Input timeout after $custom_timeout seconds"
        echo # Add newline after timeout
    fi

    return 0
}

# Updates the system's APT repositories.
# Disables the commercial Proxmox repository, adds the no-subscription repository, and updates the sources list.
# Also removes the Proxmox subscription nag from the UI and installs necessary packages.
#
# Returns:
#   0 if successful, 1 otherwise.
update_repos() {
    log_info "Configuring repositories and removing subscription nag..."

    # Disable the commercial repository with better error handling
    if ! sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null; then
        log_warning "Failed to disable enterprise repository"
    fi

    # Extract Proxmox version using more precise Perl-compatible regex
    local pve_version
    if ! pve_version=$(grep -oP '(?<=\().*?(?=\))' /etc/os-release); then
        log_error "Failed to retrieve Proxmox version"
        return 1
    fi

    # Create the no-subscription repository entry
    printf "deb http://download.proxmox.com/debian/pve %s pve-no-subscription\n" "$pve_version" >/etc/apt/sources.list.d/pve-no-enterprise.list

    # Configure main Debian repositories
    cat <<EOF >/etc/apt/sources.list
deb https://ftp.debian.org/debian/ bookworm contrib main non-free non-free-firmware
deb https://ftp.debian.org/debian/ bookworm-updates contrib main non-free non-free-firmware
deb https://ftp.debian.org/debian/ bookworm-proposed-updates contrib main non-free non-free-firmware
deb https://ftp.debian.org/debian/ bookworm-backports contrib main non-free non-free-firmware
EOF

    # Configure Ceph repository with proper output redirection
    printf "deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription\n" | tee /etc/apt/sources.list.d/ceph.list >/dev/null

    # Create nag removal script with proper escaping
    # Using quoted heredoc to prevent variable expansion
    cat <<'EOF' >/etc/apt/apt.conf.d/no-nag-script
DPkg::Post-Invoke {
  "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; \
   if [ $? -eq 1 ]; then { \
     echo 'Removing subscription nag from UI...'; \
     sed -i '/data.status/{s/\\!//;s/Active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; \
   }; fi";
};
EOF

    # Look for local package with improved error handling and null check
    local package_path
    if ! package_path=$(find ./packages -type f -name 'proxmox-widget-toolkit*.deb' -print -quit 2>/dev/null); then
        package_path=""
    fi

    # Install from local package if available, otherwise use repository
    if [[ -n "$package_path" && -f "$package_path" ]]; then
        local package_name
        package_name=$(basename "$package_path")
        log_info "Installing proxmox-widget-toolkit from local package: $package_name"
        if ! dpkg -i "$package_path" >/dev/null 2>&1; then
            log_error "Failed to install local package: $package_name"
            log_info "Attempting to install from repositories..."
        else
            log_info "Successfully installed $package_name from local source"
            return 0
        fi
    else
        log_warning "Local proxmox-widget-toolkit package not found in ./packages"
        log_info "Attempting to install from repositories..."
    fi

    # Fall back to repository installation
    if ! apt-get update >/dev/null 2>&1 || ! apt-get install -y proxmox-widget-toolkit >/dev/null 2>&1; then
        log_error "Failed to install proxmox-widget-toolkit from repository"
        return 1
    fi

    log_info "Successfully installed proxmox-widget-toolkit from repository"
    log_info "Repository configuration completed successfully"
    return 0
}

# Prompts the user for input with validation and default value handling.
# This function simplifies getting user input while ensuring data integrity.
#
# Args:
#   prompt: The message to display to the user.
#   var_name: The name of the variable to store the input.
#   default: An optional default value.
#   is_required: Whether the input is required (true/false).
#   validation_func: An optional validation function to call.
get_input() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local is_required="${4:-false}"
    local validation_func="${5:-}"

    # Show prompt with default if provided
    if [[ -n "$default" ]]; then
        prompt="$prompt [$default]: "
    else
        prompt="$prompt: "
    fi

    while true; do
        read -r -p "$prompt" input

        # Use default if nothing entered
        if [[ -z "$input" && -n "$default" ]]; then
            input="$default"
        fi

        # Check if input is required
        if [[ -z "$input" && "$is_required" == "true" ]]; then
            log_error "Input is required"
            continue
        fi

        # Validate input if validation function provided
        if [[ -n "$validation_func" && -n "$input" ]]; then
            if ! $validation_func "$input"; then
                continue
            fi
        fi

        # Set the variable to the provided input
        printf -v "$var_name" "%s" "$input"
        break
    done
}

# Validates an IPv4 address.
# Checks if the provided string is a valid IPv4 address, including octet range validation.
#
# Args:
#   ip: The IP address to validate.
#
# Returns:
#   0 if the IP is valid, 1 otherwise.
is_valid_ip() {
    local ip="$1"

    # Check for null pointer references
    if [[ -z "$ip" ]]; then
        log_error "is_valid_ip: ip address is empty"
        return 1
    fi

    # Check format and validate each octet
    # Regex matches IPv4 pattern, then we check each octet is in valid range
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<<"$ip"
        for octet in "${octets[@]}"; do
            if ((octet < 0 || octet > 255)); then
                log_error "is_valid_ip: octet $octet in $ip is out of range (0-255)"
                return 1
            fi
        done
    else
        log_error "is_valid_ip: invalid IP address format - must be x.x.x.x where x is 0-255"
        return 1
    fi

    return 0
}

# Checks if a network interface exists.
# Uses `ip link show` to verify the existence of a given interface.
#
# Args:
#   interface: The name of the interface to check.
#
# Returns:
#   0 if the interface exists, 1 otherwise.
interface_exists() {
    local interface="$1"

    if [[ -z "$interface" ]]; then
        log_error "interface_exists: interface name is empty"
        return 1
    fi

    if ip link show "$interface" >/dev/null 2>&1; then
        debug "Interface $interface exists"
        return 0
    else
        log_error "Interface $interface does not exist. Available interfaces:"
        ip -br link show | awk '{print "  - " $1}' >&2
        return 1
    fi
}
# Lists available network interfaces.
# Displays a list of available network interfaces using `ip -br link show`.
list_interfaces() {
    echo "Available network interfaces:" >&2
    ip -br link show | awk '{print "  - "$1}' >&2
}

# Installs Debian packages from a local directory.
# This function installs .deb packages found in the ./packages directory.  It handles dependencies and package configuration.
#
# Args:
#   A list of package names to install.  The script will search for packages matching the pattern `${package}_*.deb`.
#
# Returns:
#   0 if successful, 1 otherwise.
install_packages() {
    # Add at the beginning of the function
    if [[ ! -d "./packages" ]]; then
        log_warning "Packages directory not found. Will attempt to install from repositories."
        # Add fallback apt-get install logic here
    fi

    local packages=("$@")
    local log_file="/var/log/install-packages.log"

    # Use array length instead of [[ -z "$packages" ]]
    if [ ${#packages[@]} -eq 0 ]; then
        log_error "install_packages: packages is empty"
        return 1
    fi

    mkdir -pv /var/log
    touch "$log_file"
    chmod 644 "$log_file"

    log_info "Installing packages from local folder: ${packages[*]}"

    for package in "${packages[@]}"; do
        # Find the exact .deb file matching the package name pattern
        local package_path
        if ! package_path=$(find ./packages -name "${package}_*.deb" -print -quit); then
            log_error "Failed to find package file matching ${package}_*.deb"
            return 1
        fi

        if [[ -z "$package_path" || ! -f "$package_path" ]]; then
            log_error "Package file matching ${package}_*.deb not found in ./packages"
            return 1
        fi

        local pkg_filename=$(basename "$package_path")
        log_info "Installing package: $pkg_filename"

        if ! dpkg -i "$package_path"; then
            log_error "Failed to install package $pkg_filename"
            return 1
        fi
    done

    dpkg --configure -a || log_warning "Failed to configure packages"        # Non-critical failure
    apt-get install -f -y || log_warning "Failed to fix broken dependencies" # Non-critical failure

    log_info "Packages installed successfully from local folder."
    return 0
}

# Backs up the /etc/network/interfaces file.
# Creates a timestamped backup of the interfaces file in /root/network_backups and keeps only the last 5 backups.
#
# Returns:
#   0 if successful, 1 otherwise.
backup_interfaces() {
    local filename="interfaces_backup"
    # Declare and assign separately to avoid masking return values
    local date_part
    if ! date_part=$(date "+%Y-%m-%d_%H-%M-%S"); then
        log_error "Failed to generate date for backup filename"
        return 1
    fi
    local backup_dir="/root/network_backups"
    local backup="${backup_dir}/${filename}_${date_part}.bak"

    # Validation checks
    if [[ -z "$filename" || -z "$date_part" || -z "$backup_dir" || -z "$backup" ]]; then
        log_error "backup_interfaces: one or more required variables are empty"
        return 1
    fi

    # Create backup directory if it doesn't exist
    if ! mkdir -p "$backup_dir"; then
        log_error "Failed to create backup directory: $backup_dir"
        return 1
    fi

    # Backup the interface file
    if ! cp /etc/network/interfaces "$backup"; then
        log_error "Failed to backup interfaces file to: $backup"
        return 1
    fi

    # Manage backup rotation - keep only last 5 backups
    # Use find instead of ls for better handling of special characters
    find "$backup_dir" -maxdepth 1 -type f -name 'interfaces_backup_*.bak' \
        -printf '%T+ %p\n' | sort -r | sed '1,5d' | cut -d' ' -f2- | xargs rm -f -- 2>/dev/null

    debug "Removed old backups, keeping only 5 most recent"
    log_info "Backed up current interfaces file to: $backup"
    return 0
}

# Restores the /etc/network/interfaces file from a backup.
# Presents the user with a list of available backups and restores the selected one.
#
# Returns:
#   0 if successful, 1 otherwise.
restore_interfaces() {
    local backup_dir="/root/network_backups"
    local backups=()

    # Check if backup directory exists
    if [[ ! -d "$backup_dir" ]]; then
        log_error "Backup directory $backup_dir does not exist"
        return 1
    fi

    # Use mapfile to safely populate the array
    mapfile -t backups < <(find "$backup_dir" -maxdepth 1 -type f -name 'interfaces_backup_*.bak' \
        -printf '%T+ %p\n' | sort -r | cut -d' ' -f2-)

    # Check if any backups were found
    if [ ${#backups[@]} -eq 0 ]; then
        log_error "No backups found in $backup_dir"
        return 1
    fi

    # Display available backups
    echo "Available backups:"
    for i in "${!backups[@]}"; do
        echo "  $((i + 1))) ${backups[$i]##*/}"
    done

    # Get user selection with proper validation
    read -r -p "Select backup to restore [1-${#backups[@]}]: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]]; then
        log_error "Invalid selection"
        return 1
    fi

    local selected_backup="${backups[$((choice - 1))]}"

    # Confirm restore
    read -r -p "Are you sure you want to restore from $selected_backup? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log_info "Restore cancelled"
        return 0
    fi

    # Perform restore with error handling
    if ! cp "$selected_backup" /etc/network/interfaces; then
        log_error "Failed to restore from $selected_backup"
        return 1
    fi

    log_info "Successfully restored from $selected_backup"
    return 0
}

# Configures IP forwarding and disables IPv6.
# Enables IPv4 forwarding and disables IPv6 by modifying /etc/sysctl.conf and applying the changes immediately.
#
# Returns:
#   0 if successful, 1 otherwise.
configure_ip_forwarding() {
    # Use standardized variable declaration pattern (declare then assign)
    local sysctl_config_file="/etc/sysctl.conf"
    local ipv4_forwarding_enabled="net.ipv4.ip_forward = 1"
    local ipv6_disabled_all="net.ipv6.conf.all.disable_ipv6 = 1"
    local ipv6_disabled_default="net.ipv6.conf.default.disable_ipv6 = 1"
    local temp_file
    local settings_to_add=()

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

    # Determine which settings need to be added (collect them first)
    if ! grep -q "$ipv4_forwarding_enabled" "$sysctl_config_file"; then
        settings_to_add+=("$ipv4_forwarding_enabled")
        debug "Will add IPv4 forwarding setting"
    fi

    if ! grep -q "$ipv6_disabled_all" "$sysctl_config_file"; then
        settings_to_add+=("$ipv6_disabled_all")
        debug "Will add IPv6 all disable setting"
    fi

    if ! grep -q "$ipv6_disabled_default" "$sysctl_config_file"; then
        settings_to_add+=("$ipv6_disabled_default")
        debug "Will add IPv6 default disable setting"
    fi

    # If no changes needed, return early
    if [[ ${#settings_to_add[@]} -eq 0 ]]; then
        log_info "IP forwarding already configured correctly."
        return 0
    fi

    # Check if we're in dry-run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Would configure these IP forwarding settings:"
        for setting in "${settings_to_add[@]}"; do
            log_info "DRY-RUN: Would add: $setting"
        done
        return 0
    fi

    # Create a temporary file in a secure location
    if ! temp_file=$(mktemp); then
        log_error "Failed to create temporary file"
        return 1
    fi

    # Ensure temporary file is removed on function exit or script termination
    # This is a more comprehensive trap that catches more signals
    trap 'rm -f "$temp_file"; debug "Removed temporary file: $temp_file"' RETURN EXIT INT TERM

    # Securely add settings using tee instead of direct file modification
    # This avoids having to temporarily change file permissions
    if [[ ${#settings_to_add[@]} -gt 0 ]]; then
        log_info "Adding IP forwarding configuration..."

        # Use printf to build the settings string with proper newlines
        # Then pipe to sudo tee -a to append with proper permissions
        printf '%s\n' "${settings_to_add[@]}" | sudo tee -a "$sysctl_config_file" >/dev/null

        if [[ $? -ne 0 ]]; then
            log_error "Failed to write IP forwarding settings"
            return 1
        fi
    fi

    # Apply the changes immediately
    if ! sudo sysctl -p "$sysctl_config_file"; then
        log_error "Failed to apply sysctl changes"
        return 1
    fi

    log_info "IP forwarding configuration applied successfully"
    return 0
}

# --- Configuration Functions ---

# Configures the loopback interface.
# Adds the loopback interface configuration to /etc/network/interfaces, skipping if already present.
# Returns: 0 if successful, 1 otherwise.
configure_loopback() {
    local interfaces_file="/etc/network/interfaces"

    # Validate parameters
    if [[ -z "$interfaces_file" ]]; then
        log_error "configure_loopback: interfaces_file is not set"
        return 1
    fi

    # Check file permissions
    if [[ ! -w "$interfaces_file" ]]; then
        log_error "configure_loopback: no write permissions for $interfaces_file"
        return 1
    fi

    # Check if loopback is already configured to avoid duplication
    if grep -q "^auto lo" "$interfaces_file"; then
        log_info "Loopback already configured, skipping"
        return 0
    fi

    # Add loopback configuration with proper spacing
    if ! cat <<EOF >>"$interfaces_file"; then
auto lo
iface lo inet loopback

EOF
        log_error "configure_loopback: failed to write to $interfaces_file"
        return 1
    fi

    log_info "Loopback interface configured."
    return 0
}

# Configures bonding for two network interfaces.
# Args: BOND_IFACE1, BOND_IFACE2
# Returns: 0 if successful, 1 otherwise.
configure_bonding() {
    local BOND_IFACE1="$1"
    local BOND_IFACE2="$2"

    # Validate parameters
    if [[ -z "$BOND_IFACE1" || -z "$BOND_IFACE2" ]]; then
        log_error "configure_bonding: bond interfaces are not set"
        return 1
    fi

    # Verify interfaces exist
    if ! interface_exists "$BOND_IFACE1" || ! interface_exists "$BOND_IFACE2"; then
        log_error "configure_bonding: one or both interfaces do not exist"
        return 1
    fi

    # Check file permissions
    if [[ ! -w /etc/network/interfaces ]]; then
        log_error "configure_bonding: no write permissions for /etc/network/interfaces"
        return 1
    fi

    # Add bonding configuration
    if ! cat <<EOF >>/etc/network/interfaces; then
auto $BOND_IFACE1
iface $BOND_IFACE1 inet manual
    bond-master bond0
    up ip link set dev $BOND_IFACE1 up

auto $BOND_IFACE2
iface $BOND_IFACE2 inet manual
    bond-master bond0
    up ip link set dev $BOND_IFACE2 up

auto $MGMT_IFACE
iface $MGMT_IFACE inet manual
    up ip link set dev $MGMT_IFACE up
    mtu 9000

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
    mtu 9000

EOF
        log_error "configure_bonding: failed to write to /etc/network/interfaces"
        return 1
    fi

    log_info "Bonding configured with $BOND_IFACE1 and $BOND_IFACE2."
    return 0
}

# Configures bridge interfaces (vmbr0 and vmbr1).
# Args: MGMT_IP, MGMT_NETMASK, MGMT_GW, DNS, MGMT_IFACE
# Returns: 0 if successful, 1 otherwise.
configure_bridge() {
    local MGMT_IP="$1"
    local MGMT_NETMASK="$2"
    local MGMT_GW="$3"
    local DNS="$4"
    local MGMT_IFACE="$5"

    # Validate parameters
    if [[ -z "$MGMT_IP" || -z "$MGMT_NETMASK" || -z "$MGMT_GW" || -z "$DNS" || -z "$MGMT_IFACE" ]]; then
        log_error "configure_bridge: one or more required parameters are empty"
        return 1
    fi

    # Verify interfaces exist
    if ! interface_exists "$MGMT_IFACE"; then
        log_error "configure_bridge: interface $MGMT_IFACE does not exist"
        return 1
    fi

    # Check file permissions
    if [[ ! -w /etc/network/interfaces ]]; then
        log_error "configure_bridge: no write permissions for /etc/network/interfaces"
        return 1
    fi

    # Add bridge configuration
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
    up ip link set dev vmbr1 promisc on
    up ip link set dev vmbr1 up
    mtu 9000

EOF
        log_error "configure_bridge: failed to write to /etc/network/interfaces"
        return 1
    fi

    log_info "Bridge interfaces vmbr0 and vmbr1 configured."
    return 0
}

# Configures VLAN interfaces (vlan50 and vlan55).
# Args: CLUSTER_IP, CEPH_IP, DNS
# Returns: 0 if successful, 1 otherwise.
configure_vlans() {
    local CLUSTER_IP="$1"
    local CEPH_IP="$2"
    local DNS="$3"

    # Validate parameters
    if [[ -z "$CLUSTER_IP" || -z "$CEPH_IP" || -z "$DNS" ]]; then
        log_error "configure_vlans: one or more required parameters are empty"
        return 1
    fi

    # Validate IP addresses
    if ! is_valid_ip "$CLUSTER_IP" || ! is_valid_ip "$CEPH_IP"; then
        log_error "configure_vlans: invalid IP format detected"
        return 1
    fi

    # Check file permissions
    if [[ ! -w /etc/network/interfaces ]]; then
        log_error "configure_vlans: no write permissions for /etc/network/interfaces"
        return 1
    fi

    # Add VLAN configuration
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
    mtu 9000

EOF
        log_error "configure_vlans: failed to write to /etc/network/interfaces"
        return 1
    fi

    log_info "VLAN interfaces vlan50 and vlan55 configured."
    return 0
}

# --- Interface Naming Functions ---

# Retrieves a list of network interfaces with the "enx" prefix.
# Returns a newline-separated list of interfaces starting with "enx".
get_enx_interfaces() {
    # Get interfaces starting with enx
    ip -o link show | awk -F': ' '/^[0-9]+: enx/{print $2}'
}

# Retrieves the MAC address for a given network interface.
# Reads the MAC address from /sys/class/net/$iface/address and validates the format.
#
# Args:
#   iface: The name of the interface.
#
# Returns:
#   The MAC address of the interface or an empty string if an error occurs.  Returns 1 if an error occurs.
get_mac_for_interface() {
    local iface="$1"

    # Check for null pointer reference
    if [[ -z "$iface" ]]; then
        log_error "get_mac_for_interface: interface name is empty"
        return 1
    fi

    # Check if interface exists
    if ! interface_exists "$iface"; then
        return 1
    fi

    # Check if MAC address file exists
    if [[ ! -f "/sys/class/net/$iface/address" ]]; then
        log_error "MAC address file for $iface not found"
        return 1
    fi

    local mac
    if ! mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null); then
        log_error "Failed to read MAC address for interface $iface"
        return 1
    fi

    # Validate MAC address format and content
    if [[ -z "$mac" || "$mac" =~ ^(00:00:00:00:00:00|\s*)$ ]]; then
        log_error "Invalid MAC address for interface $iface"
        return 1
    fi

    echo "$mac"
}

# Creates a systemd link file for renaming a network interface.
# This function creates a .link file in /etc/systemd/network to rename an interface based on its MAC address.
#
# Args:
#   iface: The current name of the interface.
#   newname: The desired new name for the interface.
#
# Returns:
#   0 if successful, 1 otherwise.
create_link_file() {
    local iface="$1"
    local newname="$2"
    local link_dir="/etc/systemd/network"
    local link_priority="10"

    # Check for null pointer references
    if [[ -z "$iface" || -z "$newname" ]]; then
        log_error "create_link_file: one or more required parameters is empty"
        return 1
    fi

    # Get MAC address
    local mac
    if ! mac=$(get_mac_for_interface "$iface"); then
        log_error "Failed to get MAC address for $iface"
        return 1
    fi

    # Create directory if it doesn't exist
    if ! mkdir -p "$link_dir"; then
        log_error "Failed to create directory: $link_dir"
        return 1
    fi

    # Create link file
    local file="$link_dir/${link_priority}-${newname}.link"
    if ! cat >"$file" <<EOF; then
[Match]
MACAddress=$mac
Type=ether

[Link]
Name=$newname
EOF
        log_error "Failed to write link file: $file"
        return 1
    fi

    # Verify file was created successfully
    if [[ -s "$file" ]]; then
        log_info "Created link file: $file"
        return 0
    else
        log_error "Failed to create link file: $file"
        return 1
    fi
}

# Updates the /etc/network/interfaces file with the new interface name.
# Replaces occurrences of the old interface name with the new name in the interfaces file.
#
# Args:
#   oldname: The old interface name.
#   newname: The new interface name.
#
# Returns:
#   0 if successful, 1 otherwise.
adjust_interfaces_config() {
    local oldname="$1"
    local newname="$2"
    local interfaces_file="/etc/network/interfaces"

    # Check for null pointer references
    if [[ -z "$oldname" || -z "$newname" ]]; then
        log_error "adjust_interfaces_config: one or more required parameters is empty"
        return 1
    fi

    # Check if file exists and is writable
    if [[ ! -w "$interfaces_file" ]]; then
        log_error "No write permissions for $interfaces_file"
        return 1
    fi

    # Check if old interface name is in the file
    if grep -qw "$oldname" "$interfaces_file"; then
        # Backup the file before making changes
        if ! backup_interfaces; then
            log_error "Failed to backup interfaces file before renaming"
            return 1
        fi

        # Update the file
        if ! sed -i "s/\b$oldname\b/$newname/g" "$interfaces_file"; then
            log_error "Failed to update $interfaces_file with new interface name"
            return 1
        fi

        log_info "Updated $interfaces_file with new interface name: $oldname → $newname"
    else
        log_warning "No references to $oldname in $interfaces_file"
    fi

    return 0
}

# Updates the initramfs for all installed kernels.
# This is necessary for interface renaming to take effect on boot.
#
# Returns:
#   0 if successful, 1 otherwise.
update_initramfs_all() {
    log_info "Updating initramfs for all kernels..."

    if ! update-initramfs -u -k all; then
        log_error "Failed to update initramfs"
        return 1
    fi

    log_info "Successfully updated initramfs for all kernels"
    return 0
}

# Renames all "enx" prefixed interfaces to a user-specified prefix.
# This function renames network interfaces using systemd link files and updates the interfaces configuration.  Requires a reboot to take effect.
#
# Returns:
#   0 if successful, 1 otherwise.
rename_network_interfaces() {
    # Get prefix for new interface names
    local prefix
    get_input "Enter new interface name prefix (e.g. eth, net)" prefix "eth" true

    # Validate prefix is alphanumeric with optional dashes/underscores
    if [[ ! "$prefix" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid prefix: must contain only letters, numbers, underscores, or dashes"
        return 1
    fi

    # Get all enx interfaces
    local interfaces
    if ! interfaces=$(get_enx_interfaces); then
        log_error "Failed to retrieve enx interfaces"
        return 1
    fi

    if [[ -z "$interfaces" ]]; then
        log_info "No enx interfaces found to rename"
        return 0
    fi

    log_info "Found the following enx interfaces: $interfaces"

    # Confirm before proceeding
    local confirm
    read -r -p "Do you want to rename these interfaces? This will require a reboot. [y/N]: " confirm
    confirm="${confirm,,}" # Convert to lowercase

    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        log_info "Interface renaming cancelled"
        return 0
    fi

    local index=0
    local renamed=0

    # Process each interface
    while read -r iface; do
        [[ -z "$iface" ]] && continue

        local newname="${prefix}${index}"
        log_info "Renaming $iface to $newname"

        if create_link_file "$iface" "$newname"; then
            if adjust_interfaces_config "$iface" "$newname"; then
                ((renamed++))
            fi
        fi

        ((index++))
    done <<<"$interfaces"

    if ((renamed > 0)); then
        if update_initramfs_all; then
            log_info "$renamed interfaces will be renamed on next boot"
            log_warning "A reboot is required for the changes to take effect"
        fi
    else
        log_warning "No interfaces were renamed"
    fi

    return 0
}

# --- LVM Cleanup Functions ---

# Finds and optionally deletes orphaned LVM volumes.
# Scans for LVM volumes that do not belong to any active container or VM and prompts the user for deletion.
#
# Returns:
#   0 if successful, 1 otherwise.
find_orphaned_lvm() {
    # Array to store orphaned volumes information
    local orphaned_volumes=()
    local lv vg size container_id

    log_info "Scanning for orphaned LVM volumes..."

    # Check if lvs command exists
    if ! command -v lvs >/dev/null 2>&1; then
        log_error "LVM tools not installed. Cannot scan for orphaned volumes."
        return 1
    fi

    # Scan for potentially orphaned volumes
    while read -r lv vg size; do
        # Skip critical system volumes
        if [[ "$lv" == "data" || "$lv" == "root" || "$lv" == "swap" || "$lv" =~ ^osd-block- ]]; then
            debug "Skipping critical volume: $lv"
            continue
        fi

        # Extract container/VM ID from volume name
        container_id=$(grep -oE '[0-9]+' <<<"$lv" | head -n1)

        # Skip if no ID found
        if [[ -z "$container_id" ]]; then
            debug "No container ID found in volume: $lv"
            continue
        fi

        # Skip if container or VM exists
        if [[ -f "/etc/pve/lxc/${container_id}.conf" || -f "/etc/pve/qemu-server/${container_id}.conf" ]]; then
            debug "Volume $lv belongs to active container/VM $container_id - skipping"
            continue
        fi

        # Add to orphaned volumes array
        orphaned_volumes+=("$lv" "$vg" "$size")
    done < <(lvs --noheadings -o lv_name,vg_name,lv_size --separator ' ' | awk '{print $1, $2, $3}')

    # Display results
    if [[ ${#orphaned_volumes[@]} -eq 0 ]]; then
        log_info "No orphaned LVM volumes found."
        return 0
    fi

    echo
    log_info "Orphaned LVM volumes detected:"
    echo
    printf "%-25s %-10s %-10s\n" "LV Name" "VG" "Size"
    printf "%-25s %-10s %-10s\n" "-------------------------" "----------" "----------"

    # Display each orphaned volume
    for ((i = 0; i < ${#orphaned_volumes[@]}; i += 3)); do
        printf "%-25s %-10s %-10s\n" "${orphaned_volumes[i]}" "${orphaned_volumes[i + 1]}" "${orphaned_volumes[i + 2]}"
    done

    echo

    # Prompt for deletion
    local confirm
    read -r -p "Do you want to delete orphaned volumes? [y/N]: " confirm
    confirm="${confirm,,}" # Convert to lowercase

    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        log_info "No volumes will be deleted."
        return 0
    fi

    # Process deletion
    for ((i = 0; i < ${#orphaned_volumes[@]}; i += 3)); do
        local lv="${orphaned_volumes[i]}"
        local vg="${orphaned_volumes[i + 1]}"
        local size="${orphaned_volumes[i + 2]}"

        read -r -p "Delete $lv (VG: $vg, Size: $size)? [y/N]: " confirm
        confirm="${confirm,,}" # Convert to lowercase

        if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then
            log_info "Deleting $lv from $vg"
            if lvremove -f "$vg/$lv" &>/dev/null; then
                log_info "$lv deleted successfully"
            else
                log_error "Failed to delete $lv"
            fi
        else
            log_warning "Skipped deletion of $lv"
        fi
    done

    log_info "LVM cleanup complete"
    return 0
}

# Applies the Linux network configuration.
# This is the main function that orchestrates the network configuration process.  It installs packages, backs up existing configurations, configures interfaces, and restarts networking.
#
# Args:
#   BOND_IFACE1: The name of the first interface to bond.
#   BOND_IFACE2: The name of the second interface to bond.
#   MGMT_IP: The IP address for the management interface.
#   MGMT_NETMASK: The netmask for the management interface.
#   MGMT_GW: The gateway for the management interface.
#   DNS: The DNS server address.
#   MGMT_IFACE: The name of the management interface.
#   CLUSTER_IP: The IP address for the cluster interface.
#   CEPH_IP: The IP address for the Ceph interface.
#
# Returns:
#   0 if successful, 1 otherwise.
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
    if ! install_packages ifenslave bridge-utils ethtool iproute2; then
        log_error "Failed to install required packages. Aborting."
        return 1
    fi

    # Backup existing configuration
    if ! backup_interfaces; then
        log_error "Failed to backup existing network configuration. Aborting."
        return 1
    fi

    # Clear the interfaces file
    : >/etc/network/interfaces

    # Configure the network interfaces
    configure_loopback || return 1
    configure_bonding "$BOND_IFACE1" "$BOND_IFACE2" || return 1
    configure_bridge "$MGMT_IP" "$MGMT_NETMASK" "$MGMT_GW" "$DNS" "$MGMT_IFACE" || return 1
    configure_vlans "$CLUSTER_IP" "$CEPH_IP" "$DNS" || return 1

    # Restart networking
    if ! systemctl restart networking; then
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

# Change hostname with proper error handling for non-existent config files
change_hostname() {
    local CURRENT_HOSTNAME
    local NEW_NODE_NAME

    # Get current hostname with error handling
    if ! CURRENT_HOSTNAME=$(hostname); then
        log_error "Failed to retrieve current hostname."
        return 1
    fi

    # Prompt for new hostname
    read -rp "Enter new node name (or leave blank to keep '$CURRENT_HOSTNAME'): " NEW_NODE_NAME
    if [[ -z "$NEW_NODE_NAME" ]]; then
        log_info "Node name remains as $CURRENT_HOSTNAME"
        return 0
    fi

    # Skip if hostname isn't changing
    if [[ "$NEW_NODE_NAME" == "$CURRENT_HOSTNAME" ]]; then
        log_info "Node name remains as $CURRENT_HOSTNAME"
        return 0
    fi

    log_info "Changing hostname from $CURRENT_HOSTNAME to $NEW_NODE_NAME..."

    # Set the system hostname
    if ! hostnamectl set-hostname "$NEW_NODE_NAME"; then
        log_error "Failed to set new hostname."
        return 1
    fi

    # Update system files
    local system_files_updated=true
    if ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/hosts; then
        log_error "Failed to update /etc/hosts"
        system_files_updated=false
    fi

    if ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/hostname; then
        log_error "Failed to update /etc/hostname"
        system_files_updated=false
    fi

    # Restart hostname service
    systemctl restart systemd-hostnamed || log_warning "Failed to restart systemd-hostnamed service"

    # Update mail configuration files if they exist
    for file in /etc/mailname /etc/postfix/main.cf; do
        if [[ -f "$file" ]]; then
            if ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" "$file"; then
                log_warning "Failed to update $file"
            else
                debug "Updated $file with new hostname"
            fi
        else
            debug "File $file not found, skipping"
        fi
    done

    # Update Proxmox RRD database directories if they exist
    # Using find with a conditional to prevent errors when no matches are found
    if find /var/lib/rrdcached/db/pve2-{node,storage} -type d -name "$CURRENT_HOSTNAME" 2>/dev/null | grep -q .; then
        log_info "Updating RRD database directories..."
        find /var/lib/rrdcached/db/pve2-{node,storage} -type d -name "$CURRENT_HOSTNAME" -exec sh -c '
            for f; do
                target_dir="$(dirname "$f")/'$NEW_NODE_NAME'"
                if mv "$f" "$target_dir"; then
                    echo "Moved $(basename "$f") to $(basename "$target_dir")"
                else
                    echo "Failed to move $f to $target_dir"
                fi
            done
        ' sh {} + || log_warning "Failed updating some RRD database directories"
    else
        debug "No matching RRD database directories found"
    fi

    # Update Proxmox configuration files
    log_info "Updating Proxmox configuration files..."

    # List of common Proxmox configuration files
    local pve_single_files=(
        "/etc/pve/.membership"
        "/etc/pve/cluster.conf"
        "/etc/pve/storage.cfg"
        "/etc/pve/user.cfg"
    )

    # Update simple configuration files
    for file in "${pve_single_files[@]}"; do
        if [[ -f "$file" ]]; then
            if ! sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" "$file"; then
                log_warning "Failed to update $file"
            else
                debug "Updated $file with new hostname"
            fi
        else
            debug "File $file not found, skipping"
        fi
    done

    # Update VM configuration files (handle case where directory is empty)
    for conf_dir in "/etc/pve/qemu-server" "/etc/pve/lxc" "/etc/pve/firewall"; do
        if [[ -d "$conf_dir" ]]; then
            # Check if any .conf files exist in the directory
            if compgen -G "$conf_dir/*.conf" >/dev/null 2>&1 || compgen -G "$conf_dir/*.fw" >/dev/null 2>&1; then
                debug "Processing config files in $conf_dir"
                # Use find to safely process files without glob expansion errors
                find "$conf_dir" -type f \( -name "*.conf" -o -name "*.fw" \) -exec sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" {} \; || {
                    log_warning "Failed to update some files in $conf_dir"
                }
            else
                debug "No configuration files found in $conf_dir"
            fi
        else
            debug "Directory $conf_dir not found, skipping"
        fi
    done

    # Check if we need to update /etc/hosts again (sometimes needed after systemd-hostnamed restart)
    if grep -q "$CURRENT_HOSTNAME" /etc/hosts; then
        log_warning "Hostname still present in /etc/hosts, updating again..."
        sed -i "s/$CURRENT_HOSTNAME/$NEW_NODE_NAME/g" /etc/hosts
    fi

    log_info "Node name changed to $NEW_NODE_NAME"

    # Suggest restarting services if needed
    log_warning "You may need to restart Proxmox services for all changes to take effect"
    log_warning "Consider running 'systemctl restart pveproxy pvedaemon' after verifying the configuration"

    return 0
}

# Get network configuration parameters from the user
get_network_params() {
    local confirm
    local mgmt_prefix
    local cluster_prefix
    local ceph_prefix
    local mgmt_oct
    local cluster_oct
    local ceph_oct

    # Confirm default subnets
    echo "Use default subnets?"
    echo "  VLAN1: 192.168.51.0/24"
    echo "  VLAN50: 10.50.10.0/24"
    echo "  VLAN55: 10.55.10.0/24"
    read -r -p "[Y/n]: " confirm
    confirm="${confirm,,}" # Convert to lowercase

    if [[ "$confirm" != "n" && "$confirm" != "no" ]]; then
        mgmt_prefix="192.168.51"
        cluster_prefix="10.50.10"
        ceph_prefix="10.55.10"
    else
        read -r -p "VLAN1 prefix: " mgmt_prefix
        read -r -p "VLAN50 prefix: " cluster_prefix
        read -r -p "VLAN55 prefix: " ceph_prefix
    fi

    # Validate subnets
    if [[ -z "$mgmt_prefix" ]]; then
        log_error "Subnet prefix for VLAN1 is undefined"
        return 1
    fi

    if [[ -z "$cluster_prefix" ]]; then
        log_error "Subnet prefix for VLAN50 is undefined"
        return 1
    fi

    if [[ -z "$ceph_prefix" ]]; then
        log_error "Subnet prefix for VLAN55 is undefined"
        return 1
    fi

    if ! is_valid_ip "$mgmt_prefix.1"; then
        log_error "Invalid subnet prefix for VLAN1"
        return 1
    fi

    if ! is_valid_ip "$cluster_prefix.1"; then
        log_error "Invalid subnet prefix for VLAN50"
        return 1
    fi

    if ! is_valid_ip "$ceph_prefix.1"; then
        log_error "Invalid subnet prefix for VLAN55"
        return 1
    fi

    # Get last octet of IPs
    read -r -p "Last octet for VLAN1: " mgmt_oct
    read -r -p "Last octet for VLAN50: " cluster_oct
    read -r -p "Last octet for VLAN55: " ceph_oct

    # Set global variables to make them available in the main function
    MGMT_IP="$mgmt_prefix.$mgmt_oct"
    CLUSTER_IP="$cluster_prefix.$cluster_oct"
    CEPH_IP="$ceph_prefix.$ceph_oct"

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
    MGMT_GW="$mgmt_prefix.1"
    DNS="$DEFAULT_DNS"

    # Step 1: Select Management Interface
    echo "Available network interfaces:"
    if ! mapfile -t interfaces < <(ip -br link show | awk '{print $1}'); then
        log_error "Failed to get network interfaces"
        return 1
    fi
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "No network interfaces detected. Aborting."
        return 1
    fi
    for i in "${!interfaces[@]}"; do
        echo "$((i + 1))) ${interfaces[$i]}"
    done
    read -r -p "Select Management Interface (1-${#interfaces[@]}): " mgmt_choice
    if ! [[ "$mgmt_choice" =~ ^[0-9]+$ ]] || [ "$mgmt_choice" -lt 1 ] || [ "$mgmt_choice" -gt ${#interfaces[@]} ]]; then
        log_error "Invalid selection for Management Interface"
        return 1
    fi
    MGMT_IFACE="${interfaces[$((mgmt_choice - 1))]}"

    # Step 2: Select First NIC for Bond
    echo "Available network interfaces (excluding $MGMT_IFACE):"
    mapfile -t interfaces < <(ip -br link show | awk '{print $1}' | grep -v "^$MGMT_IFACE$")
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "No additional interfaces available for bonding. Aborting."
        return 1
    fi
    for i in "${!interfaces[@]}"; do
        echo "$((i + 1))) ${interfaces[$i]}"
    done
    read -r -p "Select First NIC for Bond (1-${#interfaces[@]}): " bond1_choice
    if ! [[ "$bond1_choice" =~ ^[0-9]+$ ]] || [ "$bond1_choice" -lt 1 ] || [ "$bond1_choice" -gt ${#interfaces[@]} ]]; then
        log_error "Invalid selection for First NIC for Bond"
        return 1
    fi
    BOND_IFACE1="${interfaces[$((bond1_choice - 1))]}"

    # Step 3: Select Second NIC for Bond
    echo "Available network interfaces (excluding $MGMT_IFACE and $BOND_IFACE1):"
    mapfile -t interfaces < <(ip -br link show | awk '{print $1}' | grep -v -e "^$MGMT_IFACE$" -e "^$BOND_IFACE1$")
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "No additional interfaces available for second bond NIC. Aborting."
        return 1
    fi
    for i in "${!interfaces[@]}"; do
        echo "$((i + 1))) ${interfaces[$i]}"
    done
    read -r -p "Select Second NIC for Bond (1-${#interfaces[@]}): " bond2_choice
    if ! [[ "$bond2_choice" =~ ^[0-9]+$ ]] || [ "$bond2_choice" -lt 1 ] || [ "$bond2_choice" -gt ${#interfaces[@]} ]]; then
        log_error "Invalid selection for Second NIC for Bond"
        return 1
    fi
    BOND_IFACE2="${interfaces[$((bond2_choice - 1))]}"

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

    # Validate global variable assignment
    debug "Network configuration parameters:"
    debug "MGMT_IP: $MGMT_IP"
    debug "CLUSTER_IP: $CLUSTER_IP"
    debug "CEPH_IP: $CEPH_IP"
    debug "MGMT_IFACE: $MGMT_IFACE"
    debug "BOND_IFACE1: $BOND_IFACE1"
    debug "BOND_IFACE2: $BOND_IFACE2"

    return 0
}

# --- Main Script Execution ---

main() {
    # Main Menu
    local choice

    while true; do
        # Clear screen but handle TERM errors gracefully
        clear 2>/dev/null || printf "\033c" || echo -e "\n\n\n\n\n\n\n\n\n\n"

        echo "==============================="
        echo " Proxmox Network Recovery Tool"
        echo "==============================="
        echo " 1) Check Interfaces"
        echo " 2) Apply Linux bridge config"
        echo " 3) Change Hostname"
        echo " 4) Restore from backup"
        echo " 5) Configure IP Forwarding"
        echo " 6) Update Repositories"
        echo " 7) Rename Network Interfaces"
        echo " 8) Clean Orphaned LVM Volumes"
        echo " 9) Exit"
        echo

        read -r -p "Choose an option [1-9]: " choice

        case "$choice" in
        1)
            check_interfaces
            pause "Press Enter to continue..."
            ;;
        2)
            # Direct error handling pattern
            if ! get_network_params; then
                log_error "Failed to get network parameters. Aborting."
                pause "Press Enter to continue..."
                continue
            fi

            if ! apply_linux_config "$BOND_IFACE1" "$BOND_IFACE2" "$MGMT_IP" "$MGMT_NETMASK" \
                "$MGMT_GW" "$DNS" "$MGMT_IFACE" "$CLUSTER_IP" "$CEPH_IP"; then
                log_error "Failed to apply Linux bridge config. Review logs."
                pause "Press Enter to continue..."
            else
                log_info "Successfully applied Linux bridge configuration."
                pause "Press Enter to continue..."
            fi
            ;;
        3)
            change_hostname
            pause "Press Enter to continue..."
            ;;
        4)
            if ! restore_interfaces; then
                log_error "Failed to restore interfaces."
            else
                log_info "Network interfaces restored successfully."
            fi
            pause "Press Enter to continue..."
            ;;
        5)
            if ! configure_ip_forwarding; then
                log_error "Failed to configure IP forwarding."
            else
                log_info "IP forwarding configured successfully."
            fi
            pause "Press Enter to continue..."
            ;;
        6)
            if ! update_repos; then
                log_error "Failed to update repositories."
            else
                log_info "Repositories updated successfully."
            fi
            pause "Press Enter to continue..."
            ;;
        7)
            if ! rename_network_interfaces; then
                log_error "Failed to rename network interfaces."
            fi
            pause "Press Enter to continue..."
            ;;
        8)
            if ! find_orphaned_lvm; then
                log_error "Failed to clean orphaned LVM volumes."
            fi
            pause "Press Enter to continue..."
            ;;
        9)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid choice."
            sleep 1
            ;;
        esac
    done
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # This runs the main function but ensures proper cleanup on exit
    trap 'echo "Script terminated. Cleaning up..."; exit' INT TERM
    main "$@"
fi
