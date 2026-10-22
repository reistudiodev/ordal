#!/usr/bin/env bash
# Builds a macOS release: dist/Ordal-<version>-macos.dmg and .zip (universal).
# Signs with a Developer ID certificate and notarizes when these are set, in the
# environment or in .env at the repo root (see .env.example):
#
#   MACOS_CERTIFICATE       base64 of the "Developer ID Application" .p12
#   MACOS_CERTIFICATE_PWD   password of that .p12
#   APPLE_API_KEY_ID        App Store Connect API key ID
#   APPLE_API_ISSUER        App Store Connect issuer ID
#   APPLE_API_KEY_BASE64    base64 of the AuthKey_<id>.p8 file
#
# Without them the release keeps the ad-hoc signature: fine for local testing,
# but Gatekeeper blocks it on other Macs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
export VERSION="${VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)}"

"$ROOT/scripts/package-macos.sh"

APP="$ROOT/dist/Ordal.app"
DMG="$ROOT/dist/Ordal-$VERSION-macos.dmg"
ZIP="$ROOT/dist/Ordal-$VERSION-macos.zip"
WORK="$(mktemp -d)"
KEYCHAIN=""
cleanup() {
  [ -n "$KEYCHAIN" ] && security delete-keychain "$KEYCHAIN" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

IDENTITY=""
if [ -n "${MACOS_CERTIFICATE:-}" ]; then
  echo "==> Importing signing certificate into a temporary keychain"
  KEYCHAIN="$WORK/ordal-signing.keychain-db"
  KEYCHAIN_PWD="$(uuidgen)"
  echo "$MACOS_CERTIFICATE" | base64 --decode > "$WORK/cert.p12"
  security create-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
  security import "$WORK/cert.p12" -k "$KEYCHAIN" \
    -P "${MACOS_CERTIFICATE_PWD:?MACOS_CERTIFICATE_PWD is required with MACOS_CERTIFICATE}" \
    -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PWD" "$KEYCHAIN" >/dev/null
  # codesign only finds identities in keychains on the search list.
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
  [ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' identity in MACOS_CERTIFICATE" >&2; exit 1; }

  echo "==> Signing app with $IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "warning: MACOS_CERTIFICATE not set, keeping the ad-hoc signature (not notarized)" >&2
fi

echo "==> Building $DMG"
mkdir -p "$WORK/dmg"
cp -R "$APP" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
hdiutil create -volname "Ordal" -srcfolder "$WORK/dmg" -ov -format UDZO "$DMG" >/dev/null
[ -n "$IDENTITY" ] && codesign --force --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" "$DMG"

if [ -n "$IDENTITY" ] && [ -n "${APPLE_API_KEY_ID:-}" ]; then
  echo "==> Notarizing (this usually takes a few minutes)"
  KEY="$WORK/AuthKey_$APPLE_API_KEY_ID.p8"
  echo "${APPLE_API_KEY_BASE64:?APPLE_API_KEY_BASE64 is required with APPLE_API_KEY_ID}" | base64 --decode > "$KEY"
  AUTH=(--key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "${APPLE_API_ISSUER:?APPLE_API_ISSUER is required}")
  OUT="$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait 2>&1)" || true
  echo "$OUT"
  if ! grep -q "status: Accepted" <<<"$OUT"; then
    ID="$(sed -n 's/^ *id: //p' <<<"$OUT" | head -1)"
    [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}"
    echo "Notarization failed" >&2
    exit 1
  fi
  # The DMG's ticket covers the app inside it; staple both so they open offline.
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
elif [ -n "$IDENTITY" ]; then
  echo "warning: APPLE_API_KEY_ID not set, signed but not notarized" >&2
fi

echo "==> Building $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done:"
ls -lh "$DMG" "$ZIP"
