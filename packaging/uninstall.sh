#!/bin/bash
set -euo pipefail

# NovelKV Uninstallation Script
# Usage: sudo ./uninstall.sh [--purge]

PURGE=false
BIN_DIR="/usr/local/bin"
DATA_DIR="/var/lib/novelkv"
LOG_DIR="/var/log/novelkv"
CONFIG_DIR="/etc/novelkv"
SERVICE_USER="novelkv"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge)
            PURGE=true
            shift
            ;;
        --help|-h)
            echo "Usage: sudo ./uninstall.sh [--purge]"
            echo ""
            echo "  --purge   Remove data and configuration files too"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

echo "=== NovelKV Uninstaller ==="

if systemctl is-active --quiet novelkv 2>/dev/null; then
    echo "[1/5] Stopping service..."
    systemctl stop novelkv
else
    echo "[1/5] Service not running"
fi

if systemctl is-enabled --quiet novelkv 2>/dev/null; then
    echo "[2/5] Disabling service..."
    systemctl disable novelkv
else
    echo "[2/5] Service not enabled"
fi

echo "[3/5] Removing systemd unit..."
rm -f /etc/systemd/system/novelkv.service
systemctl daemon-reload

echo "[4/5] Removing binary..."
rm -f "$BIN_DIR/novelkv"

if id "$SERVICE_USER" &>/dev/null; then
    echo "[5/5] Removing service user..."
    userdel "$SERVICE_USER" 2>/dev/null || true
else
    echo "[5/5] User already removed"
fi

if [[ "$PURGE" == "true" ]]; then
    echo ""
    echo "WARNING: Removing all NovelKV data and configuration!"
    read -p "Type YES to confirm: " CONFIRM
    if [[ "$CONFIRM" == "YES" ]]; then
        rm -rf "$DATA_DIR"
        rm -rf "$CONFIG_DIR"
        rm -rf "$LOG_DIR"
        echo "  Data and configuration removed."
    else
        echo "  Purge cancelled. Data preserved at:"
        echo "    $DATA_DIR"
        echo "    $CONFIG_DIR"
    fi
else
    echo ""
    echo "Data and configuration preserved. To remove:"
    echo "  sudo rm -rf $DATA_DIR"
    echo "  sudo rm -rf $CONFIG_DIR"
    echo "  sudo rm -rf $LOG_DIR"
fi

echo ""
echo "=== Uninstall complete ==="
