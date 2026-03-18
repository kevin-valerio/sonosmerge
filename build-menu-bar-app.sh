#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SonoMerge"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$RESOURCES_DIR"

swiftc \
  -parse-as-library \
  "$ROOT_DIR/SonoMergeMenuBarApp/main.swift" \
  -o "$EXECUTABLE_PATH" \
  -framework AppKit

cp "$ROOT_DIR/SonoMergeMenuBarApp/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/sonos_broadcast.py" "$RESOURCES_DIR/sonos_broadcast.py"
chmod +x "$EXECUTABLE_PATH" "$RESOURCES_DIR/sonos_broadcast.py"

printf 'Built %s\n' "$APP_DIR"
