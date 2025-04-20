#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ENV_FILE="./network.env"
LOG_FILE="/var/log/apply-proxmox-network.log"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') :: $1" | tee -a "$LOG_FILE"
}

log_header() {
    echo -e "\n===== $1 =====" | tee -a "$LOG_FILE"
}

# Ensure running as root
if [[ "$(id -u)" -ne 0 ]]; then
    log "❌ This script must be run as root"
    exit 1
fi

# Load env file
if [[ ! -f "$ENV_FILE" ]]; then
    log "❌ Missing environment file: $ENV_FILE"
    exit 1
fi

log_header "Loading environment variables"
set -a
source "$ENV_FILE"
set +a

# Validate required variables
REQUIRED_VARS=(HOSTF IFACE1 IFACE2 IFACE3 IP1 IP10 IP20 IP30 IP40 GATEWAY DNS_SERVERS DOMAIN)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "❌ Required variable $var is not set in $ENV_FILE"
        exit 1
    fi
done

if [[ "${WIRELESS_ENABLED:-false}" == "true" ]]; then
    WIRELESS_VARS=(WIRELESS_IFACE IP50 WIFI_SSID WIFI_PSK)
    for var in "${WIRELESS_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log "❌ Wireless is enabled but $var is not set"
            exit 1
        fi
    done
fi

# Set hostname
log_header "Setting hostname"
hostnamectl set-hostname "$HOSTF"
log "✅ Hostname set to $HOSTF"

# Update /etc/hosts
log_header "Updating /etc/hosts"
cat <<EOF > /etc/hosts
127.0.0.1       localhost
${IP1}          ${HOSTF}.${DOMAIN} ${HOSTF}
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
log "✅ /etc/hosts updated"

# Backup existing interfaces file
log_header "Backing up current /etc/network/interfaces"
cp /etc/network/interfaces "/etc/network/interfaces.bak.${DATE_STAMP}"
log "✅ Backup saved as interfaces.bak.${DATE_STAMP}"

# Generate new interfaces file
log_header "Writing new /etc/network/interfaces"

cat <<EOF > /etc/network/interfaces
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ${IFACE1}
iface ${IFACE1} inet manual
    ovs_type OVSPort
    ovs_bridge vmbr0
    ovs_mtu 1500

auto vmbr0
allow-ovs vmbr0
iface vmbr0 inet manual
    ovs_type OVSBridge
    ovs_ports ${IFACE1} vmbr0.0
    ovs_mtu 1500
    ovs_options other_config:rstp-enable=true other_config:rstp-priority=32768

auto vmbr0.0
allow-ovs vmbr0.0
iface vmbr0.0 inet static
    ovs_type OVSIntPort
    ovs_bridge vmbr0
    address ${IP1}
    netmask 255.255.255.0
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVERS}
    ovs_options tag=0
    ovs_mtu 1500
    ovs_extra set interface vmbr0.0 external-ids:iface-id=$(hostname -s)

auto ${IFACE2}
iface ${IFACE2} inet manual
    ovs_type OVSPort
    ovs_bridge vmbr1
    ovs_mtu 9000

auto vmbr1
allow-ovs vmbr1
iface vmbr1 inet manual
    ovs_type OVSBridge
    ovs_ports ${IFACE2} vmbr1.10 vmbr1.20
    ovs_mtu 9000
    ovs_options other_config:rstp-enable=true other_config:rstp-priority=32768

auto vmbr1.10
allow-ovs vmbr1.10
iface vmbr1.10 inet static
    ovs_type OVSIntPort
    ovs_bridge vmbr1
    address ${IP10}
    netmask 255.255.255.0
    ovs_options tag=10
    ovs_mtu 9000
    ovs_extra set interface vmbr1.10 external-ids:iface-id=$(hostname -s)

auto vmbr1.20
allow-ovs vmbr1.20
iface vmbr1.20 inet static
    ovs_type OVSIntPort
    ovs_bridge vmbr1
    address ${IP20}
    netmask 255.255.255.0
    ovs_options tag=20
    ovs_mtu 9000
    ovs_extra set interface vmbr1.20 external-ids:iface-id=$(hostname -s)

auto ${IFACE3}
iface ${IFACE3} inet manual
    ovs_type OVSPort
    ovs_bridge vmbr2
    ovs_mtu 9000

auto vmbr2
allow-ovs vmbr2
iface vmbr2 inet manual
    ovs_type OVSBridge
    ovs_ports ${IFACE3} vmbr2.30 vmbr2.40
    ovs_mtu 9000
    ovs_options other_config:rstp-enable=true other_config:rstp-priority=32768

