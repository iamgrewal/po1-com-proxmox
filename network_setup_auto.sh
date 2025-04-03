#!/bin/bash
# Proxmox Network Configuration Selector - Automated Version
# This script configures network options for Proxmox without requiring user input

# Set strict error handling
set -e

# ANSI color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# GitHub repository information
REPO_OWNER="iamgrewal"
REPO_NAME="po1-com-proxmox"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/refs/heads/${BRANCH}"

# Script filenames
LINUX_BRIDGE_SCRIPT="proxmox-3-nic-setup.sh"
OVS_BRIDGE_SCRIPT="ovs-bridge-setup.sh"
SINGLE_NODE_SCRIPT="network_configration_for_single_node_VMS_on_NAT.sh"
IP_RANGE_SCRIPT="network-addiprange.sh"

# Temporary directory for downloaded scripts
TEMP_DIR="/tmp/proxmox-network-setup"

# Log file
LOG_FILE="/var/log/proxmox-network-setup.log"

# Default configuration option (1=Linux Bridge, 2=OVS Bridge, 3=Single Node with NAT)
NETWORK_CONFIG=${1:-1}

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to display colored messages
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_message "$RED" "Error: This script must be run as root"
        exit 1
    fi
}

# Function to create necessary directories
create_directories() {
    mkdir -p "$TEMP_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# Function to download a script from GitHub
download_script() {
    local script_name="$1"
    local output_path="$TEMP_DIR/$script_name"
    local script_url="$BASE_URL/$script_name"
    
    print_message "$BLUE" "Downloading $script_name from repository..."
    
    if curl -s -o "$output_path" "$script_url"; then
        chmod +x "$output_path"
        print_message "$GREEN" "Successfully downloaded $script_name"
        echo "$output_path"
    else
        print_message "$RED" "Failed to download $script_name"
        return 1
    fi
}

# Function to execute a script with proper error handling
execute_script() {
    local script_path="$1"
    local script_name=$(basename "$script_path")
    
    print_message "$BLUE" "Executing $script_name..."
    log "INFO" "Executing $script_name"
    
    # Execute the script with -a flag (apply mode)
    print_message "$YELLOW" "Executing with -a flag (apply mode)..."
    if "$script_path" -a; then
        print_message "$GREEN" "$script_name executed successfully with -a flag"
        log "SUCCESS" "$script_name executed successfully with -a flag"
        return 0
    else
        local exit_code=$?
        print_message "$RED" "$script_name failed with -a flag (exit code $exit_code)"
        log "ERROR" "$script_name failed with -a flag (exit code $exit_code)"
        return 1
    fi
}

# Function to set up Linux Bridge
setup_linux_bridge() {
    print_message "$BLUE" "Setting up Linux Bridge configuration..."
    
    # Download the Linux Bridge script
    local script_path=$(download_script "$LINUX_BRIDGE_SCRIPT")
    if [ $? -ne 0 ]; then
        print_message "$RED" "Failed to download Linux Bridge script."
        return 1
    fi
    
    # Execute the script
    execute_script "$script_path"
    return $?
}

# Function to set up OVS Bridge
setup_ovs_bridge() {
    print_message "$BLUE" "Setting up Open vSwitch Bridge configuration..."
    
    # Check if OVS is installed
    if ! command -v ovs-vsctl &> /dev/null; then
        print_message "$YELLOW" "Open vSwitch is not installed. Installing now..."
        apt-get update
        apt-get install -y openvswitch-switch
        
        if [ $? -ne 0 ]; then
            print_message "$RED" "Failed to install Open vSwitch."
            return 1
        fi
    fi
    
    # Download the OVS Bridge script
    local script_path=$(download_script "$OVS_BRIDGE_SCRIPT")
    if [ $? -ne 0 ]; then
        print_message "$RED" "Failed to download OVS Bridge script."
        return 1
    fi
    
    # Execute the script
    execute_script "$script_path"
    return $?
}

# Function to set up Single Node with NAT
setup_single_node() {
    print_message "$BLUE" "Setting up Single Node with NAT configuration..."
    
    # Download the Single Node script
    local script_path=$(download_script "$SINGLE_NODE_SCRIPT")
    if [ $? -ne 0 ]; then
        print_message "$RED" "Failed to download Single Node script."
        return 1
    fi
    
    # Download the IP Range script (needed by Single Node script)
    local ip_range_script_path=$(download_script "$IP_RANGE_SCRIPT")
    if [ $? -ne 0 ]; then
        print_message "$YELLOW" "Warning: Failed to download IP Range script. Continuing anyway."
    else
        # Copy the IP Range script to the same directory as the Single Node script
        cp "$ip_range_script_path" "$(dirname "$script_path")/"
    fi
    
    # Execute the script
    execute_script "$script_path"
    return $?
}

# Main function
main() {
    # Check if running as root
    check_root
    
    # Create necessary directories
    create_directories
    
    # Process based on configuration option
    case $NETWORK_CONFIG in
        1)
            print_message "$BLUE" "Selected Linux Bridge configuration"
            setup_linux_bridge
            ;;
        2)
            print_message "$BLUE" "Selected Open vSwitch Bridge configuration"
            setup_ovs_bridge
            ;;
        3)
            print_message "$BLUE" "Selected Single Node with NAT configuration"
            setup_single_node
            ;;
        *)
            print_message "$RED" "Invalid configuration option: $NETWORK_CONFIG. Using default (Linux Bridge)."
            setup_linux_bridge
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        print_message "$GREEN" "Network configuration completed successfully."
        exit 0
    else
        print_message "$RED" "Network configuration failed."
        exit 1
    fi
}

# Run the main function
main
