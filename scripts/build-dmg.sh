#!/usr/bin/env bash
# Builds a beautifully styled macOS DMG with custom branded background and Finder drag-and-drop layout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Ordal.app}"
VERSION="${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)}"
DMG="${2:-$ROOT/dist/Ordal-$VERSION-macos.dmg}"
VOLNAME="Ordal"

if [ ! -d "$APP" ]; then
    echo "Error: App bundle not found at $APP" >&2
    echo "Run scripts/package-macos.sh first." >&2
    exit 1
fi

# 1. Ensure background image is generated
if [ ! -f "$ROOT/assets/dmg/dmg-background.png" ]; then
    echo "==> Generating DMG background image..."
    "$ROOT/scripts/generate-dmg-background.swift"
fi

TEMP_DIR="$(mktemp -d)"
DMG_RW="$TEMP_DIR/temp.dmg"

cleanup() {
    if [ -d "/Volumes/$VOLNAME" ]; then
        hdiutil detach "/Volumes/$VOLNAME" -force -quiet 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Unmount any existing /Volumes/Ordal
if [ -d "/Volumes/$VOLNAME" ]; then
    hdiutil detach "/Volumes/$VOLNAME" -force -quiet 2>/dev/null || true
fi

echo "==> Creating temporary writable DMG container..."
hdiutil create -size 200m -fs HFS+ -volname "$VOLNAME" "$DMG_RW" -quiet

echo "==> Mounting temporary DMG to /Volumes/$VOLNAME..."
MOUNT_INFO=$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen)
DEVICE=$(echo "$MOUNT_INFO" | grep '^/dev/' | head -1 | awk '{print $1}')
MOUNT_POINT="/Volumes/$VOLNAME"

echo "==> Copying application bundle and setting up links..."
cp -R "$APP" "$MOUNT_POINT/"
ln -s /Applications "$MOUNT_POINT/Applications"

mkdir -p "$MOUNT_POINT/.background"
cp "$ROOT/assets/dmg/dmg-background.png" "$MOUNT_POINT/.background/background.png"
cp "$ROOT/assets/dmg/dmg-background@2x.png" "$MOUNT_POINT/.background/background@2x.png"

# Setup Finder window layout via AppleScript
echo "==> Configuring Finder window and icon layout..."
osascript <<APPLESCRIPT || echo "warning: Finder layout configuration skipped (headless environment)"
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 0.5
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {300, 150, 960, 550}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 110
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Ordal.app" of container window to {175, 195}
        set position of item "Applications" of container window to {485, 195}
        close
        delay 0.5
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Hide .background folder
SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true
chmod -Rf go-w "$MOUNT_POINT" 2>/dev/null || true
sync

echo "==> Detaching temporary DMG..."
hdiutil detach "$MOUNT_POINT" -quiet

echo "==> Converting to final compressed read-only DMG..."
rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet

echo "==> Successfully created $DMG"
ls -lh "$DMG"
