#!/bin/bash
set -euo pipefail

# NovelKV release packaging script
# Usage: ./scripts/package.sh [VERSION]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    VERSION=$(grep -oP '\.version\s*=\s*"\K[^"]+' "$PROJECT_DIR/build.zig.zon")
    if [ -z "$VERSION" ]; then
        echo "ERROR: Cannot determine version from build.zig.zon"
        exit 1
    fi
fi

ARCH=$(uname -m)
PKG_NAME="novelkv-${VERSION}-linux-${ARCH}"
BUILD_DIR="$PROJECT_DIR/zig-out/bin"
STAGE_DIR="$PROJECT_DIR/dist/$PKG_NAME"

echo "=== Packaging NovelKV $VERSION for linux-$ARCH ==="

echo "[1/5] Cleaning previous build..."
rm -rf "$PROJECT_DIR/dist"
mkdir -p "$STAGE_DIR"

echo "[2/5] Building release binary (ReleaseSafe)..."
cd "$PROJECT_DIR"
zig build -Doptimize=ReleaseSafe

echo "[3/5] Copying binary..."
cp "$BUILD_DIR/novelkv" "$STAGE_DIR/novelkv"
if command -v strip &>/dev/null; then
    strip --strip-all "$STAGE_DIR/novelkv"
    echo "  (stripped)"
elif command -v llvm-strip &>/dev/null; then
    llvm-strip "$STAGE_DIR/novelkv"
    echo "  (stripped with llvm-strip)"
fi
chmod +x "$STAGE_DIR/novelkv"

SIZE=$(du -sh "$STAGE_DIR/novelkv" | cut -f1)
echo "  Binary size: $SIZE"

echo "[4/5] Copying package files..."
cp "$PROJECT_DIR/packaging/install.sh" "$STAGE_DIR/install.sh"
cp "$PROJECT_DIR/packaging/uninstall.sh" "$STAGE_DIR/uninstall.sh"
cp "$PROJECT_DIR/packaging/novelkv.service" "$STAGE_DIR/novelkv.service"
cp "$PROJECT_DIR/packaging/novelkv.conf" "$STAGE_DIR/novelkv.conf"
cp "$PROJECT_DIR/packaging/README.deploy.md" "$STAGE_DIR/README.md"
chmod +x "$STAGE_DIR/install.sh" "$STAGE_DIR/uninstall.sh"

echo "[5/5] Creating tar.gz archive..."
cd "$PROJECT_DIR/dist"
tar czf "$PKG_NAME.tar.gz" "$PKG_NAME"

FINAL="$PROJECT_DIR/dist/$PKG_NAME.tar.gz"
FINAL_SIZE=$(du -sh "$FINAL" | cut -f1)

echo ""
echo "=== Package created successfully ==="
echo "  Archive: $FINAL"
echo "  Size:    $FINAL_SIZE"
echo ""
echo "To install on target machine:"
echo "  scp $FINAL user@target:/tmp/"
echo "  cd /tmp && tar xzf $PKG_NAME.tar.gz"
echo "  cd $PKG_NAME && sudo ./install.sh"
