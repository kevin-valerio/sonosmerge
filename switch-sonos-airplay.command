#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_PATH="$ROOT_DIR/build/sonos_broadcast"

if [[ ! -x "$CLI_PATH" ]]; then
  "$ROOT_DIR/build-menu-bar-app.sh" >/dev/null
fi

"$CLI_PATH" broadcast \
  --rooms "Salon TV" "Cuisine" \
  --primary-room "Salon TV"
