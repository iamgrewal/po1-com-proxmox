#!/bin/bash

PHASE_FILE="/root/.proxmox_install_phase"
export DOMAIN="po1.me" # Configurable domain variable

# Configurable DNS servers
export PRIMARY_DNS="192.168.51.1"
export SECONDARY_DNS="8.8.8.8"

# Check if we're continuing from a reboot
if [ -f "$PHASE_FILE" ]; then
    CURRENT_PHASE=$(cat "$PHASE_FILE")
else
    CURRENT_PHASE="1"
fi

choose_network_interface() {
  echo "Available network interfaces:"
  mapfile -t interfaces < <(ip -o -f inet addr show scope global | awk '{print $2}' | sort -u)

  if [ ${#interfaces[@]} -eq 0 ]; then
    echo "No active network interfaces with IP found."
    exit 1
  fi

  for i in "${!interfaces[@]}"; do
    iface="${interfaces[$i]}"
    ip_info=$(ip -o -f inet addr show "$iface" | awk '{print $4}')
    echo "  [$i] $iface - IP: $ip_info"
  done

  read -rp "Select the interface number to configure [0-${#interfaces[@]}]: " idx
  validate_interface_index() {
    local index=$1
    local max_index=$2
    if [[ -z "$index" || ! "$index" =~ ^[0-9]+$ || "$index" -lt 0 || "$index" -ge "$max_index" ]]; then
      return 1
    fi
    return 0
  }

  if ! validate_interface_index "$idx" "${#interfaces[@]}"; then
    echo "Invalid selection. Exiting."
    exit 1
  fi

  INTERFACE_NAME="${interfaces[$idx]}"
  echo "Selected interface: $INTERFACE_NAME"

  current_ip=$(ip -o -f inet addr show "$INTERFACE_NAME" | awk '{print $4}' | cut -d/ -f1)
  current_mask=$(ip -o -f inet addr show "$INTERFACE_NAME" | awk '{print $4}' | cut -d/ -f2)

  if [[ -z "$current_ip" ]]; then
    echo "No IPv4 address found on $INTERFACE_NAME. Exiting."
    exit 1
  fi

  echo "Current IP: $current_ip"
  echo "Current Subnet Mask (CIDR): $current_mask"

  # Ask user for IP customization
  base_ip=$(echo "$current_ip" | cut -d. -f1-3)
  default_octet=$(echo "$current_ip" | cut -d. -f4)
  read -rp "Enter new last octet for IP [$default_octet]: " last_octet
  last_octet="${last_octet:-$default_octet}"
  NODEIP="${base_ip}.${last_octet}"

  # CIDR to Netmask Conversion
  cidr_to_netmask() {
    local cidr=$1
    local i
    local mask=""
    for ((i=0; i<4; i++)); do
      if (( cidr >= 8 )); then
        (( mask += 255 ))
        cidr=$((cidr - 8))
      else
        mask+=$((256 - 2 ** (8 - cidr)))
        cidr=0
      fi
      [[ $i -lt 3 ]] && mask+=.
    done
    echo "$mask"
  while true; do
    read -rp "Enter new subnet mask [$SUBNETMASK]: " input_mask
    input_mask="${input_mask:-$SUBNETMASK}"
    if [[ "$input_mask" =~ ^(255\.(255\.(255\.(255|254|252|248|240|224|192|128|0)|0)|0)|0)\.0$ ]]; then
      SUBNETMASK="$input_mask"
      break
    else
      echo "Invalid subnet mask format. Please enter a valid subnet mask (e.g., 255.255.255.0)."
    fi
  done
  if [[ "$current_mask" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
    SUBNETMASK=$(cidr_to_netmask "$current_mask")
  else
    echo "Invalid CIDR value for subnet mask: $current_mask"
    exit 1
  fi
  elif [[ "$input_gateway" =~ ^((25[0-5]|2[0-4][0-9]|[0-1]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[0-1]?[0-9][0-9]?)$ ]]; then
    GATEWAY="$input_gateway"
  else
    echo "Invalid gateway format. Please enter a valid IP address (e.g., 192.168.1.1). Exiting."
    exit 1
  read -rp "Enter default gateway [$GATEWAY_DEFAULT]: " input_gateway
  if [[ -z "$input_gateway" ]]; then
    GATEWAY="$GATEWAY_DEFAULT"
  elif [[ "$input_gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    GATEWAY="$input_gateway"
  else
    echo "Invalid gateway format. Exiting."
    exit 1
  fi

  echo ""
  echo "✅ Network Configuration Summary:"
  echo "Interface      : $INTERFACE_NAME"
  echo "IP Address     : $NODEIP"
  echo "Subnet Mask    : $SUBNETMASK"
  echo "Default Gateway: $GATEWAY"
}


 

read -rp "Enter the node name: " NODENAME
[[ -z "$NODENAME" ]] && { echo "Node name cannot be empty."; exit 1; }

choose_network_interface

# Export for later use
NODE_NAME=$NODENAME
NODE_IP=$NODEIP
NETMASK=$SUBNETMASK
INTERFACE=$INTERFACE_NAME
BRIDGE="vmbr0"
GATEWAY=$GATEWAY

LOG_FILE="/var/log/proxmox_install.log"
# Validate and set NODENAME
if [[ -z "$NODENAME" ]]; then
  read -rp "Enter the node name: " NODENAME
  if [[ -z "$NODENAME" ]]; then
    echo "Error: Node name cannot be empty."
    exit 1
  fi
fi

NETWORK_BACKUP="/etc/network/interfaces.backup"
TEMP_NETWORK_CONFIG="/tmp/interfaces.temp"

# Logging function
# Purpose: Logs messages with a timestamp to both the console and a specified log file.
# Usage: Call the function with a string message as an argument, e.g., log "Your message here".
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
# Error handling function
# Purpose: Logs an error message, optionally rolls back the network configuration if a backup exists, and exits the script.
# Parameters:
#   $1 - The error message to log and display.
error_exit() {
  log "ERROR: $1"
  if [ -f "$NETWORK_BACKUP" ]; then
    log "Rolling back network configuration..."
    cp "$NETWORK_BACKUP" /etc/network/interfaces
    systemctl restart networking
    log "Network configuration rolled back."
  fi
  exit 1
}
  exit 1
}

case $CURRENT_PHASE in
    "1")
        log "Starting Phase 1: Pre-reboot installation"
        # Step 1: Preparation
        log "Starting Proxmox VE installation on $NODE_NAME ($NODE_IP)."
        log "Backing up network configuration..."
        cp /etc/network/interfaces "$NETWORK_BACKUP" || error_exit "Failed to backup network configuration."

        # Step 2: Repository Setup
        log "Setting up Proxmox Community repositories..."
        
        # Update main sources list
        SOURCES_URL="https://gist.githubusercontent.com/hakerdefo/5e1f51fa93ff37871b9ff738b05ba30f/raw/7b5a0ff76b7f963c52f2b33baa20d8c4033bce4d/sources.list"
        EXPECTED_CHECKSUM="d41d8cd98f00b204e9800998ecf8427e" # Replace with the actual checksum of the file
        TEMP_FILE="/tmp/sources.list"

        wget "$SOURCES_URL" -O "$TEMP_FILE" || error_exit "Failed to download sources.list"
        ACTUAL_CHECKSUM=$(md5sum "$TEMP_FILE" | awk '{print $1}')

        if [[ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
            error_exit "Checksum verification failed for sources.list"
        fi

        mv "$TEMP_FILE" /etc/apt/sources.list || error_exit "Failed to move sources.list to /etc/apt/"
        
        # Add PVE community repository
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-community.list || error_exit "Failed to add PVE community repo"
        
        # Add Ceph Squid community repository
        echo "deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription" > /etc/apt/sources.list.d/ceph-squid-community.list || error_exit "Failed to add Ceph community repo"
        
    
        
        log "Repository setup completed, updating package lists..."
        apt update && apt full-upgrade -y || error_exit "Failed to update package lists."

        # Step 3: Kernel Installation
        log "Installing Proxmox VE kernel..."
        apt install proxmox-default-kernel -y || error_exit "Failed to install Proxmox VE kernel."
        log "Rebooting to Proxmox VE kernel..."
        read -p "The system will reboot now. Please save your work and press Enter to continue..."
        echo "2" > "$PHASE_FILE"
        log "Phase 1 complete. System will reboot now."
        # read -p "Press Enter to reboot..."  # This line is unnecessary and can be removed
        reboot
        ;;
    "2")
        log "Starting Phase 2: Post-reboot installation"
        # Step 4: Package Installation
        #Update resolv.conf
        cat > /etc/systemd/resolved.conf.d/custom.conf <<EOF
[Resolve]
        Domains=po1.me
EOF
EOF

        systemctl restart systemd-resolved
        

        log "Installing Proxmox VE packages..."
        apt install proxmox-ve postfix open-iscsi chrony -y || error_exit "Failed to install Proxmox VE packages."
        log "Postfix and Chrony installed. Please configure them as needed."
        log "For Postfix configuration, refer to: https://www.postfix.org/BASIC_CONFIGURATION_README.html"
        log "For Chrony configuration, refer to: https://chrony.tuxfamily.org/doc/4.1/chrony.conf.html"

        # Step 5: Kernel Removal
        log "Removing Debian kernel..."
        apt remove linux-image-amd64 'linux-image-6.1*' -y || error_exit "Failed to remove Debian kernel."
        log "Updating GRUB configuration..."
        update-grub || error_exit "Failed to update GRUB."

        # Step 6: OS Prober Removal
        log "Removing os-prober..."
        apt remove os-prober -y || error_exit "Failed to remove os-prober."
        # Configure and install Postfix
        debconf-set-selections <<< "postfix postfix/mailname string $NODE_NAME"
        debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Local only'"
        apt-get install -y postfix || error_exit "Failed to install Postfix."

        # Install bridge-utils
        apt-get install -y bridge-utils || error_exit "Failed to install bridge-utils."
        debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Local only'"
        apt-get install -y postfix
        apt-get install -y bridge-utils || error_exit "Failed to install bridge-utils."
        # Create a temporary network configuration file
        log "Creating temporary network configuration file..."
        echo "Creating temporary network configuration file..."
        hostnamectl set-hostname "$NODE_NAME"
        echo "127.0.1.1 $NODE_NAME" >> /etc/hosts
        echo "$NODE_IP $NODE_NAME" >> /etc/hosts
        echo "$NODE_IP $NODE_NAME.local $NODE_NAME" >> /etc/hosts
        apt install openvswitch-switch -y || error_exit "Failed to install Open vSwitch."
        # Check if the interface exists
        if ! ip link show "${INTERFACE}" &>/dev/null; then
            error_exit "Network interface '${INTERFACE}' does not exist."
        fi
        # Check if the interface is up
        if ! ip link show "${INTERFACE}" | grep -q "state UP"; then
            error_exit "Network interface '${INTERFACE}' is not up."
        fi
                             
        cat <<EOF > "$TEMP_NETWORK_CONFIG"
    auto lo
    iface lo inet loopback

    auto $INTERFACE
    iface $INTERFACE inet manual
        ovs_type OVSPort
        ovs_bridge vmbr0
        ovs_mtu 9000

    auto vmbr0
    iface vmbr0 inet manual
        ovs_type OVSBridge
        ovs_mtu 9000
        ovs_ports $INTERFACE vmbr0.0

    auto vmbr0.0
    iface vmbr0.0 inet static
        ovs_type OVSIntPort
        ovs_bridge vmbr0
        ovs_options tag=0
        address $NODE_IP
        netmask $NETMASK
        gateway $GATEWAY
        ovs_mtu 9000
EOF
        SCRIPT_DIR="/tmp/proxmox_scripts"
        mkdir -p "$SCRIPT_DIR"

        download_script() {
          local url=$1
          local filename=$2
          if [ ! -f "$SCRIPT_DIR/$filename" ]; then
            log "Downloading $filename..."
            curl -sL "$url" -o "$SCRIPT_DIR/$filename" || log "Failed to download $filename"
          fi
        }

        KERNEL_CLEAN_SCRIPT_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/kernel-clean.sh"
        CPU_SCALING_SCRIPT_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/scaling-governor.sh"
        POST_INSTALL_SCRIPT_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/post-pve-install.sh"
        PROXMOX_VE_PROCESSOR_MICROCODE_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/microcode.sh"

        download_script "$KERNEL_CLEAN_SCRIPT_URL" "kernel-clean.sh"
        download_script "$CPU_SCALING_SCRIPT_URL" "scaling-governor.sh"
        download_script "$POST_INSTALL_SCRIPT_URL" "post-pve-install.sh"
        download_script "$PROXMOX_VE_PROCESSOR_MICROCODE_URL" "microcode.sh"

        log "Running kernel cleaning script"
        bash "$SCRIPT_DIR/kernel-clean.sh" || log "Kernel cleaning script failed"

        log "Running CPU scaling script"
        bash "$SCRIPT_DIR/scaling-governor.sh" || log "CPU scaling script failed"

        log "Running post install script"
        bash "$SCRIPT_DIR/post-pve-install.sh" || log "Post install script failed"

        log "Running microcode script"
        bash "$SCRIPT_DIR/microcode.sh" || log "Microcode script failed"
          bash -c "$(curl -sL $POST_INSTALL_SCRIPT_URL)" || log "Post install script failed"
        else
          log "Post install script URL is not available"
        fi
        PROXMOX_VE_PROCESSOR_MICROCODE_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/microcode.sh"
        log "Running microcode script"
        if curl --output /dev/null --silent --head --fail "$PROXMOX_VE_PROCESSOR_MICROCODE_URL"; then
          bash -c "$(curl -sL $PROXMOX_VE_PROCESSOR_MICROCODE_URL)" || log "Microcode script failed"
        if ! sudo ls /boot/vmlinuz-*proxmox* &>/dev/null; then
          error_exit "Proxmox kernel installation failed or not found."
        fi
        if ! ls /boot/vmlinuz-*proxmox* &>/dev/null; then
          error_exit "Proxmox kernel installation failed or not found."
        fi

        #
        if [ -f "$PHASE_FILE" ]; then
            rm "$PHASE_FILE"
        fi
        log "Proxmox VE installation completed."
        ;;
        
esac
