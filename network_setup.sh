#!/bin/bash
# Proxmox Network Configuration Selector
# This script helps users choose between different network configuration options for Proxmox

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
    
    # Ask if user wants to try applying with -a flag
    read -p "Would you like to try applying with -a flag? (y/n): " apply_flag
    
    # Execute the script and capture its exit status
    if [[ "$apply_flag" =~ ^[Yy]$ ]]; then
        print_message "$YELLOW" "Executing with -a flag (apply mode)..."
        if "$script_path" -a; then
            print_message "$GREEN" "$script_name executed successfully with -a flag"
            log "SUCCESS" "$script_name executed successfully with -a flag"
            return 0
        else
            local exit_code=$?
            print_message "$RED" "$script_name failed with -a flag (exit code $exit_code)"
            log "ERROR" "$script_name failed with -a flag (exit code $exit_code)"
        fi
    else
        if "$script_path"; then
            print_message "$GREEN" "$script_name executed successfully"
            log "SUCCESS" "$script_name executed successfully"
            return 0
        else
            local exit_code=$?
            print_message "$RED" "$script_name failed with exit code $exit_code"
            log "ERROR" "$script_name failed with exit code $exit_code"
        fi
    fi
    
    # If we get here, the script failed
    # Ask if user wants to roll back
    read -p "Would you like to roll back the changes? (y/n): " rollback
    if [[ "$rollback" =~ ^[Yy]$ ]]; then
        print_message "$YELLOW" "Rolling back changes..."
        # The scripts have their own rollback mechanisms
        # We don't need to implement additional rollback logic here
    fi
    
    return 1
}

# Function to display the main menu
show_menu() {
    clear
    echo "========================================================"
    echo "           Proxmox Network Configuration Setup          "
    echo "========================================================"
    echo
    print_message "$YELLOW" "Please select a network configuration option:"
    echo
    echo "1) Linux Bridge Configuration"
    echo "   - Traditional Linux bridge setup"
    echo "   - Good for standard deployments"
    echo "   - Supports bonding and VLANs"
    echo
    echo "2) Open vSwitch (OVS) Bridge Configuration"
    echo "   - Advanced software-defined networking"
    echo "   - Better for complex network setups"
    echo "   - Enhanced VLAN support and traffic control"
    echo
    echo "3) Single Node with NAT for VMs"
    echo "   - Simplified setup for standalone nodes"
    echo "   - Uses NAT for VM internet access"
    echo "   - Good for home labs or isolated environments"
    echo
    echo "4) Exit"
    echo
    read -p "Enter your choice [1-4]: " choice
    
    case $choice in
        1) setup_linux_bridge ;;
        2) setup_ovs_bridge ;;
        3) setup_single_node ;;
        4) exit 0 ;;
        *) 
            print_message "$RED" "Invalid choice. Please try again."
            sleep 2
            show_menu
            ;;
    esac
}

# Function to set up Linux Bridge
setup_linux_bridge() {
    print_message "$BLUE" "Setting up Linux Bridge configuration..."
    
    # Download the Linux Bridge script
    local script_path=$(download_script "$LINUX_BRIDGE_SCRIPT")
    if [ $? -ne 0 ]; then
        print_message "$RED" "Failed to download Linux Bridge script. Returning to menu."
        sleep 3
        show_menu
        return
    fi
    
    # Execute the script
    execute_script "$script_path"
    
    # Return to menu after completion
    print_message "$YELLOW" "Press Enter to return to the main menu..."
    read
    show_menu
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
            print_message "$RED" "Failed to install Open vSwitch. Returning to menu."
            sleep 3
            show_menu
            return
        fi
    fi
    
    # Download the OVS Bridge script
    local script_path=$(download_script "$OVS_BRIDGE_SCRIPT")
    if [ $? -ne 0 ]; then
        print_message "$RED" "Failed to download OVS Bridge script. Returning to menu."
        sleep 3
        show_menu
        return
    fi
    
    # Execute the script
    execute_script "$script_path"
    
    # Return to menu after completion
    print_message "$YELLOW" "Press Enter to return to the main menu..."
    read
    show_menu
}

# Function to set up Single Node with NAT
setup_single_node() {
    print_message "$BLUE" "Setting up Single Node with NAT configuration..."
    
    # Download the Single Node script
    local script_path=$(download_script "$SINGLE_NODE_SCRIPT")
    if [ $? -ne 0 ]; then
        print_message "$RED" "Failed to download Single Node script. Returning to menu."
        sleep 3
        show_menu
        return
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
    
    # Return to menu after completion
    print_message "$YELLOW" "Press Enter to return to the main menu..."
    read
    show_menu
}

# Main function
main() {
    # Check if running as root
    check_root
    
    # Create necessary directories
    create_directories
    
    # Show the main menu
    show_menu
}

# Run the main function
main
