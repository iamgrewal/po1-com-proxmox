#!/bin/bash
sudo apt-get update && sudo apt-get install wget aria2 -y

## Function to download files, attempting parallel + resumed downloads
download() {
    local url=$1
    local output=$2

    # If aria2c is installed, use it for parallel and resumed downloads
    if command -v aria2c &>/dev/null; then
        # The -c option automatically attempts to continue partial downloads
        # -x sets the max connection per server, -s sets split count, and -k sets minimum split size
        aria2c -c -x 16 -s 16 -k 1M -o "$output" "$url"
    else
        # Fallback to wget with resume support
        wget -c -O "$output" "$url"
    fi
}

ALMA_LINUX="http://ftp.cn.debian.org/proxmox/images/system/almalinux-9-default_20240911_amd64.tar.xz"
ALPINE_LINUX="http://ftp.cn.debian.org/proxmox/images/system/alpine-3.21-default_20241217_amd64.tar.xz"
ARCH_LINUX="http://ftp.cn.debian.org/proxmox/images/system/archlinux-base_20240911-1_amd64.tar.zst"
BOOKWORM_DEBIAN="https://images.linuxcontainers.org/images/debian/bookworm/amd64/cloud/20250321_22%3A02/disk.qcow2"
DEBIAN_12_Bookworm="http://ftp.cn.debian.org/proxmox/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
BOOKWORM_DEBIAN_ROOTFS="https://images.linuxcontainers.org/images/debian/bookworm/amd64/cloud/20250321_22%3A02/rootfs.tar.xz"
TRIXY_DEBIAN="https://images.linuxcontainers.org/images/debian/trixie/amd64/default/20250324_05%3A32/disk.qcow22"
TRIXY_DEBIAN_ROOTFS="https://images.linuxcontainers.org/images/debian/trixie/amd64/default/20250324_05%3A32/rootfs.tar.xz"
UBUNTU_2404="http://ftp.cn.debian.org/proxmox/images/system/ubuntu-24.04-standard_24.04-1_amd64.tar.zst"

## Array of URLs to download
urls=(
    "$ALMA_LINUX"
    "$ALPINE_LINUX"
    "$ARCH_LINUX"
    "$BOOKWORM_DEBIAN"
    "$DEBIAN_12_Bookworm"
    "$BOOKWORM_DEBIAN_ROOTFS"
    "$TRIXY_DEBIAN"
    "$TRIXY_DEBIAN_ROOTFS"
    "$UBUNTU_2404"
)

## Loop to download each file by splitting from the array
for url in "${urls[@]}"; do
    # Check if the URL is valid using a HEAD request; if not, log and skip
    if ! curl -Ifs "$url" >/dev/null 2>&1; then
        echo "$(date): Invalid URL: $url" >>/var/log/download_script.log
        continue
    fi

    # Extract the filename and call the download function
    filename=$(basename "$url")
    download "$url" "$filename"
done
