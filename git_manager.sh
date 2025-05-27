#!/bin/bash

# File to store git credentials
CREDENTIALS_FILE="$HOME/.git-credentials-manager"
CONFIG_FILE="$HOME/.git-config-manager"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to save credentials
save_credentials() {
    echo "Enter Git repository information:"
    read -p "Repository URL (e.g., https://github.com/username/repo.git): " repo_url
    read -p "Username: " username
    read -s -p "Password/access token: " password
    echo
    
    # Extract domain from repo URL
    domain=$(echo "$repo_url" | awk -F/ '{print $3}')
    
    # Save credentials in git credential helper
    git config --global credential.helper 'store --file ~/.git-credentials'
    echo "https://${username}:${password}@${domain}" >> ~/.git-credentials
    
    # Save config for this script
    echo "REPO_URL=\"$repo_url\"" > "$CREDENTIALS_FILE"
    echo "USERNAME=\"$username\"" >> "$CREDENTIALS_FILE"
    echo "PASSWORD=\"$password\"" >> "$CREDENTIALS_FILE"
    echo "DOMAIN=\"$domain\"" >> "$CREDENTIALS_FILE"
    
    # Configure git to use credential helper
    git config --global credential.helper 'cache --timeout=3600'
    
    echo -e "${GREEN}Credentials saved successfully.${NC}"
}

# Function to push changes
push_changes() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        echo -e "${RED}Error: No credentials found. Please set them up first.${NC}"
        return 1
    fi
    
    source "$CREDENTIALS_FILE"
    
    echo -e "${YELLOW}Processing latest changes...${NC}"
    
    # Add all changes
    git add .
    
    # Commit with a default message
    commit_message="Auto-commit by script at $(date)"
    git commit -m "$commit_message" || {
        echo -e "${YELLOW}No changes to commit.${NC}"
        return 0
    }
    
    # Push changes
    echo -e "${YELLOW}Pushing changes...${NC}"
    git push "$REPO_URL"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Changes pushed successfully.${NC}"
    else
        echo -e "${RED}Error pushing changes.${NC}"
    fi
}

# Function to clear all settings
clear_settings() {
    if [ -f "$CREDENTIALS_FILE" ]; then
        rm "$CREDENTIALS_FILE"
        echo -e "${GREEN}Credentials removed.${NC}"
    else
        echo -e "${YELLOW}No credentials file found.${NC}"
    fi
    
    if [ -f ~/.git-credentials ]; then
        rm ~/.git-credentials
        echo -e "${GREEN}Git credentials file removed.${NC}"
    fi
    
    git config --global --unset credential.helper
    echo -e "${GREEN}Git credential helper settings removed.${NC}"
}

# Function to show menu
show_menu() {
    echo -e "\n${GREEN}Git Manager Menu${NC}"
    echo "1. Save credentials"
    echo "2. Push changes"
    echo "3. Clear all settings"
    echo "4. Exit"
    
    read -p "Please select an option: " choice
    
    case $choice in
        1) save_credentials ;;
        2) push_changes ;;
        3) clear_settings ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
    
    show_menu
}

# Main execution
if [ "$1" = "--setup" ]; then
    save_credentials
elif [ "$1" = "--push" ]; then
    push_changes
elif [ "$1" = "--clear" ]; then
    clear_settings
else
    show_menu
fi
