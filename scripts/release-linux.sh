#!/usr/bin/env bash
# Builds a Linux release: dist/ordal-<version>-linux-<arch>.tar.gz
# The archive uses the usual prefix layout, so it can be unpacked into
# ~/.local or /usr/local:
#
#   bin/ordal
#   share/applications/ordal.desktop
#   share/icons/hicolor/512x512/apps/ordal.png
#
# The Swift runtime is linked statically; GTK comes from the system.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)}"
ARCH="$(uname -m)"

"$ROOT/scripts/build-core.sh"

cd "$ROOT/apps/linux"
swift build -c release --static-swift-stdlib
BIN="$(swift build -c release --static-swift-stdlib --show-bin-path)/OrdalLinux"

NAME="ordal-$VERSION-linux-$ARCH"
STAGE="$ROOT/dist/$NAME"
rm -rf "$STAGE"
install -Dm755 "$BIN" "$STAGE/bin/ordal"
strip "$STAGE/bin/ordal"
install -Dm644 "$ROOT/assets/brand/ordal-app-icon-512.png" "$STAGE/share/icons/hicolor/512x512/apps/ordal.png"
mkdir -p "$STAGE/share/applications"
cat > "$STAGE/share/applications/ordal.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ordal
Comment=Native database client
Exec=ordal
Icon=ordal
Categories=Development;Database;
Terminal=false
DESKTOP

tar -C "$ROOT/dist" -czf "$ROOT/dist/$NAME.tar.gz" "$NAME"
rm -rf "$STAGE"
echo "Built $ROOT/dist/$NAME.tar.gz"
