#!/usr/bin/env bash
# Removes build caches and outputs: Rust target/, SwiftPM .build folders,
# the core library copied into swift/lib, and dist/. Leaves .env alone.
# Run scripts/build-core.sh again before building the apps.
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Rust (target/)"
cargo clean

echo "==> Swift build caches"
rm -rf swift/.build swift/.swiftpm apps/*/.build apps/*/.swiftpm

echo "==> Copied core library (swift/lib)"
rm -f swift/lib/*.a swift/lib/*.lib

echo "==> Release outputs (dist/)"
rm -rf dist

echo "Done. Rebuild with: ./scripts/build-core.sh"
