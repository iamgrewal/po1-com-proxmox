#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Ensure required commands are available
# ------------------------------------------------------------------------------
for cmd in lsblk whiptail wipefs dd parted mkfs.vfat mkfs.ext4 pvcreate vgcreate; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is not installed or not in PATH"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Interactive or automatic mode handling
# ------------------------------------------------------------------------------
AUTO_MODE=false
if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE=true
fi

# ------------------------------------------------------------------------------
# Prepare disk selection
# Build a checklist array of all 'disk' type block devices.
# ------------------------------------------------------------------------------
CHOICES=()
for dev in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    CHOICES+=("/dev/$dev" "/dev/$dev" "OFF")
done

# If not running in auto mode, display an interactive checklist.
if ! $AUTO_MODE; then
    SELECTED_DEVICES=$(whiptail --title "Select Drives" \
        --checklist "Use [SPACE] to select disks to wipe and partition." \
        20 60 10 \
        "${CHOICES[@]}" 3>&1 1>&2 2>&3)
    DRIVES=($(echo "$SELECTED_DEVICES" | tr -d '"'))
else
    # Non-interactive example: automatically select all available disks
    DRIVES=($(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'))
fi

# ------------------------------------------------------------------------------
# If no drives are selected, exit to avoid accidental operations
# ------------------------------------------------------------------------------
if [ ${#DRIVES[@]} -eq 0 ]; then
    echo "No drives selected. Exiting."
    exit 1
fi

# ------------------------------------------------------------------------------
# Confirm before wiping disks (interactive mode)
# ------------------------------------------------------------------------------
if ! $AUTO_MODE; then
    whiptail --title "Confirmation" --yesno "About to wipe these drives: ${DRIVES[*]}. Continue?" 10 60
    if [ $? -ne 0 ]; then
        echo "Operation cancelled."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Variables for Volume Group and Logical Volume names
# Adjust these if needed for your own environment
# ------------------------------------------------------------------------------
VGNAME="pve"
LV_ROOT_NAME="root"
LV_SWAP_NAME="swap"

# ------------------------------------------------------------------------------
# Partition sizes (adjust as needed)
# ------------------------------------------------------------------------------
EFI_END="512MiB" # End of EFI partition
SWAP_END="4GiB"  # End of SWAP partition

# ------------------------------------------------------------------------------
# Wipe and partition the selected drives
# ------------------------------------------------------------------------------
for drive in "${DRIVES[@]}"; do
    echo "Wiping and partitioning $drive..."
    wipefs -a "$drive" || true # Remove existing signatures
    dd if=/dev/zero of="$drive" bs=1M count=100 status=progress || true

    # Create GPT label and partitions for EFI, swap, and root/LVM
    parted -s "$drive" mklabel gpt
    parted -s "$drive" mkpart primary fat32 1MiB "$EFI_END"
    parted -s "$drive" set 1 esp on
    parted -s "$drive" mkpart primary linux-swap "$EFI_END" "$SWAP_END"
    parted -s "$drive" mkpart primary ext4 "$SWAP_END" 100%

    # Identify partitions dynamically for portability (handles NVMe, sdX, etc.)
    EFI_PART="/dev/$(lsblk -ln -o NAME -r "$drive" | grep -m1 -E "${drive##*/}p?1$")"
    SWAP_PART="/dev/$(lsblk -ln -o NAME -r "$drive" | grep -m1 -E "${drive##*/}p?2$")"
    ROOT_PART="/dev/$(lsblk -ln -o NAME -r "$drive" | grep -m1 -E "${drive##*/}p?3$")"

    # Format EFI and swap partitions
    mkfs.vfat -F32 "$EFI_PART"
    mkswap "$SWAP_PART"
    # Uncomment to format the root partition if not using LVM:
    # mkfs.ext4 "$ROOT_PART"

    echo "Partitioning completed on $drive."
done

# ------------------------------------------------------------------------------
# Collect the root partitions (third partition) for LVM if needed
# ------------------------------------------------------------------------------
PVS=()
for drive in "${DRIVES[@]}"; do
    third_part=$(lsblk -ln -o NAME -r "$drive" | grep -m1 -E "${drive##*/}p?3$")
    if [ -b "/dev/$third_part" ]; then
        PVS+=("/dev/$third_part")
    fi
done

# ------------------------------------------------------------------------------
# Create LVM only if there are partitions available for it
# ------------------------------------------------------------------------------
if [ ${#PVS[@]} -gt 0 ]; then
    echo "Creating LVM..."
    # Use --force and --yes flags, but be aware of potentially overwriting data
    pvcreate --force --yes "${PVS[@]}"
    vgcreate "$VGNAME" "${PVS[@]}"

    # Create swap and root LVs
    lvcreate -L 8G -n "$LV_SWAP_NAME" "$VGNAME"
    lvcreate -l 100%FREE -n "$LV_ROOT_NAME" "$VGNAME"

    # Format the logical volumes
    mkswap "/dev/$VGNAME/$LV_SWAP_NAME"
    mkfs.ext4 "/dev/$VGNAME/$LV_ROOT_NAME"
fi

# ------------------------------------------------------------------------------
# Final message
# ------------------------------------------------------------------------------
echo "Disk setup and optional LVM creation completed."
echo "Next steps: Mount the partitions and configure your system as needed."
