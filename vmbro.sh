#!/bin/bash

# Try to fix vmbr0 / GUI access on IP:8006 after a NIC name change

# This script will:
#   1. Backup /etc/network/interfaces to interfaces.YYYYMMDD@HHMM.bak
#   2. Copy /etc/network/interfaces to interfaces.MODME
#   3. Prompt user for the new interface name to use for vmbr0
#   4. Update /etc/network/interfaces to use the new interface name
#   5. Restart networking service

# DEPENDS: find grep awk sed netstat
# NOTE: script must be run as root
# NOTE: script assumes the original /etc/network/interfaces file is in the default location
# NOTE: script assumes the original /etc/network/interfaces file is not modified by the user
# NOTE: script assumes the original /etc/network/interfaces file has a vmbr0 entry
# NOTE: script assumes the original /etc/network/interfaces file has a bridge-ports entry for vmbr0
# NOTE: script assumes the original /etc/network/interfaces file has a valid address and gateway entry for vmbr0

# PROTIP - run ' screen ' or ' tmux ' before running this script if the interface name is long,
#   you can copypasta with just the keyboard - see appropriate man pages

# In GNU screen: Hit ^[, cursor move to start of new interface name, hit spacebar to begin mark, cursor to end of NIC name,
#   then hit spacebar to end mark, ^] to paste

# Function to check and fix the network interface
check_and_fix() {
    cd /etc/network/

    # Extract the old interface name from the vmbr0 configuration
    oldiface=$(grep -m 1 bridge-ports /etc/network/interfaces | awk '{print $2}')

    # Check if the old interface exists
    if ! ip link show "$oldiface" &>/dev/null; then
        echo "Warning: The current interface '$oldiface' for vmbr0 does not exist."
        echo "Available interfaces:"
        ip -br a | awk '{print $1, "- MAC:", $2}' | grep -v lo | column -t
        echo '====='
        echo "Here is the current entry for vmbr0:"
        grep -A 7 vmbr0 /etc/network/interfaces
        echo "Please enter the new interface name to use for vmbr0:"
        read useinterface

        # Check if the new interface actually exists
        if ! ip link show "$useinterface" &>/dev/null; then
            echo "Error: Interface '$useinterface' not found. Exiting." >&2
            return 1
        fi

        # Backup and modify the interfaces file
        cp -v interfaces interfaces.$(date +%Y%m%d@%H%M).bak
        tee interfaces.$(date +%Y%m%d@%H%M).bak <interfaces >interfaces.MODME

        echo ''
        echo "Replacing '$oldiface' with '$useinterface' in 'interfaces.MODME' (no actual changes to your system yet)."

        # Replace only the first occurrence of 'bridge-ports' in the temporary copy
        sed -i "s/bridge-ports $oldiface/bridge-ports $useinterface/" interfaces.MODME

        echo '====='
        grep -A 7 vmbr0 interfaces.MODME
        ls -lh /etc/network/interfaces /etc/network/interfaces.MODME

        echo '====='
        echo "NOTE The original interfaces file has been backed up!"
        ls -lh *bak

        echo '====='
        echo "Nothing has been modified / fixed yet, you are still in safe mode"
        echo "Hit ^C to backout, or Enter to replace the interfaces file with the fixed one and restart networking:"
        read

        # apply the fix
        echo ''
        echo "$(date) - Applying the fix"
        if cp -v interfaces.MODME interfaces; then
            echo "Successfully replaced the interfaces file."
        else
            echo "Error: Failed to replace the interfaces file. Exiting." >&2
            return 1
        fi

        echo "$(date) - Restarting networking service to apply the change"
        if time systemctl restart networking; then
            echo "Networking service restarted successfully."
        else
            echo "Error: Failed to restart networking service. Exiting." >&2
            return 1
        fi

        echo "$(date) - Restarting pveproxy service to make sure port 8006 is listening"
        if time systemctl restart pveproxy; then
            echo "pveproxy service restarted successfully."
        else
            echo "Error: Failed to restart pveproxy service. Exiting." >&2
            return 1
        fi
        # probably not necessary, but why not

        # verify web GUI listening port using ss (modern alternative to netstat)
        ss -plant | grep 8006 | head -n 2

        echo '====='
        ip a | grep vmbr0 | grep -v tap

        echo "You should now be able to ping the above IP address and get to the Proxmox Web interface."
        date
        return 0
    else
        echo "vmbr0 interface '$oldiface' is correct."
        return 0
    fi
}

# Check if the script is called with the check_and_fix function
if [ "$1" == "check_and_fix" ]; then
    check_and_fix
fi
