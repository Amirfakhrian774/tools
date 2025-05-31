#!/bin/bash

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

timestamp=$(date +"%Y%m%d_%H%M%S")
log_file="offline_pkg_log_$timestamp.txt"

download_packages() {
  read -p "Enter package names (comma separated, e.g., docker.io, curl, git): " PACKAGE_LIST
  read -p "Enter target directory for download (absolute path): " TARGET_DIR

  mkdir -p "$TARGET_DIR/packages"
  cd "$TARGET_DIR/packages"

  IFS=',' read -ra PACKAGES <<< "$PACKAGE_LIST"

  echo -e "${GREEN}Downloading packages and dependencies...${NC}" | tee -a "$TARGET_DIR/$log_file"

  sudo apt update >> "$TARGET_DIR/$log_file"

  for PACKAGE in "${PACKAGES[@]}"; do
    PACKAGE=$(echo "$PACKAGE" | xargs)
    echo -e "\n>>> Processing $PACKAGE" | tee -a "$TARGET_DIR/$log_file"

    apt-rdepends "$PACKAGE" 2>/dev/null | grep -v "^ " | while read pkg; do
      if apt-cache show "$pkg" >/dev/null 2>&1; then
        echo "Downloading $pkg" | tee -a "$TARGET_DIR/$log_file"
        apt download "$pkg" >> "$TARGET_DIR/$log_file" 2>&1 || echo "[!] Failed: $pkg" | tee -a "$TARGET_DIR/$log_file"
      else
        echo "Skipping virtual package: $pkg" | tee -a "$TARGET_DIR/$log_file"
      fi
    done
  done

  echo -e "${GREEN}Creating install script...${NC}"
  cat > "$TARGET_DIR/packages/install.sh" << 'EOF'
#!/bin/bash
set -e
echo "Installing .deb packages in this directory..."
sudo dpkg -i *.deb || sudo apt --fix-broken install -y
echo "Installation complete."
EOF
  chmod +x "$TARGET_DIR/packages/install.sh"

  echo -e "${GREEN}Packaging files...${NC}"
  cd "$TARGET_DIR"
  tar -czvf "offline-packages_$timestamp.tar.gz" packages >> "$log_file" 2>&1

  echo -e "${GREEN}Done. Archive created:${NC} $TARGET_DIR/offline-packages_$timestamp.tar.gz"
}

install_packages() {
  read -p "Enter directory containing .deb files: " INSTALL_DIR

  if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${RED}Directory not found!${NC}"
    exit 1
  fi

  cd "$INSTALL_DIR"
  echo -e "${GREEN}Installing .deb packages from: $INSTALL_DIR${NC}" | tee "$log_file"
  sudo dpkg -i *.deb >> "$log_file" 2>&1 || {
    echo -e "${RED}Some dependencies missing. Trying to fix...${NC}"
    sudo apt --fix-broken install -y >> "$log_file" 2>&1
  }

  echo -e "${GREEN}Installation complete.${NC}"
}

main_menu() {
  echo "Select an option:"
  echo "1) Download packages and dependencies (multi-package, offline mode)"
  echo "2) Install packages from local folder"
  echo "3) Exit"
  read -p "Enter choice [1-3]: " CHOICE

  case $CHOICE in
    1) download_packages ;;
    2) install_packages ;;
    3) exit 0 ;;
    *) echo "Invalid choice"; main_menu ;;
  esac
}

while true; do
  main_menu
done
