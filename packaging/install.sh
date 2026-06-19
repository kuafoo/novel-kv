#!/bin/bash
set -euo pipefail

# NovelKV Installation Script
# Usage: sudo ./install.sh [OPTIONS]
#
# Interactive mode (default on tty):
#   sudo ./install.sh
#
# Non-interactive mode:
#   sudo ./install.sh --port 16379 --data /data --password mysecret --non-interactive

PREFIX="/usr/local"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="novelkv"
SERVICE_USER="novelkv"
SERVICE_GROUP="novelkv"

# Config defaults
CONF_HOST="0.0.0.0"
CONF_PORT="6379"
CONF_DATA="/var/lib/novelkv"
CONF_PASSWORD=""
CONF_UPGRADE=false
NON_INTERACTIVE=false

usage() {
    echo "Usage: sudo ./install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --prefix PATH          Installation prefix (default: /usr/local)"
    echo "  --host ADDR            Listen address (default: 0.0.0.0)"
    echo "  --port PORT            Listen port (default: 6379)"
    echo "  --data PATH            Data directory (default: /var/lib/novelkv)"
    echo "  --password PASS        Authentication password"
    echo "  --non-interactive      Non-interactive mode, use defaults/cli args"
    echo "  --help                 Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --host)
            CONF_HOST="$2"
            shift 2
            ;;
        --port)
            CONF_PORT="$2"
            shift 2
            ;;
        --data)
            CONF_DATA="$2"
            shift 2
            ;;
        --password)
            CONF_PASSWORD="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

BIN_DIR="$PREFIX/bin"
LOG_DIR="/var/log/novelkv"
CONFIG_DIR="/etc/novelkv"

# Detect existing installation
if [[ -f "$CONFIG_DIR/novelkv.conf" ]]; then
    CONF_UPGRADE=true
fi

# If not on a tty, force non-interactive
if ! tty -s 2>/dev/null; then
    NON_INTERACTIVE=true
fi

echo "=== NovelKV Installer ==="
echo ""

# --- Collect configuration ---
if [[ "$NON_INTERACTIVE" == "false" ]]; then
    echo "Configuration (press Enter to accept default):"
    echo ""

    read -p "  Listen address [$CONF_HOST]: " input
    [[ -n "$input" ]] && CONF_HOST="$input"

    read -p "  Listen port [$CONF_PORT]: " input
    [[ -n "$input" ]] && CONF_PORT="$input"

    read -p "  Data directory [$CONF_DATA]: " input
    [[ -n "$input" ]] && CONF_DATA="$input"

    while true; do
        read -s -p "  Password (required): " input
        echo ""
        if [[ -n "$input" ]]; then
            CONF_PASSWORD="$input"
            break
        fi
        echo "  ERROR: Password is required"
    done

    echo ""
    echo "--- Configuration Summary ---"
    echo "  Binary:   $BIN_DIR/$BIN_NAME"
    echo "  Config:   $CONFIG_DIR/novelkv.conf"
    echo "  Data:     $CONF_DATA"
    echo "  Listen:   $CONF_HOST:$CONF_PORT"
    echo "  Auth:     enabled"
    echo ""

    read -p "Proceed with installation? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# Validate password in non-interactive mode
if [[ "$NON_INTERACTIVE" == "true" && -z "$CONF_PASSWORD" && "$CONF_UPGRADE" == "false" ]]; then
    echo "WARNING: No password set. Consider using --password for production."
fi

echo "  Binary:   $BIN_DIR/$BIN_NAME"
echo "  Config:   $CONFIG_DIR/novelkv.conf"
echo "  Data:     $CONF_DATA"
echo "  Listen:   $CONF_HOST:$CONF_PORT"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# --- System environment checks ---
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    echo "ERROR: Unsupported architecture: $ARCH (requires x86_64)"
    exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: Unsupported OS: $(uname -s) (requires Linux)"
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    echo "ERROR: systemctl not found. This installer requires systemd."
    exit 1
