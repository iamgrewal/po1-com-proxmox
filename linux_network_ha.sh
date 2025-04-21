#!/bin/bash

set -e

# === Suggest NICs ===
list="/sys/class/net/*"
CURRENTNICNAMES=$(for nic in $list; do cat "${nic}/uevent"; done | grep "INTERFACE=en" | awk -F= '{print $2}' | tr '\n' ' ')
WIRELESSNICS=$(for nic in $list; do cat "${nic}/uevent"; done | grep "INTERFACE=wl" | awk -F= '{print $2}' | tr '\n' ' ')

# === Basic Setup ===
HOSTF1=$HOSTNAME
read -p "Enter the hostname (currently: $HOSTF1), change? (y/n): " CHANGE_HOSTNAME
if [ "$CHANGE_HOSTNAME" == "y" ]; then
    read -p "Enter the new hostname: " HOSTF
    hostnamectl set-hostname "$HOSTF"
    echo "✅ Hostname changed to $HOSTF"
else
    echo "ℹ️ Hostname not changed"
fi

# === Bond Setup ===
echo "Available interfaces: $CURRENTNICNAMES"
read -p "Enter the first interface for bonding: " IFACE1
read -p "Enter the second interface for bonding: " IFACE2

# === IP Assignments ===
read -p "Enter IP last octet for mgmt (192.168.0.X): " IP1L
read -p "Enter IP last octet for VLAN10: " IP10L
read -p "Enter IP last octet for VLAN20: " IP20L
read -p "Enter IP last octet for VLAN30: " IP30L
read -p "Enter IP last octet for VLAN40: " IP40L

# === Networking Constants ===
GATEWAY='192.168.0.1'
DNS_SERVERS='192.168.0.1 172.64.36.1 172.64.36.2'
DOMAIN='po1.me'

IP1="192.168.0.${IP1L}"
IP10="10.10.10.${IP10L}"
IP20="10.10.20.${IP20L}"
IP30="10.10.30.${IP30L}"
IP40="10.10.40.${IP40L}"

# === Optional WiFi ===
read -p "Enable Wireless? (true/false): " WIRELESS_ENABLED
if [[ "$WIRELESS_ENABLED" == "true" ]]; then
  echo "Available wireless interfaces: $WIRELESSNICS"
  read -p "Enter wireless interface: " WIRELESS_IFACE
  read -p "Enter WiFi IP last octet: " IP50L
  read -p "Enter WiFi SSID: " WIFI_SSID
  read -p "Enter WiFi PSK: " WIFI_PSK
  IP50="192.168.0.${IP50L}"
fi

# === Ensure ifupdown2 is installed ===
ensure_ifupdown() {
  if [ -x "$(command -v ifup)" ] && [ -x "$(command -v ifdown)" ]; then
    echo "✅ ifup/ifdown available."
    return 0
  fi

  echo "📦 Installing ifupdown2..."
  apt update && apt install -y ifupdown2
}
ensure_ifupdown

# === Backup Existing Config ===
cp /etc/network/interfaces /etc/network/interfaces.backup-$(date +%Y%m%d%H%M%S)

# === Generate New Network Config ===
cat <<EOF > /etc/network/interfaces
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# === Bonded NICs for redundancy (balance-alb) ===
auto bond0
iface bond0 inet manual
    bond-slaves ${IFACE1} ${IFACE2}
    bond-miimon 100
    bond-mode balance-alb
    bond-xmit-hash-policy layer2+3
    mtu 9000

# === Main VLAN-aware bridge (for mgmt + tagged VLANs) ===
auto vmbr0
iface vmbr0 inet static
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
    address ${IP1}
    netmask 255.255.255.0
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVERS}
    dns-search ${DOMAIN}
    mtu 9000

# === VLAN Interfaces ===
auto vmbr0.10
iface vmbr0.10 inet static
    address ${IP10}
    netmask 255.255.255.0
    vlan-id 10
    vlan-raw-device bond0
    mtu 9000

auto vmbr0.20
iface vmbr0.20 inet static
    address ${IP20}
    netmask 255.255.255.0
    vlan-id 20
    vlan-raw-device bond0
    mtu 9000

auto vmbr0.30
iface vmbr0.30 inet static
    address ${IP30}
    netmask 255.255.255.0
    vlan-id 30
    vlan-raw-device bond0
    mtu 9000

auto vmbr0.40
iface vmbr0.40 inet static
    address ${IP40}
    netmask 255.255.255.0
    vlan-id 40
    vlan-raw-device bond0
    mtu 9000
EOF

# === Wireless Config (Optional) ===
if [[ "$WIRELESS_ENABLED" == "true" ]]; then
cat <<EOF >> /etc/network/interfaces

# === Wireless Interface ===
auto ${WIRELESS_IFACE}
allow-hotplug ${WIRELESS_IFACE}
iface ${WIRELESS_IFACE} inet static
    address ${IP50}
    netmask 255.255.255.0
    dns-nameservers ${DNS_SERVERS}
    wpa-ssid "${WIFI_SSID}"
    wpa-psk "${WIFI_PSK}"
EOF
fi

# === Disable Proxmox auto network overwrite ===
touch /etc/network/.pve-ignore-interfaces

echo "✅ Network configuration updated. Reboot or restart networking to apply changes."
