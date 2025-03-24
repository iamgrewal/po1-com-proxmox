#!/bin/bash
sudo apt update
sudo mkdir -p ~/.


# Installs the provided packages.
# This function uses apt-get to install packages, handling errors by redirecting them to a log file.
function addpkgs {
    # apt-get install -y --force-yes $*
    sudo apt-get install -y --allow-unauthenticated $*
} 2>>$logfile
# addpkgs $*
# addpkgs $* >> $logfile
# addpkgs $* >> $logfile 2>&1
# essential
addpkgs joe mc screen nano vim tmux lzop fsarchiver netcat-traditional bwm-ng smartmontools sysstat
addpkgs linux-headers-$(uname -r) build-essential
addpkgs nfs-common open-iscsi lvm2 multipath-tools
addpkgs mbr lm-sensors gawk net-tools mlocate # hddtemp
addpkgs sshfs pv buffer ethtool parted iotop dos2unix
addpkgs p7zip parallel pbzip2 xz-utils # unrar #  TODO - codecs? - to play dvds
addpkgs exfat-utils jfsutils certbot
apt -t stretch-backports install certbot -y

apt-file update &
#[ `lsmod |grep -c zfs` -gt 0 ] && zpool import
echo "$(date) - DONE"

apt install curl software-properties-common apt-transport-https ca-certificates gnupg2 -y
bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/misc/update-repo.sh)"
# This script updates the Proxmox VE repository to the latest version.

## Proxmox VE Post-Install Clean Kernal
bash -c "$(wget -qLO - https://github.com/tteck/Proxmox/raw/main/misc/kernel-clean.sh)"
# This script provides options for managing Proxmox VE repositories, including disabling the Enterprise Repo, adding or correcting PVE sources, enabling the No-Subscription Repo, adding the test Repo, disabling the subscription nag, updating Proxmox VE, and rebooting the system.
bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/misc/cron-update-lxcs.sh)"
# Run the command below. This script provides options for managing Proxmox VE repositories, including disabling the Enterprise Repo, adding or correcting PVE sources, enabling the No-Subscription Repo, adding the test Repo, disabling the subscription nag, updating Proxmox VE, and rebooting the system.


bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/misc/clean-orphaned-lvm.sh)"
# This script installs Postfix, Open-iSCSI, and Chrony in the Proxmox VE Shell.
# Install necessary packages
apt install proxmox-ve postfix open-iscsi chrony -y

# Enable and start services
for service in postfix open-iscsi chrony; do
    systemctl enable $service
    systemctl start $service
done
dpkg --configure -a

# Update and upgrade the system
apt-get update && apt-get dist-upgrade -y --allow-unauthenticated
apt-get install -f
apt-get autoremove -y
apt-get autoclean -y
sudo rm /var/lib/dpkg/lock-frontend
sudo rm /var/lib/dpkg/lock
sudo rm /var/cache/apt/archives/lock

service pveproxy restart
service pvedaemon restart

##remove oprtphaned lvm


update-grub
apt remove os-prober

##remove oprtphaned lvm

# --- Network Interface Check and Fix ---
echo "Checking network interface for vmbr0..."

# Source the vmbro.sh script (make sure it's executable: chmod +x vmbro.sh)
source /scripts/vmbro.sh check_and_fix

# Check if the script returned an error code
if [ $? -ne 0 ]; then
    echo "Error: Network interface check and fix failed. Please check the logs." >&2
    exit 1
fi

echo "Network interface check and fix completed successfully."

# --- Ensure DHCP is used ---
echo "Ensuring DHCP is used for vmbr0..."
sed -i '/iface vmbr0 inet static/s/static/dhcp/' /etc/network/interfaces
sed -i '/address /d' /etc/network/interfaces
sed -i '/netmask /d' /etc/network/interfaces
sed -i '/gateway /d' /etc/network/interfaces

# Restart networking to apply DHCP changes
echo "Restarting networking service to apply DHCP changes..."
systemctl restart networking

echo "DHCP configuration applied successfully."


echo "$(date) - post-install.sh completed"
exit 0

##remove oprtphaned lvm
