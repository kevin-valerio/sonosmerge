#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SonoMerge"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"
CLI_PATH="$ROOT_DIR/build/sonos_broadcast"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$ROOT_DIR/build"

swiftc \
  "$ROOT_DIR/SonoMergeCore/SonoMergeCore.swift" \
  "$ROOT_DIR/SonoMergeCLI/main.swift" \
  -o "$CLI_PATH"

swiftc \
  -parse-as-library \
  "$ROOT_DIR/SonoMergeCore/SonoMergeCore.swift" \
  "$ROOT_DIR/SonoMergeMenuBarApp/main.swift" \
  -o "$EXECUTABLE_PATH" \
  -framework AppKit \
  -framework ServiceManagement

cp "$ROOT_DIR/SonoMergeMenuBarApp/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$EXECUTABLE_PATH" "$CLI_PATH"

printf 'Built %s\n' "$APP_DIR"
printf 'Built %s\n' "$CLI_PATH"
