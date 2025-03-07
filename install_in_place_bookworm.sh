#!/bin/bash

PHASE_FILE="/root/.proxmox_install_phase"

# Check if we're continuing from a reboot
if [ -f "$PHASE_FILE" ]; then
    CURRENT_PHASE=$(cat "$PHASE_FILE")
else
    CURRENT_PHASE="1"
fi

# Variables
NODE_NAME="node4.po1.me"
NODE_IP="192.168.51.94"
NETMASK="255.255.255.0"
GATEWAY="192.168.51.1"
INTERFACE="enp5s0f1"
BRIDGE="vmbr0"
LOG_FILE="/var/log/proxmox_install.log"
NETWORK_BACKUP="/etc/network/interfaces.backup"
TEMP_NETWORK_CONFIG="/tmp/interfaces.temp"

# Logging function
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Error handling function
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

case $CURRENT_PHASE in
    "1")
        log "Starting Phase 1: Pre-reboot installation"
        # Step 1: Preparation
        log "Starting Proxmox VE installation on $NODE_NAME ($NODE_IP)."
        log "Backing up network configuration..."
        cp /etc/network/interfaces "$NETWORK_BACKUP" || error_exit "Failed to backup network configuration."

        # Step 2: Repository Setup
        log "Adding Proxmox VE repository key..."
        wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg || error_exit "Failed to download repository key."
        sha512sum /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg || error_exit "Failed to verify repository key."
        log "Updating package lists..."
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

        # Step 7: Network Configuration
        log "Configuring network bridge $BRIDGE..."
        cat <<EOF > "$TEMP_NETWORK_CONFIG"
auto lo
iface lo inet loopback

iface $INTERFACE inet manual

auto $BRIDGE
iface $BRIDGE inet static
        address $NODE_IP
        netmask $NETMASK
        gateway $GATEWAY
        bridge-ports $INTERFACE
        bridge-stp off
        bridge-fd 0
EOF
        cp "$TEMP_NETWORK_CONFIG" /etc/network/interfaces || error_exit "Failed to configure network bridge."
        rm "$TEMP_NETWORK_CONFIG"
        systemctl restart networking || error_exit "Failed to restart networking."
        log "Network bridge $BRIDGE configured."

        # Step 8: Subscription Key (Optional)
        log "Removing installation repository..."
        rm /etc/apt/sources.list.d/pve-install-repo.list || log "Failed to remove install repository. This may not be present."

        # Step 9: Kernel Clean (Optional)
        KERNEL_CLEAN_SCRIPT_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/kernel-clean.sh"
        log "Running kernel cleaning script"
        if curl --output /dev/null --silent --head --fail "$KERNEL_CLEAN_SCRIPT_URL"; then
          bash -c "$(curl -sL $KERNEL_CLEAN_SCRIPT_URL)" || log "Kernel cleaning script failed"
        else
          log "Kernel cleaning script URL is not available"
        fi
        CPU_SCALING_SCRIPT_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/scaling-governor.sh"
        log "Running cpu scaling script"
        if curl --output /dev/null --silent --head --fail "$CPU_SCALING_SCRIPT_URL"; then
          bash -c "$(curl -sL $CPU_SCALING_SCRIPT_URL)" || log "CPU scaling script failed"
        else
          log "CPU scaling script URL is not available"
        fi

        POST_INSTALL_SCRIPT_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/post-pve-install.sh"
        log "Running post install script"
        if curl --output /dev/null --silent --head --fail "$POST_INSTALL_SCRIPT_URL"; then
          bash -c "$(curl -sL $POST_INSTALL_SCRIPT_URL)" || log "Post install script failed"
        else
          log "Post install script URL is not available"
        fi
        PROXMOX_VE_PROCESSOR_MICROCODE_URL="https://github.com/community-scripts/ProxmoxVE/raw/main/misc/microcode.sh"
        log "Running microcode script"
        if curl --output /dev/null --silent --head --fail "$PROXMOX_VE_PROCESSOR_MICROCODE_URL"; then
          bash -c "$(curl -sL $PROXMOX_VE_PROCESSOR_MICROCODE_URL)" || log "Microcode script failed"
        else
          log "Microcode script URL is not available"
        fi
        #
        rm "$PHASE_FILE"
        log "Proxmox VE installation completed."
        ;;
esac
