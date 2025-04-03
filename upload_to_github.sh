#!/bin/bash
# Script to upload files to GitHub repository
# This script uploads the created scripts to the GitHub repository

# Set up variables
REPO_OWNER="iamgrewal"
REPO_NAME="po1-com-proxmox"
BRANCH="main"
GITHUB_TOKEN="YOUR_GITHUB_TOKEN"  # Replace with your GitHub token

# Files to upload
FILES=(
    "network_setup_auto.sh"
    "install_in_place_bookworm_auto.sh"
    "remove_nag.sh"
)

# Function to upload a file to GitHub
upload_file() {
    local file="$1"
    local content=$(cat "$file" | base64)
    local message="Add $file for automated installation"
    
    # Check if file already exists in the repository
    local sha=""
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$file?ref=$BRANCH")
    
    if [[ "$response" == *"sha"* ]]; then
        sha=$(echo "$response" | grep -o '"sha": "[^"]*"' | cut -d'"' -f4)
    fi
    
    # Prepare JSON payload
    local data="{\"message\":\"$message\",\"content\":\"$content\",\"branch\":\"$BRANCH\""
    if [[ -n "$sha" ]]; then
        data="$data,\"sha\":\"$sha\""
    fi
    data="$data}"
    
    # Upload file
    echo "Uploading $file to GitHub..."
    curl -s -X PUT -H "Authorization: token $GITHUB_TOKEN" \
        -d "$data" \
        "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$file"
    
    echo "Upload of $file completed."
}

# Main function
main() {
    echo "Starting upload of files to GitHub repository..."
    
    # Check if GitHub token is set
    if [[ "$GITHUB_TOKEN" == "YOUR_GITHUB_TOKEN" ]]; then
        echo "ERROR: GitHub token not set. Please edit this script and set your GitHub token."
        exit 1
    fi
    
    # Upload each file
    for file in "${FILES[@]}"; do
        if [[ -f "$file" ]]; then
            upload_file "$file"
        else
            echo "ERROR: File $file not found."
        fi
    done
    
    echo "All files uploaded successfully."
}

# Run main function
main
