#!/bin/bash

# Validate hostname input
if [[ -z "$1" || ! "$1" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "Error: Invalid hostname provided. Usage: $0 <hostname> [domain]"
    exit 1
fi
MYHOSTNAME="$1"
DOMAIN="${2:-po1.me}" # Use the second argument if provided, otherwise default to 'po1.me'

# Basic sanity check for hostname and domain
if [[ -z "$MYHOSTNAME" || -z "$DOMAIN" ]]; then
    echo "Error: MYHOSTNAME or DOMAIN is empty."
    exit 1
fi

# Set the system hostname
hostnamectl set-hostname "$MYHOSTNAME"

# Get the IPv4 address of eth0 (consider making this more dynamic)
MYIP=$(ip -4 addr show eth0 | grep -oP 'inet\s+\K[\d.]+' || true)
export MYIP

# Add hostname and domain entries to /etc/hosts if they don't exist
if [[ -n "${MYHOSTNAME}" ]]; then
    if ! grep -q "^127.0.0.1[[:space:]]\+$MYHOSTNAME" /etc/hosts || ! grep -q "^127.0.1.1[[:space:]]\+$MYHOSTNAME\.$DOMAIN" /etc/hosts; then
        cat <<EOF >> /etc/hosts
127.0.0.1 ${MYHOSTNAME}
127.0.1.1 ${MYHOSTNAME}.${DOMAIN}
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF
    else
        echo "Warning: Hostname entries for ${MYHOSTNAME} already exist in /etc/hosts. Skipping."
    fi
else
    echo "Error: MYHOSTNAME is empty. Exiting without modifying /etc/hosts."
    exit 1
fi

# Array of static host entries
declare -A static_hosts=(
  ["192.168.0.2"]="synology.po1.me synology"
  ["192.168.0.108"]="devbox.po1.me devbox"
  ["192.168.0.103"]="umbrel.po1.me umbrel"
)

# Add static host entries if they don't exist
for ip in "${!static_hosts[@]}"; do
    if ! grep -q "^${ip}[[:space:]]\+${static_hosts[$ip]}" /etc/hosts; then
        echo "$ip  ${static_hosts[$ip]}" >> /etc/hosts
    fi
done

# Loop to add entries for Proxmox Virtual Environment (PVE) nodes
for i in {1..5}; do
    if ! grep -q "^192.168.0.$i[[:space:]]\+pve$i\.po1\.me pve$i" /etc/hosts; then
        echo "192.168.0.$i  pve$i.po1.me pve$i"  >> /etc/hosts
    fi
done

echo "Finished updating /etc/hosts."
