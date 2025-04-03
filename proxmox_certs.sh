#!/bin/bash
 
# Error handling
set -euo pipefail
# 1. First install Proxmox VE
 
sudo apt-get install jq curl openssl procps -y
# 2. Verify Proxmox installation
 

# 3. Then run the certificate/swap management script
#sudo ./proxmox-certs.sh
# 1. First install Proxmox VE
#bash install.sh  # Your Proxmox installation script
read -p "Your Cloudflare API token. Obtain it from the Cloudflare dashboard under " CFAPITOKEN   
read -p "Your Cloudflare API token. Obtain it from the Cloudflare dashboard: " CFAPITOKEN   
read -p "Your Cloudflare Zone ID (found in the Cloudflare dashboard under the DNS settings for your domain): " ZONEID      
read -p "Your domain (e.g., example.com). Use the root domain without 'www' or subdomains: " DOMAINNAME      
read -p "Your Email Address: " EMAILADDRESS
pvesh get version
systemctl status pveproxy

# 3. Then run the certificate/swap management script
#sudo ./proxmox-certs.sh
apt-get install jq curl openssl procps -Y
apt-get install 
# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq could not be found, please install jq to proceed"
    exit 1
fi

# Check if df is installed
if ! command -v df &> /dev/null; then
    echo "df could not be found, please install df to proceed"
    exit 1
fi

# Check if pvesh is installed
if ! command -v pvesh &> /dev/null; then
    echo "pvesh could not be found, please install pvesh to proceed"
    exit 1
fi
curl 'https://api.cloudflare.com/client/v4/zones?account.id=$ZONEID' \
--header 'Authorization: Bearer $CF_API_TOKEN' \
--header 'Content-Type: application/json' | jq
# Configuration
CF_API_TOKEN="$CFAPITOKEN"  # Your Cloudflare API token. Obtain it from the Cloudflare dashboard under "API Tokens".
ZONE_ID="$ZONEID"       # Your Cloudflare Zone ID (found in the Cloudflare dashboard under the DNS settings for your domain)
DOMAIN="$DOMAINNAME"        # Your domain (e.g., example.com). Use the root domain without 'www' or subdomains.
EMAIL="$EMAILADDRESS"         # Your Cloudflare email. Used for Cloudflare account identification and notifications.
# Directory where Proxmox nodes' certificates will be stored
CERT_DIR="/etc/pve/nodes"  # Proxmox certificate directory

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# Validate configuration
validate_config() {
    if [[ -z "$CF_API_TOKEN" ]] || [[ -z "$ZONE_ID" ]] || [[ -z "$DOMAIN" ]] || [[ -z "$EMAIL" ]]; then
        error_exit "Please configure CF_API_TOKEN, ZONE_ID, DOMAIN, and EMAIL variables"
    fi
}

# Generate CSR and private key
generate_csr() {
    log "Generating CSR and private key..."
    
    local tmp_dir=$(mktemp -d)
    local subject="/C=US/ST=State/L=City/O=Organization/CN=*.${DOMAIN}"
    
    # Generate private key
    openssl genrsa -out "${tmp_dir}/privkey.pem" 2048 || error_exit "Failed to generate private key"
    
    # Generate CSR
    openssl req -new -key "${tmp_dir}/privkey.pem" \
        -out "${tmp_dir}/csr.pem" \
        -subj "$subject" || error_exit "Failed to generate CSR"
    # Read CSR content
    if [[ -f "${tmp_dir}/csr.pem" ]]; then
    CSR=$(tr -d '\n' < "${tmp_dir}/csr.pem")
    
    if [[ ! -f "${tmp_dir}/csr.pem" ]]; then
        error_exit "CSR file does not exist"
    fi
    CSR=$(tr -d '\n' < "${tmp_dir}/csr.pem")
    
    if [[ ! -f "${tmp_dir}/privkey.pem" ]]; then
        error_exit "Private key file does not exist"
    fi
    PRIVATE_KEY=$(< "${tmp_dir}/privkey.pem")
    rm -rf "${tmp_dir}"
}

# Request certificate from Cloudflare
request_certificate() {
    log "Requesting certificate from Cloudflare..."
    
    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/ssl/certificate_packs" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{
            \"hosts\": [\"*.${DOMAIN}\", \"${DOMAIN}\"],
            \"type\": \"advanced\",
            \"validation_method\": \"txt\",
            \"validity_days\": 365,
            \"certificate_authority\": \"lets_encrypt\",
            \"requested_validity\": 365
        }")
    
    # Extract certificate from response
    CERT=$(echo "$response" | jq -r '.result.certificate')
    if [[ -z "$CERT" || "$CERT" == "null" ]]; then
        error_exit "Failed to get certificate from Cloudflare"
    }
}
    local nodes=$(pvesh get /nodes --output-format=json | jq -r '.[].node')
