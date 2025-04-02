#!/bin/bash
# filepath: /Users/jgrewal/projects/iso/bitbucket/proxmox/pre-install.sh

# =============================================================================
# Proxmox Pre-Installation Disk Setup Script
#
# This script prepares disks for Proxmox VE installation by:
# - Detecting available drives and categorizing by type (NVMe, SSD, HDD)
# - Allowing interactive or automatic drive selection
# - Partitioning selected drives with appropriate layout
# - Setting up LVM or ZFS based on system memory
# - Preparing boot, swap, and root partitions
# =============================================================================
# by Jatin Grewal
# Last updated: 2023-10-01
# email @jgrewal@po1.me
# Enable strict error handling
set -euo pipefail

# -----------------------------------------------------------------------------
# Logging Functions - Making debugging easier
# -----------------------------------------------------------------------------
LOG_FILE="/var/log/proxmox-pre-install.log"

# Setup log file with appropriate permissions
setup_logging() {
    # Create log directory with parent directories if needed
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/proxmox-pre-install.log"
    chmod 644 "$LOG_FILE"

    # Begin logging session with timestamp
    echo "=========================================================" >>"$LOG_FILE"
    echo "Proxmox Pre-Install Script Started at $(date)" >>"$LOG_FILE"
    echo "=========================================================" >>"$LOG_FILE"
}

log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[INFO] $1"
    echo "[$timestamp] [INFO] $1" >>"$LOG_FILE"
}

log_warning() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\e[33m[WARNING]\e[0m $1"
    echo "[$timestamp] [WARNING] $1" >>"$LOG_FILE"
}

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
    echo "[$timestamp] [ERROR] $1" >>"$LOG_FILE"
}