fi

# Check binary is executable on this system
if [[ ! -f "$SCRIPT_DIR/$BIN_NAME" ]]; then
    echo "ERROR: Binary not found: $SCRIPT_DIR/$BIN_NAME"
    exit 1
fi
if ! file "$SCRIPT_DIR/$BIN_NAME" 2>/dev/null | grep -q "ELF"; then
    echo "ERROR: Binary is not a valid ELF executable: $SCRIPT_DIR/$BIN_NAME"
    exit 1
fi

# Stop existing service if upgrading
if systemctl is-active --quiet novelkv 2>/dev/null; then
    echo "[upgrade] Stopping existing NovelKV service..."
    systemctl stop novelkv
fi

echo "[1/8] Installing binary to $BIN_DIR/..."
mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/$BIN_NAME" "$BIN_DIR/$BIN_NAME"
chmod 755 "$BIN_DIR/$BIN_NAME"

echo "[2/8] Creating service user..."
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system \
            --no-create-home \
            --home-dir "$CONF_DATA" \
            --shell /usr/sbin/nologin \
            "$SERVICE_USER"
    echo "  Created user: $SERVICE_USER"
else
    echo "  User $SERVICE_USER already exists"
fi

echo "[3/8] Creating directories..."
mkdir -p "$CONF_DATA"
mkdir -p "$LOG_DIR"
mkdir -p "$CONFIG_DIR"

echo "[4/8] Writing configuration..."
if [[ "$CONF_UPGRADE" == "true" ]]; then
    # Upgrade: preserve existing config, install new as .example
    echo "  Existing config found at $CONFIG_DIR/novelkv.conf -- preserving"
    cp "$SCRIPT_DIR/novelkv.conf" "$CONFIG_DIR/novelkv.conf.example"
    echo "  New defaults available at $CONFIG_DIR/novelkv.conf.example"
else
    # Fresh install: generate config from template
    cp "$SCRIPT_DIR/novelkv.conf" "$CONFIG_DIR/novelkv.conf"
    sed -i "s|^host .*|host $CONF_HOST|" "$CONFIG_DIR/novelkv.conf"
    sed -i "s|^port .*|port $CONF_PORT|" "$CONFIG_DIR/novelkv.conf"
    sed -i "s|^data .*|data $CONF_DATA|" "$CONFIG_DIR/novelkv.conf"
    if [[ -n "$CONF_PASSWORD" ]]; then
        sed -i "s|^# requirepass .*|requirepass $CONF_PASSWORD|" "$CONFIG_DIR/novelkv.conf"
    fi
    echo "  Installed $CONFIG_DIR/novelkv.conf"
fi
chmod 600 "$CONFIG_DIR/novelkv.conf"

if [[ ! -f "$CONFIG_DIR/novelkv.env" ]]; then
    cp "$SCRIPT_DIR/novelkv.env" "$CONFIG_DIR/novelkv.env"
    # If data dir is non-default, pass it via CLI override
    if [[ "$CONF_DATA" != "/var/lib/novelkv" ]]; then
        echo "NOVELKV_OPTS=\"--data $CONF_DATA\"" > "$CONFIG_DIR/novelkv.env"
    fi
    echo "  Installed $CONFIG_DIR/novelkv.env"
fi
chmod 644 "$CONFIG_DIR/novelkv.env"

echo "[5/8] Installing systemd service..."
sed -e "s|__BIN_PATH__|$BIN_DIR/$BIN_NAME|g" \
    -e "s|__DATA_DIR__|$CONF_DATA|g" \
    "$SCRIPT_DIR/novelkv.service" > /etc/systemd/system/novelkv.service
chmod 644 /etc/systemd/system/novelkv.service

echo "[6/8] Setting file ownership..."
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$CONF_DATA"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR"
chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/novelkv.conf"

echo "[7/8] Reloading systemd..."
systemctl daemon-reload

echo "[8/8] Enabling service..."
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
echo "Data directory:     $CONF_DATA"