# Deploy certificate to Proxmox nodes
deploy_certificate() {
    log "Deploying certificates to Proxmox nodes..."
    
    # Get list of nodes
    local nodes=$(pvesh get /nodes --output-format=json | jq -r '.[].node')
    
    for node in $nodes; do
        log "Deploying to node: $node"
        
        # Create certificate directory if it doesn't exist
        local cert_dir="${CERT_DIR}/${node}"
        local cert_path="${cert_dir}/pveproxy-ssl.pem"
        local key_path="${cert_dir}/pveproxy-ssl.key"
        
        if [ ! -d "$cert_dir" ]; then
        if ! pvesh create /nodes/${node}/status/restart --command=pveproxy; then
            error_exit "Failed to restart pveproxy on $node"
        fi
        
        mkdir -p "$cert_dir" || error_exit "Failed to create certificate directory on $node"
        chmod 640 "$cert_path" "$key_path"
        
        # Restart pveproxy on the node
        pvesh create /nodes/${node}/status/restart --command=pveproxy || \
            error_exit "Failed to restart pveproxy on $node"
        
        log "Certificate deployed successfully to $node"
    done
}
    local nodes=$(pvesh get /nodes --output-format=json | jq -r '.[].node')
    
    for node in $nodes; do
        log "Deploying to node: $node"
        
        # Create certificate directory if it doesn't exist
    for node in $nodes; do
        log "Deploying to node: $node"
        
        # Create certificate directory if it doesn't exist
        local cert_dir="${CERT_DIR}/${node}"
        local cert_path="${cert_dir}/pveproxy-ssl.pem"
        local key_path="${cert_dir}/pveproxy-ssl.key"
        
        if [ ! -d "$cert_dir" ]; then
            mkdir -p "$cert_dir" || error_exit "Failed to create certificate directory on $node"
        fi
        
        # Deploy certificate and key
        echo "$CERT" > "$cert_path" || error_exit "Failed to deploy certificate to $node"
        echo "$PRIVATE_KEY" > "$key_path" || error_exit "Failed to deploy private key to $node"
        chmod 640 "$cert_path" "$key_path"
        
        # Restart pveproxy on the node
        pvesh create /nodes/${node}/status/restart --command=pveproxy || \
            error_exit "Failed to restart pveproxy on $node"
        
        log "Certificate deployed successfully to $node"
    done
}
        error_exit "free command could not be found, please install it to proceed"
    fi
    
    # Get current swap size in GB (rounded)
    local current_swap=$(free -g | awk '/^Swap:/ {print $2}')
    local current_swap=$(free -g | awk '/^Swap:/ {print $2}')
    
    # Get total disk size in GB
    local disk_size=$(df -BG / | awk 'NR==2 {print $2}' | tr -d 'G')
    
    # Calculate maximum allowed swap (1/8 of disk size)
    local max_allowed_swap=$((disk_size / 8))
    
    # Ensure max_allowed_swap is between 4 and 8 GB
    if [ "$max_allowed_swap" -gt 8 ]; then
        max_allowed_swap=8
    elif [ "$max_allowed_swap" -lt 4 ]; then
        max_allowed_swap=4
    fi
    
    log "Current swap: ${current_swap}GB"
    log "Maximum allowed swap: ${max_allowed_swap}GB"
    
    if [ "$current_swap" -lt 4 ] || [ "$current_swap" -gt "$max_allowed_swap" ]; then
        log "Adjusting swap size to ${max_allowed_swap}GB..."
        swapoff -a || error_exit "Failed to disable swap"
        # Backup fstab
        cp /etc/fstab /etc/fstab.backup
        log "Backed up /etc/fstab to /etc/fstab.backup"
        
        # Disable all existing swap
        swapoff -a
        
        # Remove existing swap file if exists
        if [ -f /swapfile ]; then
            rm -f /swapfile
        fi
        
        # Create new swap file
        log "Creating new swap file..."
        fallocate -l ${max_allowed_swap}G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile || error_exit "Failed to create swap space"
        
        # Remove existing swap entries from fstab
        sed -i '/\sswap\s/d' /etc/fstab
        
        # Add new swap entry to fstab
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
        
        # Enable swap
        swapon /swapfile || error_exit "Failed to enable swap"
        
        log "Swap configuration completed. New swap size: ${max_allowed_swap}GB"
        log "Changes made:"
        log "- Created new swap file: /swapfile"
        log "- Updated /etc/fstab with new swap entry"
        log "- Original fstab backed up to /etc/fstab.backup"
    else
        log "Swap size is already within acceptable range. No changes needed."
    fi
}

# Main execution
main() {
    log "Starting certificate deployment..."
    
    # Add swap configuration before certificate operations
    configure_swap
    
    # Validate configuration
    validate_config
    
    # Generate CSR and get certificate
    generate_csr
    request_certificate
    
    # Deploy to nodes
    deploy_certificate
    
    log "Certificate deployment completed successfully"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root/sudo"
fi

# Execute main function
main "$@"





