#!/bin/bash
set -euo pipefail

# NovelKV Installation Script
# Usage: sudo ./install.sh [--prefix /opt/novelkv]

PREFIX="/usr/local"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="novelkv"
SERVICE_USER="novelkv"
SERVICE_GROUP="novelkv"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: sudo ./install.sh [--prefix /path]"
            echo ""
            echo "Options:"
            echo "  --prefix PATH   Installation prefix (default: /usr/local)"
            echo "                  Binary:   PREFIX/bin/novelkv"
            echo "                  Config:   /etc/novelkv/"
            echo "                  Data:     /var/lib/novelkv/"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

BIN_DIR="$PREFIX/bin"
DATA_DIR="/var/lib/novelkv"
LOG_DIR="/var/log/novelkv"
CONFIG_DIR="/etc/novelkv"

echo "=== NovelKV Installer ==="
echo "  Binary:   $BIN_DIR/$BIN_NAME"
echo "  Config:   $CONFIG_DIR/novelkv.conf"
echo "  Data:     $DATA_DIR"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/$BIN_NAME" ]]; then
    echo "ERROR: Binary not found: $SCRIPT_DIR/$BIN_NAME"
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    echo "ERROR: systemctl not found. This installer requires systemd."
    exit 1
fi

# Stop existing service if upgrading
if systemctl is-active --quiet novelkv 2>/dev/null; then
    echo "[upgrade] Stopping existing NovelKV service..."
    systemctl stop novelkv
fi

echo "[1/7] Installing binary to $BIN_DIR/..."
mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/$BIN_NAME" "$BIN_DIR/$BIN_NAME"
chmod 755 "$BIN_DIR/$BIN_NAME"

echo "[2/7] Creating service user..."
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system \
            --no-create-home \
            --home-dir "$DATA_DIR" \
            --shell /usr/sbin/nologin \
            "$SERVICE_USER"
    echo "  Created user: $SERVICE_USER"
else
    echo "  User $SERVICE_USER already exists"
fi

echo "[3/7] Creating directories..."
mkdir -p "$DATA_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$CONFIG_DIR"

echo "[4/7] Installing configuration..."
if [[ -f "$CONFIG_DIR/novelkv.conf" ]]; then
    echo "  Existing config found at $CONFIG_DIR/novelkv.conf -- preserving"
    echo "  New defaults available at $CONFIG_DIR/novelkv.conf.example"
    cp "$SCRIPT_DIR/novelkv.conf" "$CONFIG_DIR/novelkv.conf.example"
else
    cp "$SCRIPT_DIR/novelkv.conf" "$CONFIG_DIR/novelkv.conf"
    echo "  Installed $CONFIG_DIR/novelkv.conf"
fi
chmod 600 "$CONFIG_DIR/novelkv.conf"

echo "[5/7] Installing systemd service..."
sed "s|__BIN_PATH__|$BIN_DIR/$BIN_NAME|g" \
    "$SCRIPT_DIR/novelkv.service" > /etc/systemd/system/novelkv.service
chmod 644 /etc/systemd/system/novelkv.service

echo "[6/7] Setting file ownership..."
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR"
chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/novelkv.conf"

echo "[7/7] Enabling and starting service..."
systemctl daemon-reload
systemctl enable novelkv

echo ""
echo "=== Installation complete ==="
echo ""
echo "To start the service:"
echo "  sudo systemctl start novelkv"
echo ""
echo "To check status:"
echo "  sudo systemctl status novelkv"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u novelkv -f"
echo ""
echo "Configuration file: $CONFIG_DIR/novelkv.conf"
echo "Data directory:     $DATA_DIR"
echo ""
echo "IMPORTANT: Edit $CONFIG_DIR/novelkv.conf"
echo "           to set password (--requirepass) and other options"
echo "           before starting in production."
