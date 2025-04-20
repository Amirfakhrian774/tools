#!/bin/bash

# === Script for Preparing and Installing Offline APT Repositories ===
# Version: 8.4 (Strip quotes from target image input)

# --- Configuration ---
OFFLINE_REPO_BASE_DIR="offline_repo" # Directory to store prepared offline repositories on this host machine

# Ensure the base directory exists
mkdir -p "$OFFLINE_REPO_BASE_DIR"
if [ ! -d "$OFFLINE_REPO_BASE_DIR" ]; then
    echo "Error: Base directory '$OFFLINE_REPO_BASE_DIR' could not be created or is not a directory." >&2
    exit 1
fi

# --- Check Host Dependencies ---
host_docker_ok=true
host_dpkg_dev_ok=true
if ! command -v docker &> /dev/null; then
    echo "Warning: 'docker' command not found. Docker is required for preparing offline repositories (Option 1)." >&2
    host_docker_ok=false
fi
if ! command -v dpkg-scanpackages &> /dev/null; then
    echo "Warning: 'dpkg-scanpackages' command not found. Required for Option 1." >&2
    echo "         To install it (on Debian/Ubuntu), run this command:" >&2
    echo "           sudo apt update && sudo apt install dpkg-dev" >&2
    host_dpkg_dev_ok=false
fi

# --- Common Packages List for Bulk Prep ---
COMMON_PACKAGES=(
    "build-essential" "git" "curl" "wget" "htop" "mc" "vim" "net-tools" "unzip" "python3-pip"
    "ufw" "tmux" "tree" "jq" "openssh-server" "ca-certificates" "gnupg" "lsb-release" "ncdu"
    "sysstat" "acl" "rsync" "fail2ban" "logrotate" "sudo" "openjdk-17-jdk-headless" "ca-certificates-java"
) # ~27 packages


# --- Helper Functions ---
check_container() { local container_id="$1"; if ! docker ps -q -f name="^${container_id}$" -f status=running | grep -q .; then if ! docker ps -q -f id="^${container_id}$" -f status=running | grep -q .; then echo "Error: Container '$container_id' not found or is not running." >&2; return 1; fi; fi; echo "Container '$container_id' found and running." >&2; return 0; }
sanitize_tag() { echo "$1" | tr -c '[:alnum:]-_.' '_'; }
download_package() {
    # This function is kept for potential future use but is not currently called by main options
    # Its logic was integrated into Option 1's Docker-based download process
    echo "Error: download_package function is deprecated in this script version." >&2
    return 1
}
install_deb_ssh() {
    # This function is kept for potential future use but is not currently called by main options
    # Its logic needs review if re-enabled, as Option 3 now uses full repo install
     echo "Error: install_deb_ssh function is deprecated in this script version." >&2
    return 1
}


# --- Main Script Logic ---
echo "-------------------------------------------"
echo " Offline APT Repository Manager (v8.4)"
echo " Host Repo Base Directory: $OFFLINE_REPO_BASE_DIR/"
echo "-------------------------------------------"
echo "1. Prepare Offline Repository (Needs Internet & Docker on Host)"
echo "2. Install Offline Repo to Docker Container (Target needs NO Internet)"
echo "3. Install Offline Repo to Remote Server (SSH) (Target needs NO Internet)"
echo "-------------------------------------------"
read -p "Please enter your choice (1-3): " choice
echo ""