log_success() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\e[32m[SUCCESS]\e[0m $1"
    echo "[$timestamp] [SUCCESS] $1" >>"$LOG_FILE"
}

# Initialize logging
setup_logging

# -----------------------------------------------------------------------------
# Dependency Checking - Ensuring all required tools are available
# -----------------------------------------------------------------------------
log_info "Checking for required commands..."

REQUIRED_COMMANDS=(
    lsblk whiptail wipefs dd parted
    mkfs.vfat mkfs.ext4 pvcreate vgcreate
    lvcreate mkswap
)

MISSING_COMMANDS=()

# Check each command and build a list of missing ones
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_COMMANDS+=("$cmd")
        log_error "$cmd is not installed or not in PATH"
    fi
done

# Exit if any required commands are missing
if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    log_error "Missing required commands: ${MISSING_COMMANDS[*]}"
    log_info "Please install the missing packages and try again"
    exit 1
fi

log_success "All required commands are available"

# -----------------------------------------------------------------------------
# Script Mode Detection - Interactive vs Automatic
# -----------------------------------------------------------------------------
AUTO_MODE=false
if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE=true
    log_info "Running in automatic mode"
else
    log_info "Running in interactive mode"
fi

# -----------------------------------------------------------------------------
# Drive Detection and Categorization
# -----------------------------------------------------------------------------
log_info "Detecting available drives..."

# Arrays to store different drive types
SSD_DRIVES=()
NVME_DRIVES=()
HDD_DRIVES=()

# Parse drive information using lsblk
# The command outputs NAME, TYPE, and ROTA (rotation) status
# We filter for disk type devices only
for dev in $(lsblk -dno NAME,TYPE,ROTA | awk '$2=="disk"{print $1,$3}'); do
    dev_name=$(echo "$dev" | awk '{print $1}')
    is_rotational=$(echo "$dev" | awk '{print $2}')

    # Full path to the device
    dev_path="/dev/$dev_name"

    # Skip if device doesn't exist
    if [[ ! -b "$dev_path" ]]; then
        log_warning "Skipping non-existent device $dev_path"
        continue
    fi

    # Categorize by device type and rotational status
    if [[ $dev_name == nvme* ]]; then
        NVME_DRIVES+=("$dev_path")
        log_info "Detected NVMe drive: $dev_path"
    elif [[ $is_rotational -eq 0 ]]; then
        SSD_DRIVES+=("$dev_path")
        log_info "Detected SSD drive: $dev_path"
    else
        HDD_DRIVES+=("$dev_path")
        log_info "Detected HDD drive: $dev_path"
    fi
done

# -----------------------------------------------------------------------------
# Drive Selection Logic
# -----------------------------------------------------------------------------
DRIVES=()

if ! $AUTO_MODE; then
    # Interactive mode with menu-based selection
    MENU_OPTIONS=()

    # Add drive type options to menu if drives are available
    if [ ${#NVME_DRIVES[@]} -gt 0 ]; then
        MENU_OPTIONS+=("NVMe Drives" "Select NVMe drive for installation (fastest)")
    fi
    if [ ${#SSD_DRIVES[@]} -gt 0 ]; then
        MENU_OPTIONS+=("SSD Drives" "Select SSD drive for installation (recommended)")
    fi
    if [ ${#HDD_DRIVES[@]} -gt 0 ]; then
        MENU_OPTIONS+=("HDD Drives" "Select HDD drive for installation (slowest)")
    fi

    # If no drives detected, exit
    if [ ${#MENU_OPTIONS[@]} -eq 0 ]; then
        log_error "No drives detected!"
        exit 1
    fi

    # Display menu with timeout for drive type selection
    SELECTED_TYPE=$(whiptail --title "Select Drive Type" \
        --menu "Choose drive type for installation (default: first SSD in 2 minutes)" \
        --timeout 120 \
        20 60 10 \
        "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

    # Handle selection or timeout
    menu_status=$?
    if [ $menu_status -ne 0 ] || [ -z "$SELECTED_TYPE" ]; then
        # Default to first SSD if available, otherwise use first available drive
        if [ ${#SSD_DRIVES[@]} -gt 0 ]; then
            DRIVES=("${SSD_DRIVES[0]}")
            log_info "No selection made, defaulting to first SSD: ${DRIVES[0]}"
        elif [ ${#NVME_DRIVES[@]} -gt 0 ]; then
            DRIVES=("${NVME_DRIVES[0]}")
            log_info "No selection made, defaulting to first NVMe: ${DRIVES[0]}"
        elif [ ${#HDD_DRIVES[@]} -gt 0 ]; then
            DRIVES=("${HDD_DRIVES[0]}")
            log_info "No selection made, defaulting to first HDD: ${DRIVES[0]}"
        else
            log_error "No drives available. Exiting."
            exit 1
        fi
    else
        # Show specific drive selection based on chosen type
        case "$SELECTED_TYPE" in
        "NVMe Drives")
            # Create a menu of NVMe drives with their paths as both option and display value
            SELECTED_DRIVE=$(whiptail --title "Select NVMe Drive" \
                --menu "Choose NVMe drive for installation" \
                20 60 10 \
                $(for drive in "${NVME_DRIVES[@]}"; do echo "$drive $drive"; done) \
                3>&1 1>&2 2>&3)

            if [ $? -eq 0 ] && [ -n "$SELECTED_DRIVE" ]; then
                DRIVES=("$SELECTED_DRIVE")
            else
                log_error "No NVMe drive selected. Exiting."
                exit 1
            fi
            ;;

        "SSD Drives")
            SELECTED_DRIVE=$(whiptail --title "Select SSD Drive" \
                --menu "Choose SSD drive for installation" \
                20 60 10 \
                $(for drive in "${SSD_DRIVES[@]}"; do echo "$drive $drive"; done) \
                3>&1 1>&2 2>&3)

            if [ $? -eq 0 ] && [ -n "$SELECTED_DRIVE" ]; then
                DRIVES=("$SELECTED_DRIVE")
            else
                log_error "No SSD drive selected. Exiting."
                exit 1
            fi
            ;;

        "HDD Drives")
            SELECTED_DRIVE=$(whiptail --title "Select HDD Drive" \
                --menu "Choose HDD drive for installation" \
                20 60 10 \
                $(for drive in "${HDD_DRIVES[@]}"; do echo "$drive $drive"; done) \
                3>&1 1>&2 2>&3)

            if [ $? -eq 0 ] && [ -n "$SELECTED_DRIVE" ]; then
                DRIVES=("$SELECTED_DRIVE")
            else
                log_error "No HDD drive selected. Exiting."
                exit 1
            fi
            ;;
        esac
    fi
else
    # Automatic mode - select drives based on preference order: SSD > NVMe > HDD
    if [ ${#SSD_DRIVES[@]} -gt 0 ]; then
        DRIVES=("${SSD_DRIVES[0]}")
        log_info "Auto-selected SSD drive: ${DRIVES[0]}"
    elif [ ${#NVME_DRIVES[@]} -gt 0 ]; then
        DRIVES=("${NVME_DRIVES[0]}")
        log_info "Auto-selected NVMe drive: ${DRIVES[0]}"
    elif [ ${#HDD_DRIVES[@]} -gt 0 ]; then
        DRIVES=("${HDD_DRIVES[0]}")
        log_info "Auto-selected HDD drive: ${DRIVES[0]}"
    else
        log_error "No drives available for automatic selection. Exiting."
        exit 1
    fi
fi

# Final check to ensure we have selected drives
if [ ${#DRIVES[@]} -eq 0 ]; then
    log_error "No drives selected. Exiting."
    exit 1
fi

log_success "Selected drive(s) for installation: ${DRIVES[*]}"

# -----------------------------------------------------------------------------
# Confirmation in interactive mode
# -----------------------------------------------------------------------------
if ! $AUTO_MODE; then
    # Use whiptail to get confirmation before proceeding with destructive operations
    whiptail --title "⚠️ Confirmation Required ⚠️" \
        --yesno "WARNING: This will ERASE ALL DATA on these drives:\n\n${DRIVES[*]}\n\nThere is NO UNDO. Continue?" \
        12 70

    # Check if user confirmed
    if [ $? -ne 0 ]; then
        log_warning "Operation cancelled by user"
        exit 0
    fi

    log_info "User confirmed disk wipe operation"
fi

# -----------------------------------------------------------------------------
# Filesystem selection based on system memory
# -----------------------------------------------------------------------------
# ZFS requires more memory, so we use available RAM to decide
MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEMORY_GB=$((MEMORY_KB / 1024 / 1024))

# Choose filesystem based on memory
if [ $MEMORY_GB -lt 16 ]; then
    FILESYSTEM="ext4"
    log_info "System memory ${MEMORY_GB}GB < 16GB, using ext4 filesystem"
else
    FILESYSTEM="zfs"
    log_info "System memory ${MEMORY_GB}GB >= 16GB, using ZFS filesystem"
fi

# -----------------------------------------------------------------------------
# Volume configuration
# -----------------------------------------------------------------------------
# Names for LVM volumes
VGNAME="pve"
LV_ROOT_NAME="root"
LV_SWAP_NAME="swap"
LV_DATA_NAME="data"

# Partition sizes - adjust these as needed for your environment
EFI_SIZE="1GiB"
BOOT_SIZE="2GiB" # Increased from 1GiB for more headroom
SWAP_SIZE="8GiB"
ROOT_SIZE="40GiB"

# Ensure swap size is sensible based on RAM
# For systems with a lot of RAM, we might not need as much swap
if [ $MEMORY_GB -gt 64 ]; then
    SWAP_SIZE="4GiB"
    log_info "Large memory system (${MEMORY_GB}GB), reducing swap to 4GB"
elif [ $MEMORY_GB -gt 32 ]; then
    SWAP_SIZE="6GiB"
    log_info "Medium memory system (${MEMORY_GB}GB), using 6GB swap"
fi

# -----------------------------------------------------------------------------
# Main partitioning and filesystem creation
# -----------------------------------------------------------------------------
# Process each selected drive
for drive in "${DRIVES[@]}"; do
    log_info "Starting partitioning of $drive..."

    # Safety check - confirm drive exists
    if [[ ! -b "$drive" ]]; then
        log_error "Device $drive does not exist or is not a block device!"
        exit 1
    fi

    # Step 1: Wipe existing drive signatures to prevent issues
    log_info "Wiping existing signatures on $drive..."
    wipefs -a "$drive" || log_warning "Wipefs failed, continuing anyway"

    # Clear first 100MB of the drive to ensure clean start
    # This helps remove any remnants of old partition tables or boot sectors
    log_info "Clearing first 100MB of $drive..."
    dd if=/dev/zero of="$drive" bs=1M count=100 status=progress || log_warning "Initial zeroing failed, continuing anyway"

    # Step 2: Create GPT partition table
    log_info "Creating GPT partition table on $drive..."
    parted -s "$drive" mklabel gpt || {
        log_error "Failed to create GPT label on $drive"
        exit 1
    }

    # Step 3: Create partitions
    log_info "Creating partitions on $drive..."

    # EFI system partition - will be mounted at /boot/efi
    parted -s "$drive" mkpart primary fat32 1MiB "$EFI_SIZE" || {
        log_error "Failed to create EFI partition"
        exit 1
    }
    parted -s "$drive" set 1 esp on || log_warning "Failed to set ESP flag, may need manual intervention"

    # Boot partition - will be mounted at /boot
    parted -s "$drive" mkpart primary ext4 "$EFI_SIZE" "$BOOT_SIZE" || {
        log_error "Failed to create boot partition"
        exit 1
    }

    # Swap partition
    parted -s "$drive" mkpart primary linux-swap "$BOOT_SIZE" "$SWAP_SIZE" || {
        log_error "Failed to create swap partition"
        exit 1
    }

    # Root/data partition - will use the rest of the disk
    parted -s "$drive" mkpart primary ext4 "$SWAP_SIZE" 100% || {
        log_error "Failed to create root partition"
        exit 1
    }

    # Step 4: Identify the created partitions
    log_info "Identifying partitions..."

    # This handles both nvme (e.g., nvme0n1p1) and regular drives (e.g., sda1)
    # We need to be careful with pattern matching to get the right partitions
    drive_base=$(basename "$drive")

    # For NVMe drives, partitions are like nvme0n1p1, nvme0n1p2, etc.
    # For SATA/SAS drives, partitions are like sda1, sda2, etc.
    if [[ $drive_base == nvme* ]]; then
        # NVMe drive - partitions have 'p' prefix before the number
        EFI_PART="${drive}p1"
        BOOT_PART="${drive}p2"
        SWAP_PART="${drive}p3"
        ROOT_PART="${drive}p4"
    else
        # Regular drive - partitions are just numbers
        EFI_PART="${drive}1"
        BOOT_PART="${drive}2"
        SWAP_PART="${drive}3"
        ROOT_PART="${drive}4"
    fi

    # Verify partitions actually exist
    for part in "$EFI_PART" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART"; do
        if [[ ! -b "$part" ]]; then
            log_warning "Partition $part does not exist yet, waiting for kernel to recognize..."
            # Wait for partitions to be recognized by kernel (up to 10 seconds)
            for i in {1..10}; do
                sleep 1
                if [[ -b "$part" ]]; then
                    log_info "Partition $part now available"
                    break
                fi
                if [[ $i -eq 10 ]]; then
                    log_error "Partition $part still not available after 10 seconds"
                    log_info "Available block devices:"
                    ls -la /dev/[sh]d* /dev/nvme* 2>/dev/null || true
                    exit 1
                fi
            done
        fi
    done

    # Step 5: Format the partitions
    log_info "Formatting partitions..."

    # Format EFI partition as FAT32
    log_info "Formatting EFI partition ($EFI_PART)..."
    mkfs.vfat -F32 "$EFI_PART" || {
        log_error "Failed to format EFI partition"
        exit 1
    }

    # Format boot partition as ext4
    log_info "Formatting boot partition ($BOOT_PART)..."
    mkfs.ext4 -F "$BOOT_PART" || {
        log_error "Failed to format boot partition"
        exit 1
    }

    # Set up swap partition
    log_info "Setting up swap partition ($SWAP_PART)..."
    mkswap "$SWAP_PART" || {
        log_error "Failed to set up swap partition"
        exit 1
    }

    # Step 6: Set up root filesystem - either ext4 with LVM or ZFS
    if [ "$FILESYSTEM" = "ext4" ]; then
        log_info "Configuring ext4 filesystem with LVM on $ROOT_PART..."

        # LVM setup on the root partition
        log_info "Creating physical volume on $ROOT_PART..."
        pvcreate --force --yes "$ROOT_PART" || {
            log_error "Failed to create physical volume"
            exit 1
        }

        log_info "Creating volume group $VGNAME..."
        vgcreate "$VGNAME" "$ROOT_PART" || {
            log_error "Failed to create volume group"
            exit 1
        }

        # Create logical volumes
        log_info "Creating logical volume for root ($LV_ROOT_NAME)..."
        lvcreate -L "$ROOT_SIZE" -n "$LV_ROOT_NAME" "$VGNAME" || {
            log_error "Failed to create root logical volume"
            exit 1
        }

        log_info "Creating logical volume for data ($LV_DATA_NAME)..."
        lvcreate -l 100%FREE -n "$LV_DATA_NAME" "$VGNAME" || {
            log_error "Failed to create data logical volume"
            exit 1
        }

        # Format the logical volumes
        log_info "Formatting root logical volume..."
        mkfs.ext4 "/dev/$VGNAME/$LV_ROOT_NAME" || {
            log_error "Failed to format root logical volume"
            exit 1
        }

        log_info "Formatting data logical volume..."
        mkfs.ext4 "/dev/$VGNAME/$LV_DATA_NAME" || {
            log_error "Failed to format data logical volume"
            exit 1
        }
    else
        log_info "Configuring ZFS filesystem..."

        # Create temporary mount point
        mkdir -p /mnt/install || {
            log_error "Failed to create temporary mount point"
            exit 1
        }

        # Mount root partition temporarily
        log_info "Mounting $ROOT_PART to /mnt/install..."
        mount "$ROOT_PART" /mnt/install || {
            log_error "Failed to mount root partition"
            exit 1
        }

        # Install ZFS if needed
        log_info "Installing ZFS utilities..."
        if ! command -v zpool &>/dev/null; then
            apt-get update && apt-get install -y zfsutils-linux || {
                log_error "Failed to install ZFS utilities"
                umount /mnt/install || true
                exit 1
            }
        fi

        # Unmount first before creating ZFS pool
        umount /mnt/install || {
            log_error "Failed to unmount temporary mount point"
            exit 1
        }

        # Create ZFS pool with optimized settings
        log_info "Creating ZFS pool on $ROOT_PART..."
        zpool create -f -o ashift=12 -O compression=lz4 -O atime=off \
            -O mountpoint=/ -R /mnt/install rpool "$ROOT_PART" || {
            log_error "Failed to create ZFS pool"
            exit 1
        }

        # Create ZFS datasets with appropriate properties
        log_info "Creating ZFS datasets..."
        zfs create -o mountpoint=/ rpool/ROOT || {
            log_error "Failed to create root ZFS dataset"
            zpool destroy rpool || true
            exit 1
        }

        zfs create -o mountpoint=/var/lib/vz rpool/data || {
            log_error "Failed to create data ZFS dataset"
            zpool destroy rpool || true
            exit 1
        }

        # Cleanup
        zpool export rpool || log_warning "Failed to export ZFS pool"
        rmdir /mnt/install || log_warning "Failed to remove temporary mount point"
    fi

    log_success "Partitioning completed on $drive with $FILESYSTEM filesystem"
done

# -----------------------------------------------------------------------------
# Display final configuration and next steps
# -----------------------------------------------------------------------------
echo ""
log_success "Disk setup completed with the following configuration:"
echo "========================================================="
echo "Selected drive: ${DRIVES[0]}"
echo "Filesystem type: $FILESYSTEM"
echo "Memory detected: ${MEMORY_GB}GB"
echo ""
echo "Partition layout:"
lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT "${DRIVES[0]}"
echo ""
echo "Next steps:"
echo "1. Mount the partitions:"
echo "   - Mount ${EFI_PART} to /boot/efi"
echo "   - Mount ${BOOT_PART} to /boot"

if [ "$FILESYSTEM" = "ext4" ]; then
    echo "   - Mount /dev/$VGNAME/$LV_ROOT_NAME to /"
    echo "   - Mount /dev/$VGNAME/$LV_DATA_NAME to /var/lib/vz"
else
    echo "   - Import ZFS pool with: zpool import rpool"
    echo "   - ZFS datasets are already configured with proper mountpoints"
fi

echo "2. Configure your system and install Proxmox"
echo "3. Reboot when installation is complete"
echo ""

# Write final status to log
log_success "Pre-installation script completed successfully at $(date)"
log_info "Check $LOG_FILE for detailed logs"

exit 0
