#!/bin/bash
# Script to remove the subscription nag from Proxmox VE UI
# This script can be run after Proxmox VE is installed

# Set up logging
LOG_FILE="/var/log/proxmox-nag-removal.log"

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR" "This script must be run as root"
    exit 1
fi

# Create log file if it doesn't exist
touch "$LOG_FILE" || {
    echo "ERROR: Cannot create log file"
    exit 1
}

log "INFO" "Starting Proxmox subscription nag removal"

# Method 1: Create APT hook to remove nag on package updates
log "INFO" "Creating APT hook to remove subscription nag"
cat > /etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke {
  "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; \
   if [ $? -eq 1 ]; then { \
     echo 'Removing subscription nag from UI...'; \
     sed -i '/data.status/{s/\\!//;s/Active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; \
   }; fi";
};
EOF

# Method 2: Directly modify the JavaScript file
log "INFO" "Directly modifying proxmoxlib.js to remove subscription nag"
if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
    # Create backup of the original file
    cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak
    
    # Apply the modification
    sed -i '/data.status/{s/\!//;s/Active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Successfully modified proxmoxlib.js"
    else
        log "ERROR" "Failed to modify proxmoxlib.js"
    fi
else
    log "WARNING" "proxmoxlib.js not found. Proxmox VE may not be installed yet."
fi

# Method 3: Configure repositories to use no-subscription sources
log "INFO" "Configuring repositories to use no-subscription sources"

# Disable enterprise repository
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    log "INFO" "Disabling enterprise repository"
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
fi

# Add community repository if it doesn't exist
if [ ! -f /etc/apt/sources.list.d/pve-community.list ]; then
    log "INFO" "Adding PVE community repository"
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-community.list
fi

# Add Ceph repository if it doesn't exist
if [ ! -f /etc/apt/sources.list.d/ceph-squid-community.list ]; then
    log "INFO" "Adding Ceph community repository"
    echo "deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription" > /etc/apt/sources.list.d/ceph-squid-community.list
fi

# Update package lists
log "INFO" "Updating package lists"
apt-get update

log "SUCCESS" "Subscription nag removal completed"
exit 0