case $choice in
    1)
        # --- Option 1: Prepare Offline Repository ---
        echo "[Option 1 Selected: Prepare Offline Repository]"
        if ! $host_docker_ok || ! $host_dpkg_dev_ok ; then
             echo "---------------------------------------------------------------------" >&2; echo "Error: Prerequisites missing for preparing offline repositories." >&2
             if ! $host_docker_ok; then echo "  - 'docker' command not found. Please install Docker first." >&2; fi
             if ! $host_dpkg_dev_ok; then echo "  - 'dpkg-scanpackages' command not found." >&2; echo "  - To install it (on Debian/Ubuntu), run this command:" >&2; echo "      sudo apt update && sudo apt install dpkg-dev" >&2; fi
             echo "---------------------------------------------------------------------" >&2; exit 1
        fi

        # --- Get Target OS Info ---
        echo ""; echo "IMPORTANT: This step downloads packages and dependencies based on your target OS."; echo "To ensure compatibility, you must first identify the target operating system details."
        echo ""; echo "  * If Target is an SSH server:"; echo "    Run the following commands ON THE TARGET SERVER:"; echo "      cat /etc/os-release"; echo "      lsb_release -a"
        echo ""; echo "  * If Target is a Docker container:"; echo "    Run the following command ON THIS HOST machine:"; echo "      docker exec <container_id> cat /etc/os-release"
        echo ""; echo "Look for values like ID=debian and VERSION_CODENAME=bullseye, or ID=ubuntu and VERSION_ID=\"22.04\"."
        echo "Based on this information, find the corresponding official Docker Hub image tag"; echo "(e.g., 'debian:bullseye', 'ubuntu:22.04', 'ubuntu:jammy')."
        echo "---------------------------------------------------------------------"
        read -p "Enter the Target OS Docker Image tag discovered above: " target_image

        # --- Clean the input ---
        target_image_cleaned=$(echo "$target_image" | sed "s/^['\"]*//; s/['\"]*$//") # Remove surrounding quotes

        if [ -z "$target_image_cleaned" ]; then echo "Error: Target OS image cannot be empty after cleaning quotes." >&2; exit 1; fi
        target_os_tag=$(sanitize_tag "$target_image_cleaned") # Use cleaned version for dir name

        # --- Get Package Info ---
        packages_to_prep=(); repo_name=""
        read -p "Prepare for [S]ingle package or [G]roup (common server packages)? (S/G): " prep_type
        if [[ "$prep_type" =~ ^[Ss]$ ]]; then read -p "Enter the single package name: " single_pkg; if [ -z "$single_pkg" ]; then echo "Error: Package name cannot be empty." >&2; exit 1; fi; packages_to_prep=("$single_pkg"); repo_name=$(sanitize_tag "$single_pkg")
        elif [[ "$prep_type" =~ ^[Gg]$ ]]; then echo "Using common server packages list."; packages_to_prep=("${COMMON_PACKAGES[@]}"); repo_name="common_server_pkgs"
        else echo "Error: Invalid choice." >&2; exit 1; fi

        repo_path="$OFFLINE_REPO_BASE_DIR/$target_os_tag/$repo_name"; repo_debs_path="$repo_path/debs"
        echo "Repository will be prepared in: $repo_path"; mkdir -p "$repo_debs_path"; if [ ! -d "$repo_debs_path" ]; then echo "Error: Could not create directory '$repo_debs_path'." >&2; exit 1; fi

        # --- Start Temporary Container ---
        container_name="offline-prep-$(date +%s)"
        echo "Starting temporary container '$container_name' from image '$target_image_cleaned'..." # Use cleaned name
        if ! docker run --rm --name "$container_name" -d "$target_image_cleaned" sleep infinity > /dev/null; then echo "Error: Failed to start temporary container from image '$target_image_cleaned'. Is the image pulled/valid?" >&2; exit 1; fi # Use cleaned name in error
        trap "echo 'Stopping temporary container $container_name...'; docker stop $container_name > /dev/null || true" EXIT

        echo "Container started. Updating APT lists inside container..."; if ! docker exec "$container_name" bash -c "apt-get update -qq"; then echo "Error: Failed to run apt-get update inside container." >&2; exit 1; fi; echo "APT lists updated."

        # --- Download Packages and Dependencies ---
        echo "Attempting to download packages (and dependencies): ${packages_to_prep[*]}"; failed_pkg_download=false
        for pkg in "${packages_to_prep[@]}"; do echo "  Downloading: $pkg ..."; if ! docker exec "$container_name" bash -c "apt-get install --download-only -y $pkg" >&2 ; then echo "Warning: Failed to process/download package '$pkg' or its dependencies." >&2; failed_pkg_download=true; fi; done
        echo "Package download process completed."

        # --- Copy DEBs Out ---
        echo "Copying downloaded .deb files from container to host's '$repo_debs_path'..."; copied_files=false
        if ! docker cp "${container_name}:/var/cache/apt/archives/." "$repo_debs_path/"; then
            if docker exec "$container_name" bash -c '[ -z "$(ls -A /var/cache/apt/archives)" ]'; then echo "Warning: No .deb files found in container's apt cache." >&2; else echo "Error: Failed to copy .deb files from container." >&2; exit 1; fi
        else if [ -n "$(ls -A "$repo_debs_path/" 2>/dev/null)" ]; then echo ".deb files copied."; copied_files=true; else echo "Warning: No .deb files seem to have been copied." >&2; fi; fi

        # --- Generate Packages.gz ---
        echo "Generating APT repository metadata (Packages.gz)..."
        if $copied_files && [ -n "$(ls -A "$repo_debs_path/"*.deb 2>/dev/null)" ]; then
             (cd "$repo_debs_path" && dpkg-scanpackages . /dev/null | gzip -c > Packages.gz)
             if [ $? -ne 0 ]; then echo "Error: dpkg-scanpackages failed." >&2; exit 1; fi; echo "Repository metadata created successfully."
        else echo "Skipping metadata generation as no .deb files were found/copied."; if ! $failed_pkg_download && ! $copied_files; then echo "Warning: Investigate needed." >&2; fi; fi

        trap - EXIT; echo "Stopping temporary container $container_name..."; docker stop "$container_name" > /dev/null

        # --- Report ---
        echo "-------------------------------------------" >&2
        if $failed_pkg_download; then echo "⚠️ Preparation completed with warnings/failures during download." >&2; else echo "✅ Preparation Complete!" >&2; fi
        echo "   Offline repository prepared at: $repo_path"; echo "   Transfer this directory to the target and use Option 2 or 3." >&2
        echo "-------------------------------------------" >&2
        if $failed_pkg_download; then exit 1; else exit 0; fi
        ;;

    2)
        # --- Option 2: Install Offline Repo to Docker Container ---
        echo "[Option 2 Selected: Install Offline Repo to Docker Container]"
        read -p "Enter path to the prepared host repository directory: " host_repo_path; read -p "Enter the target Docker container name or ID: " container_id; read -p "Enter the main package(s) to install (space-separated): " packages_to_install
        if [ ! -d "$host_repo_path/debs" ]; then echo "Error: Repo '$host_repo_path/debs' not found." >&2; exit 1; fi; if [ -z "$container_id" ]; then echo "Error: Container ID cannot be empty." >&2; exit 1; fi; if [ -z "$packages_to_install" ]; then echo "Error: Package(s) to install cannot be empty." >&2; exit 1; fi
        check_container "$container_id" || exit 2

        container_repo_path="/tmp/offline-repo-$(date +%s)"; container_sources_dir="/etc/apt/sources.list.d"; container_offline_list="$container_sources_dir/offline.list"; host_backup_dir="$OFFLINE_REPO_BASE_DIR/.${container_id}.sources.bak"; container_main_sources_file="/etc/apt/sources.list"; echo "Starting Offline Installation for '$container_id'..."

        echo "Backing up container's APT sources to host:'$host_backup_dir'..."; rm -rf "$host_backup_dir"; mkdir -p "$host_backup_dir/sources.list.d"
        docker cp "${container_id}:$container_main_sources_file" "$host_backup_dir/sources.list" >/dev/null 2>&1 || echo "Warning: Failed to backup $container_main_sources_file" >&2
        docker cp "${container_id}:$container_sources_dir/." "$host_backup_dir/sources.list.d/" >/dev/null 2>&1 || echo "Warning: Failed to backup $container_sources_dir contents" >&2

        echo "Transferring repository '$host_repo_path' to container path '$container_repo_path'..."
        if ! docker cp "$host_repo_path/." "$container_id:$container_repo_path/"; then echo "Error: Failed to copy repository to container." >&2; exit 1; fi

        echo "Configuring APT sources in container for offline repo..."; repo_line="deb [trusted=yes] file:${container_repo_path}/debs ./"
        mod_sources_cmd="mkdir -p '$container_sources_dir' && rm -f $container_sources_dir/* && sed -i.bak 's/^\\s*deb/#deb/' $container_main_sources_file && echo '$repo_line' > '$container_offline_list'"
        if ! docker exec -u root "$container_id" bash -c "$mod_sources_cmd"; then echo "Error: Failed to modify APT sources inside container." >&2; echo "Attempting to restore original sources..." >&2; docker cp "$host_backup_dir/sources.list" "${container_id}:$container_main_sources_file" >/dev/null 2>&1; docker cp "$host_backup_dir/sources.list.d/." "${container_id}:$container_sources_dir/" >/dev/null 2>&1; docker exec -u root "$container_id" rm -rf "$container_repo_path"; exit 1; fi

        echo "Running apt update and installing '$packages_to_install' from offline repo..."
        install_cmd="apt-get update -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowDowngradeToInsecureRepositories=true && apt-get install -y --allow-unauthenticated $packages_to_install"; install_success=false
        if docker exec -u root "$container_id" bash -c "$install_cmd"; then install_success=true; else echo "Error: apt-get install failed inside container." >&2; fi

        echo "Restoring original APT sources in container..."; docker cp "$host_backup_dir/sources.list" "${container_id}:$container_main_sources_file" >/dev/null 2>&1; docker cp "$host_backup_dir/sources.list.d/." "${container_id}:$container_sources_dir/" >/dev/null 2>&1; if [ $? -ne 0 ]; then echo "Warning: Failed to restore original sources." >&2; fi
        echo "Removing temporary offline repository from container..."; docker exec -u root "$container_id" rm -rf "$container_repo_path"

        echo "-------------------------------------------" >&2; if $install_success; then echo "✅ Offline installation completed successfully." >&2; exit 0; else echo "❌ Offline installation failed." >&2; exit 1; fi
        ;;

    3)
        # --- Option 3: Install Offline Repo to Remote Server (SSH) ---
        echo "[Option 3 Selected: Install Offline Repo to Remote Server (SSH)]"
        read -p "Enter path to the prepared host repository directory: " host_repo_path; read -p "Enter the remote target (user@hostname): " remote_target; read -p "Enter the main package(s) to install (space-separated): " packages_to_install
        if [ ! -d "$host_repo_path/debs" ]; then echo "Error: Repo '$host_repo_path/debs' not found." >&2; exit 1; fi; if [ -z "$remote_target" ]; then echo "Error: Remote target cannot be empty." >&2; exit 1; fi; if [ -z "$packages_to_install" ]; then echo "Error: Package(s) to install cannot be empty." >&2; exit 1; fi

        remote_repo_path="/tmp/offline-repo-$(date +%s)"; remote_sources_dir="/etc/apt/sources.list.d"; remote_offline_list="$remote_sources_dir/offline.list"; remote_main_sources_file="/etc/apt/sources.list"; remote_backup_dir="/tmp/sources.bak.$(date +%s)"; echo "Starting Offline Installation on '$remote_target'..."

        echo "Backing up remote APT sources to '$remote_backup_dir' on target..."; backup_cmd="sudo mkdir -p '$remote_backup_dir/sources.list.d' && sudo cp -a '$remote_main_sources_file' '$remote_backup_dir/sources.list' && sudo cp -a '$remote_sources_dir/.' '$remote_backup_dir/sources.list.d/' || echo 'Backup Warning'"
        if ! ssh "$remote_target" "$backup_cmd"; then echo "Warning: Failed to backup remote sources." >&2; fi

        echo "Transferring repository '$host_repo_path' to remote path '$remote_repo_path'..."
        if ! scp -r "$host_repo_path/." "${remote_target}:$remote_repo_path/"; then echo "Error: Failed to copy repository via scp." >&2; exit 1; fi

        echo "Configuring APT sources on remote server for offline repo..."; repo_line="deb [trusted=yes] file:${remote_repo_path}/debs ./"
        mod_sources_cmd="sudo mkdir -p '$remote_sources_dir'; sudo rm -f ${remote_sources_dir}/* && sudo sed -i.orig.\$(date +%s) 's/^\\s*deb\\b/#deb/' '$remote_main_sources_file' && echo '$repo_line' | sudo tee '$remote_offline_list' > /dev/null"
        if ! ssh "$remote_target" "$mod_sources_cmd"; then echo "Error: Failed to modify APT sources on remote server." >&2; echo "Attempting cleanup of remote repo..." >&2; ssh "$remote_target" "sudo rm -rf '$remote_repo_path'"; echo "Check remote APT sources manually." >&2; exit 1; fi

        echo "Running apt update and installing '$packages_to_install' from offline repo on remote..."
        install_cmd="sudo apt-get update -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowDowngradeToInsecureRepositories=true && sudo apt-get install -y --allow-unauthenticated $packages_to_install"; install_success=false
        if ssh "$remote_target" "$install_cmd"; then install_success=true; else echo "Error: apt-get install failed on remote server." >&2; fi

        echo "Restoring original APT sources on remote server..."; restore_cmd="[ -f '${remote_main_sources_file}.orig.'* ] && sudo mv '${remote_main_sources_file}.orig.'* '$remote_main_sources_file' 2>/dev/null || sudo cp -a '$remote_backup_dir/sources.list' '$remote_main_sources_file'; sudo rm -f ${remote_sources_dir}/*; sudo cp -a '${remote_backup_dir}/sources.list.d/.' '$remote_sources_dir/'; sudo rm -rf '$remote_backup_dir'"
        if ! ssh "$remote_target" "$restore_cmd"; then echo "Warning: Failed to automatically restore original sources on remote." >&2; fi
        echo "Removing temporary offline repository from remote server..."; ssh "$remote_target" "sudo rm -rf '$remote_repo_path'"

        echo "-------------------------------------------" >&2; if $install_success; then echo "✅ Offline installation completed successfully." >&2; exit 0; else echo "❌ Offline installation failed." >&2; exit 1; fi
        ;;

    *)
        echo "Invalid choice. Please enter a number between 1 and 3." >&2
        exit 1
        ;;
esac
