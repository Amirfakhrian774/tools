#!/usr/bin/env bash
set -euo pipefail

### پیکربندی متغیرها ###
MUON_VERSION="3.0.0"
MUON_JAR_NAME="muon.jar"
MUON_JAR_URL="https://github.com/devlinx9/muon-ssh/releases/download/v${MUON_VERSION}/muonssh_${MUON_VERSION}.jar"
OPT_DIR="/opt/muon"
DESKTOP_FILE="$HOME/.local/share/applications/muon.desktop"

### تابع نمایش خطا و خروج ###
function die() {
  echo "❌ خطا: $*" >&2
  exit 1
}

### ۰) بررسی و نصب Java ###
if ! command -v java &>/dev/null; then
  echo "Java پیدا نشد. سعی در نصب با apt دارم..."
  if command -v apt &>/dev/null; then
    sudo apt update || echo "آفلاین یا مخازن دردسترس نیست."  
    if sudo apt install -y openjdk-17-jre-headless; then
      echo "Java با موفقیت نصب شد."
    else
      die "نصب خودکار Java شکست خورد. لطفاً فایل OpenJDK tar.gz را دانلود کرده و کنار این اسکریپت قرار دهید."
    fi
  else
    die "apt موجود نیست. لطفاً Java را دستی نصب کنید یا OpenJDK tar.gz را کنار این اسکریپت قرار دهید."
  fi
fi

### ۱) دانلود Muon JAR ###
if [ ! -f "$MUON_JAR_NAME" ]; then
  echo "درحال دانلود Muon SSH v${MUON_VERSION}..."
  if command -v curl &>/dev/null; then
    curl -L -o "$MUON_JAR_NAME" "$MUON_JAR_URL" || DOWNLOAD_FAILED=true
  elif command -v wget &>/dev/null; then
    wget -O "$MUON_JAR_NAME" "$MUON_JAR_URL" || DOWNLOAD_FAILED=true
  else
    DOWNLOAD_FAILED=true
  fi

  if [ "${DOWNLOAD_FAILED:-false}" = true ]; then
    die "دانلود خودکار Muon شکست خورد. لطفاً فایل ${MUON_JAR_NAME} را از این آدرس دانلود کرده و کنار اسکریپت قرار دهید:\n  $MUON_JAR_URL"
  fi
fi

### ۲) ایجاد پوشه /opt/muon و انتقال فایل ###
echo "ایجاد پوشه ${OPT_DIR} و انتقال JAR..."
sudo mkdir -p "$OPT_DIR"
sudo mv -f "$MUON_JAR_NAME" "${OPT_DIR}/muon.jar"
sudo chmod +x "${OPT_DIR}/muon.jar"

### ۳) ساخت لانچر دسکتاپ ###
echo "ساخت فایل دسکتاپ در ${DESKTOP_FILE}..."
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

### ۴) اجرای Muon ###
echo "نصب کامل شد! در حال اجرای Muon..."
nohup java -jar "${OPT_DIR}/muon.jar" >/dev/null 2>&1 &

echo "✅ تمام شد. اکنون می‌توانید از منوی برنامه‌ها Muon SSH را اجرا کنید."
