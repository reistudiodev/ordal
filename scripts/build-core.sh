#!/usr/bin/env bash
# Builds the Rust core, regenerates the Swift bindings and puts the static
# library where swift/Package.swift expects it. macOS and Linux.
#
#   scripts/build-core.sh            # release build for this machine
#   scripts/build-core.sh --debug    # debug build
#   scripts/build-core.sh --universal  # macOS only: arm64 + x86_64 in one lib
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE=release
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE=debug ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
CARGO_FLAGS=()
[ "$PROFILE" = release ] && CARGO_FLAGS+=(--release)

LIB=libdbclient_core.a
case "$(uname -s)" in
  Darwin) DYLIB=libdbclient_core.dylib ;;
  *) DYLIB=libdbclient_core.so ;;
esac

echo "==> Building Rust core ($PROFILE)"
if [ "$UNIVERSAL" = 1 ]; then
  [ "$(uname -s)" = Darwin ] || { echo "--universal is macOS only" >&2; exit 1; }
  for t in aarch64-apple-darwin x86_64-apple-darwin; do
    rustup target add "$t" >/dev/null
    cargo build -p dbclient-core "${CARGO_FLAGS[@]}" --target "$t"
  done
  mkdir -p "target/universal/$PROFILE"
  lipo -create \
    "target/aarch64-apple-darwin/$PROFILE/$LIB" \
    "target/x86_64-apple-darwin/$PROFILE/$LIB" \
    -output "target/universal/$PROFILE/$LIB"
  STATIC="target/universal/$PROFILE/$LIB"
  cargo build -p dbclient-core "${CARGO_FLAGS[@]}"
else
  cargo build -p dbclient-core "${CARGO_FLAGS[@]}"
  STATIC="target/$PROFILE/$LIB"
fi

echo "==> Generating Swift bindings"
OUT="$(mktemp -d)"
cargo run -q -p uniffi-bindgen -- generate \
  --library "target/$PROFILE/$DYLIB" \
  --language swift \
  --out-dir "$OUT"

FFI_DIR=swift/Sources/DBClientCoreFFI/include
mkdir -p "$FFI_DIR"
cp "$OUT/DBClientCoreFFI.h" "$FFI_DIR/DBClientCoreFFI.h"
# Drop the Apple-only `use` lines so the same module map works on Linux and Windows.
grep -v '^ *use "' "$OUT/DBClientCoreFFI.modulemap" > "$FFI_DIR/module.modulemap"
cp "$OUT/DBClientCore.swift" swift/Sources/DBClientCore/DBClientCore.swift
rm -rf "$OUT"

echo "==> Copying static library to swift/lib"
cp "$STATIC" swift/lib/$LIB

echo "Done. Now: cd apps/<platform> && swift run"
