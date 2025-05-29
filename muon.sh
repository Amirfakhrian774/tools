#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
MUON_VERSION="3.0.0"
MUON_JAR_NAME="muon.jar"
VERSIONED_JAR="muonssh_${MUON_VERSION}.jar"
MUON_JAR_URL="https://github.com/devlinx9/muon-ssh/releases/download/v${MUON_VERSION}/${VERSIONED_JAR}"
OPT_DIR="/opt/muon"
DESKTOP_FILE="$HOME/.local/share/applications/muon.desktop"

# Determine directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_PLAIN_JAR="$SCRIPT_DIR/$MUON_JAR_NAME"
LOCAL_VERSIONED_JAR="$SCRIPT_DIR/$VERSIONED_JAR"

# --- Error handler ---
function die() {
  echo "Error: $*" >&2
  exit 1
}

# 0) Ensure Java is installed
if ! command -v java &>/dev/null; then
  echo "Java not found. Attempting to install via apt..."
  if command -v apt &>/dev/null; then
    sudo apt update || echo "Warning: could not update package lists."
    sudo apt install -y openjdk-17-jre-headless \
      || die "Automatic Java install failed. Please install Java manually."
    echo "Java installed successfully."
  else
    die "apt not available. Please install Java manually."
  fi
fi

# 1) Locate or download Muon JAR
if [ -f "$LOCAL_PLAIN_JAR" ]; then
  echo "Found $MUON_JAR_NAME next to script, using it."
  SOURCE_JAR="$LOCAL_PLAIN_JAR"

elif [ -f "$LOCAL_VERSIONED_JAR" ]; then
  echo "Found $VERSIONED_JAR next to script, copying to $MUON_JAR_NAME."
  cp "$LOCAL_VERSIONED_JAR" "$LOCAL_PLAIN_JAR"
  SOURCE_JAR="$LOCAL_PLAIN_JAR"

else
  echo "No local JAR found. Downloading Muon SSH v${MUON_VERSION}..."
  DOWNLOAD_TARGET="$LOCAL_PLAIN_JAR"
  DOWNLOAD_FAILED=false

  if command -v curl &>/dev/null; then
    curl -L -o "$DOWNLOAD_TARGET" "$MUON_JAR_URL" || DOWNLOAD_FAILED=true
  elif command -v wget &>/dev/null; then
    wget -O "$DOWNLOAD_TARGET" "$MUON_JAR_URL" || DOWNLOAD_FAILED=true
  else
    DOWNLOAD_FAILED=true
  fi

  if [ "$DOWNLOAD_FAILED" = true ]; then
    die "Automatic download failed. Please download ${VERSIONED_JAR} from:\n  $MUON_JAR_URL"
  fi

  echo "Downloaded and saved as $MUON_JAR_NAME."
  SOURCE_JAR="$DOWNLOAD_TARGET"
fi

# 2) Install the JAR to /opt/muon
echo "Installing JAR to $OPT_DIR..."
sudo mkdir -p "$OPT_DIR"
sudo mv -f "$SOURCE_JAR" "${OPT_DIR}/muon.jar"
sudo chmod +x "${OPT_DIR}/muon.jar"

# 3) Create desktop launcher
echo "Creating desktop entry at $DESKTOP_FILE..."
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Muon SSH
Exec=java -jar ${OPT_DIR}/muon.jar
Icon=utilities-terminal
Categories=Network;TerminalEmulator;
StartupNotify=true
EOF
chmod +x "$DESKTOP_FILE"

# 4) Launch Muon in the background
echo "Installation complete! Launching Muon..."
nohup java -jar "${OPT_DIR}/muon.jar" >/dev/null 2>&1 &

echo "Done. You can now launch 'Muon SSH' from your applications menu."