auto vmbr2.30
allow-ovs vmbr2.30
iface vmbr2.30 inet static
    ovs_type OVSIntPort
    ovs_bridge vmbr2
    address ${IP30}
    netmask 255.255.255.0
    ovs_options tag=30
    ovs_mtu 9000
    ovs_extra set interface vmbr2.30 external-ids:iface-id=$(hostname -s)

auto vmbr2.40
allow-ovs vmbr2.40
iface vmbr2.40 inet static
    ovs_type OVSIntPort
    ovs_bridge vmbr2
    address ${IP40}
    netmask 255.255.255.0
    ovs_options tag=40
    ovs_mtu 9000
    ovs_extra set interface vmbr2.40 external-ids:iface-id=$(hostname -s)

EOF

# Append wireless block if enabled
if [[ "${WIRELESS_ENABLED:-false}" == "true" ]]; then
cat <<EOF >> /etc/network/interfaces

# Optional Wireless Interface
auto ${WIRELESS_IFACE}
iface ${WIRELESS_IFACE} inet static
    address ${IP50}
    netmask 255.255.255.0
    dns-nameservers ${DNS_SERVERS}
    wpa-ssid "${WIFI_SSID}"
    wpa-psk "${WIFI_PSK}"
EOF
    log "✅ Wireless block added for ${WIRELESS_IFACE}"
fi

# Disable Proxmox network overwrite
touch /etc/network/.pve-ignore-interfaces

# Validate network config
log_header "Validating interfaces config"
if ifquery --list --allow=auto >/dev/null 2>&1; then
    log "✅ Network config syntax looks good."
else
    log "❌ Validation failed. Check /etc/network/interfaces."
    exit 1
fi

# Reload networking
log_header "Applying new network configuration"
if command -v ifreload >/dev/null 2>&1; then
    ifreload -a
else
    systemctl restart networking || service networking restart || log "⚠️ Manual restart required."
fi

# Restart essential Proxmox services
log_header "Restarting Proxmox services"
systemctl restart pveproxy pvedaemon pve-cluster corosync || true

# Print final network state
log_header "Final network state"
ip -br a | tee -a "$LOG_FILE"

log_header "OVS status"
ovs-vsctl show | tee -a "$LOG_FILE"

log "✅ Network successfully applied!"
log "🌐 Access Proxmox Web UI at: https://${IP1}:8006"

disable_os_prober_and_adjust_grub() {
    echo "[+] Checking boot configuration..."

    IS_EFI=false
    IS_ZFS=false

    # Check if system is using EFI
    if [[ -d /sys/firmware/efi ]]; then
        IS_EFI=true
        echo "✅ Detected EFI Bootloader"
    else
        echo "ℹ️ Boot mode: Legacy BIOS"
    fi

    # Check if ZFS is in use for root
    if findmnt -n -o FSTYPE / | grep -q zfs; then
        IS_ZFS=true
        echo "✅ Detected ZFS root filesystem"
    else
        echo "ℹ️ Root filesystem is not ZFS"
    fi

    echo "[+] Removing os-prober (if installed)..."
    apt remove --purge -y os-prober || echo "os-prober already removed or not installed"

    echo "[+] Setting GRUB_DISABLE_OS_PROBER=true in /etc/default/grub..."
    if ! grep -q "^GRUB_DISABLE_OS_PROBER=true" /etc/default/grub; then
        echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
    fi

    # Apply extra ZFS or EFI flags
    if $IS_ZFS; then
        echo "[+] Adding ZFS-specific GRUB flags..."
        sed -i 's/^#GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet root=ZFS=rpool\/ROOT\/proxmox"/' /etc/default/grub
    fi

    if $IS_EFI; then
        echo "[+] Ensuring GRUB uses EFI mode"
        grub_target="x86_64-efi"
    else
        grub_target="i386-pc"
    fi

    echo "[+] Updating GRUB configuration..."
    update-grub

    echo "✅ GRUB updated successfully for ${IS_EFI:+EFI} ${IS_ZFS:++ ZFS}"
}
disable_os_prober_and_adjust_grub


log_header "Check if config is ok"
log_header "Validating /etc/network/interfaces syntax before applying..."
if ifquery --list --allow=auto >/dev/null 2>&1; then
    log_header "Network config syntax looks good."
else
    log_header "Network config validation failed. Aborting reload to prevent lockout."
    exit 1
fi

echo "ifreload -a to be applied now"
# Apply the configuration
# Check if the 'ifreload' command is available to reload network interfaces
if command -v ifreload >/dev/null 2>&1; then
    ifreload -a
else
    # If 'ifreload' is not found, use traditional networking restart methods
    if command -v systemctl &> /dev/null; then
        sudo systemctl restart networking
    elif command -v service &> /dev/null; then
        sudo service networking restart
    else
        echo "Error: Unable to determine init system. Please restart networking manually."
        exit 1
    fi
fi
exit 0
