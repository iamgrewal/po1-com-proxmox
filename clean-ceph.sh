#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Configuration
declare -A REPOS=(
    ["ceph"]="deb http://download.proxmox.com/debian/ceph-squid bookworm no-subscription"
    ["pve"]="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
)

# Pre-run checks
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "ERROR: This script must run as root" >&2
        exit 1
    fi
}

check_network() {
    if ! curl -IsS --retry 3 --max-time 10 http://download.proxmox.com >/dev/null; then
        echo "ERROR: Network connectivity check failed" >&2
        exit 1
    fi
}

cleanup_repos() {
    local files=(
        /etc/apt/sources.list.d/ceph.list
        /etc/apt/sources.list.d/pve-enterprise.list
    )
    
    for file in "${files[@]}"; do
        if [[ -f "${file}" ]]; then
            echo "Removing repository file: ${file}"
            rm -f "${file}" || {
                echo "ERROR: Failed to remove ${file}" >&2
                exit 1
            }
        fi
    done
}

setup_repos() {
    for repo in "${!REPOS[@]}"; do
        local file="/etc/apt/sources.list.d/${repo}-install-repo.list"
        echo "Configuring ${repo} repository..."
        echo "${REPOS[$repo]}" | tee "${file}" >/dev/null || {
            echo "ERROR: Failed to write ${file}" >&2
            exit 1
        }
    done
}

purge_ceph() {
    local packages=(
        ceph-mon ceph-osd ceph-mgr ceph-mds
        ceph-base ceph-mgr-modules-core
    )
    
    # Gracefully stop services first
    if systemctl list-unit-files | grep -q ceph; then
        systemctl stop ceph.target || true
    fi
    
    # Kill remaining processes
    pkill -9 ceph-mon ceph-mgr ceph-mds || true
    
    # Purge packages
    apt-get purge --assume-yes --quiet "${packages[@]}" 2>/dev/null || true
    
    # Cleanup residual files
    local dirs=(
        /etc/ceph
        /etc/pve/ceph.conf
        /etc/pve/priv/ceph.*
        /var/lib/ceph/{mon,mgr,mds}
    )
    
    for dir in "${dirs[@]}"; do
        if [[ -e "${dir}" ]]; then
            rm -rfv "${dir}" || true
        fi
    done
}

system_maintenance() {
    apt-get update --quiet
    apt-get full-upgrade --assume-yes --quiet
    apt-get dist-upgrade --assume-yes --quiet
    apt-get autoremove --assume-yes --quiet
    apt-get autoclean --quiet
}

main() {
    check_root
    check_network
    
    echo "Starting Proxmox/Ceph cleanup and reconfiguration..."
    
    cleanup_repos
    setup_repos
    purge_ceph
    system_maintenance
    
    echo "Operation completed successfully"
    logger -t proxmox-cleanup "System reconfigured successfully"
}

# Execution with clean error trapping
trap 'echo "ERROR: Script failed at line $LINENO" >&2' ERR
main
exit 0
