#!/bin/bash

# === Script for Downloading and Installing Linux Packages ===
# Version: 6.1 (Added check for OFFLINE_DIR type)

# --- Configuration ---
OFFLINE_DIR="offline_packages" # Directory to store downloaded .deb files

# Ensure the offline directory exists
mkdir -p "$OFFLINE_DIR"

# --- Check if OFFLINE_DIR is actually a directory ---
# This handles the case where a file or broken link with the same name exists
if [ ! -d "$OFFLINE_DIR" ]; then
    echo "Error: '$OFFLINE_DIR' exists but is not a directory, or could not be created." >&2
    echo "Please manually remove the existing file/link named '$OFFLINE_DIR' or check permissions." >&2
    exit 1 # Exit if it's not a directory
fi

# --- Function Definitions ---

# Function to download a package with a spinner into a specified directory
# (Used for Option 1 and 4)
download_package() {
    local pkg_name="$1"
    local target_dir="$2"
    local deb_file_name=""
    local deb_file_path=""
    local pid
    local exit_code
    local spinner='/-\|'
    local i=0

    echo -n "Downloading package '$pkg_name' locally using apt-get to '$target_dir'...  " >&2
    local tmp_download_dir=$(mktemp -d)
    # Check if mktemp succeeded
    if [[ ! -d "$tmp_download_dir" ]]; then
        echo "Error: Could not create temporary download directory." >&2
        return 1
    fi

    # Run download in background within the temp directory
    (cd "$tmp_download_dir" && apt-get download "$pkg_name" >/dev/null 2>&1) &
    pid=$!

    # Show spinner
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % ${#spinner} ))
        printf "\b%s" "${spinner:$i:1}" >&2
        sleep 0.1
    done

    # Wait for download and get exit code
    wait $pid
    exit_code=$?
    printf "\b \n" >&2 # Clear spinner

    # Check download exit code
    if [ $exit_code -ne 0 ]; then
        echo "Error: Failed to download package '$pkg_name'. Check package name, network, and permissions." >&2
        rm -rf "$tmp_download_dir" # Clean up temp dir
        return 1
    fi

    # Find the downloaded file in the temp directory
    # Using find is safer than ls if filenames have weird characters, but ls is simpler here
    deb_file_name=$(ls -t "$tmp_download_dir/"*.deb 2>/dev/null | head -n 1 | xargs basename)

    # Check if file was found
    if [ -z "$deb_file_name" ]; then
        echo "Error: Download reported success, but .deb file for '$pkg_name' not found in temp dir." >&2
        rm -rf "$tmp_download_dir"
        return 1
    fi

    # Move the file to the target directory
    mv "$tmp_download_dir/$deb_file_name" "$target_dir/"
    if [ $? -ne 0 ]; then
       echo "Error: Failed to move '$deb_file_name' to '$target_dir/' (Is '$target_dir' writable?)." >&2
       rm -rf "$tmp_download_dir" # Clean up temp dir anyway
       return 1
    fi

    # Clean up empty temp dir
    rm -rf "$tmp_download_dir"
    deb_file_path="$target_dir/$deb_file_name"

    echo "Download complete: '$deb_file_path'" >&2
    echo "$deb_file_path" # Return the full path
    return 0
}

# Function to install a local .deb file on a remote server via SSH
# (Used ONLY for Option 3 if offline file found)
install_deb_ssh() {
    local local_deb_path="$1"
    local remote_target="$2"
    local deb_basename=$(basename "$local_deb_path")
    local remote_tmp_path="/tmp/$deb_basename"

    echo "Attempting offline install of '$deb_basename' on remote server '$remote_target'..." >&2

    # 1. Copy file
    echo "Copying '$local_deb_path' to '$remote_target:$remote_tmp_path'..." >&2
    scp "$local_deb_path" "${remote_target}:$remote_tmp_path"
    if [ $? -ne 0 ]; then echo "Error: Failed to copy '$deb_basename' to remote server via SSH." >&2; return 1; fi
    echo "File copied successfully." >&2

    # 2. Install file (using apt to handle dependencies if possible)
    echo "Installing '$remote_tmp_path' on remote server (using sudo)..." >&2
    ssh "$remote_target" "sudo apt-get update && sudo apt install -y '$remote_tmp_path'"
    local install_exit_code=$?

    # 3. Cleanup remote file
    echo "Cleaning up '$remote_tmp_path' on remote server..." >&2
    ssh "$remote_target" "rm -f '$remote_tmp_path'"

    if [ $install_exit_code -ne 0 ]; then
        echo "Error: Failed to install '$deb_basename' from local file on remote server. Dependencies might be missing or file is incompatible." >&2
        return 1
    fi

    echo "Package '$deb_basename' installed successfully from local file." >&2
    return 0
}

# --- Common Packages List for Bulk Download ---
COMMON_PACKAGES=(
    "build-essential" "git" "curl" "wget" "htop" "mc" "vim" "net-tools"
    "unzip" "python3-pip" "ufw" "tmux" "tree" "jq" "openssh-server"
    "ca-certificates" "gnupg" "lsb-release" "ncdu" "sysstat" "acl"
    "rsync" "fail2ban" "logrotate" "sudo"
) # 25 packages


# --- Main Script Logic ---

# Display Menu
echo "-------------------------------------------"
echo " Package Installer Menu (v6.1)"
echo " Offline Cache Directory: $OFFLINE_DIR/"
echo "-------------------------------------------"
echo "1. Download single package .deb file locally"
echo "2. Install package in Docker Container (Always Online)"
echo "3. Install package on Remote Server (SSH) (Tries Offline first)"
echo "4. Bulk download common server packages to offline cache"
echo "-------------------------------------------"
read -p "Please enter your choice (1-4): " choice
echo ""

# Handle user choice
case $choice in
    1)
        # --- Option 1: Download Single Package ---
        read -p "Enter the package name to download: " package_name
        if [ -z "$package_name" ]; then echo "Error: Package name cannot be empty." >&2; exit 1; fi

        echo "Starting Option 1: Download '$package_name' to $OFFLINE_DIR/" >&2
        deb_filepath=$(download_package "$package_name" "$OFFLINE_DIR")
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "-------------------------------------------" >&2
            echo "✅ Success: Package downloaded as '$deb_filepath'." >&2
            echo "-------------------------------------------" >&2
            exit 0
        else
            echo "-------------------------------------------" >&2
            echo "❌ Operation failed during download." >&2
            echo "-------------------------------------------" >&2
            exit 1
        fi
        ;;

    2)
        # --- Option 2: Install in Docker Container (ALWAYS ONLINE) ---
        read -p "Enter the package name to install: " package_name
        read -p "Enter the Docker container name or ID: " container_id
        if [ -z "$package_name" ] || [ -z "$container_id" ]; then echo "Error: Package name and container ID cannot be empty." >&2; exit 1; fi

        echo "Starting Option 2: Install '$package_name' in Docker Container '$container_id' (Online Mode Only)" >&2

        # Check container status
        if ! docker ps -q -f name="^${container_id}$" -f status=running | grep -q .; then
            if ! docker ps -q -f id="^${container_id}$" -f status=running | grep -q .; then echo "Error: Container '$container_id' not found or is not running." >&2; exit 2; fi
        fi
        echo "Container '$container_id' found and running." >&2

        # Install directly inside the container using its apt-get (always online)
        echo "Attempting to update apt and install '$package_name' inside container '$container_id' (as root)..." >&2
        docker exec -u root "$container_id" bash -c "apt-get update && apt-get install -y $package_name"
        install_exit_code=$?

        # Report final status
        echo "-------------------------------------------" >&2
        if [ $install_exit_code -eq 0 ]; then
            echo "✅ Operation completed. '$package_name' should now be installed in '$container_id'." >&2
            exit 0
        else
            echo "❌ Operation failed to install '$package_name' in '$container_id'. Check errors above." >&2
            exit 1
        fi
        ;;

    3)
        # --- Option 3: Install on Remote Server (SSH) (Tries Offline First) ---
        read -p "Enter the package name to install: " package_name
        read -p "Enter the remote target (e.g., user@hostname or user@IP): " remote_target
        if [ -z "$package_name" ] || [ -z "$remote_target" ]; then echo "Error: Package name and remote target cannot be empty." >&2; exit 1; fi

        echo "Starting Option 3: Install '$package_name' on Remote Server '$remote_target'" >&2

        # Check for local offline package
        local_deb_path=$(ls -t "${OFFLINE_DIR}/${package_name}"_*.deb 2>/dev/null | head -n 1)

        install_success=false
        # If a local .deb file exists, try the offline installation function
        if [[ -n "$local_deb_path" && -f "$local_deb_path" ]]; then
            echo "Found local package: $local_deb_path. Attempting offline installation..." >&2
            install_deb_ssh "$local_deb_path" "$remote_target"
            if [ $? -eq 0 ]; then install_success=true; fi
        else
        # Otherwise, proceed with standard online installation
            echo "No local package found for '$package_name' in '$OFFLINE_DIR/'. Attempting online installation..." >&2
            ssh "$remote_target" "sudo apt-get update && sudo apt-get install -y $package_name"
            if [ $? -eq 0 ]; then install_success=true; fi
        fi

        # Report final status
        echo "-------------------------------------------" >&2
        if $install_success; then
            echo "✅ Operation completed. '$package_name' should now be installed on '$remote_target'." >&2
            exit 0
        else
            echo "❌ Operation failed to install '$package_name' on '$remote_target'. Check errors above." >&2
            exit 1
        fi
        ;;

    4)
        # --- Option 4: Bulk Download Common Packages ---
        echo "Starting Option 4: Bulk download common packages to '$OFFLINE_DIR/'" >&2
        successful_downloads=0
        failed_downloads=0
        total_packages=${#COMMON_PACKAGES[@]}

        echo "Packages to download: ${COMMON_PACKAGES[*]}" >&2

        for pkg in "${COMMON_PACKAGES[@]}"; do
            echo "--- Downloading $pkg ---" >&2
            # Call download_package but discard stdout path, just check exit code ($?)
            download_package "$pkg" "$OFFLINE_DIR" > /dev/null
            if [ $? -eq 0 ]; then
                ((successful_downloads++))
            else
                ((failed_downloads++))
                echo "Warning: Failed to download '$pkg'." >&2
            fi
        done

        echo "-------------------------------------------" >&2
        echo "Bulk Download Summary:" >&2
        echo "  Total Packages Attempted: $total_packages" >&2
        echo "  Successful Downloads: $successful_downloads" >&2
        echo "  Failed Downloads: $failed_downloads" >&2
        echo "  Downloaded packages are located in: $OFFLINE_DIR/" >&2
        echo "-------------------------------------------" >&2
        if [ $failed_downloads -gt 0 ]; then exit 1; else exit 0; fi # Exit with error if any download failed
        ;;

    *)
        echo "Invalid choice. Please enter a number between 1 and 4." >&2
        exit 1
        ;;
esac