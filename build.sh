#!/bin/bash
# Builds "STRDM Stage.app" into ./dist — needs Xcode or the Xcode Command Line Tools (Swift 5.9+), macOS 14+.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="STRDM Stage"
OUT="dist/${APP_NAME}.app"

echo "▶ Compiling (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▶ Packaging ${OUT}…"
rm -rf "${OUT}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "${BIN_DIR}/STRDMStage" "${OUT}/Contents/MacOS/STRDMStage"
cp Resources/Info.plist "${OUT}/Contents/Info.plist"

# Ad-hoc signature, no hardened runtime, so third-party Audio Units (Antares Auto-Tune, Waves…) can load in-process.
codesign --force --deep --sign - "${OUT}"

echo "✅ Built ${OUT}"
if [[ "${1:-}" == "--open" ]]; then open "${OUT}"; fi
