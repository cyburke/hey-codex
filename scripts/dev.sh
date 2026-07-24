#!/usr/bin/env bash
# Build a self-contained Hey Codex.app for local development.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
"$ROOT/scripts/bundle-app.sh" "$CONFIG"
echo "Built $ROOT/dist/HeyCodex.app"
echo "Open it manually when you are ready to grant permissions: open \"$ROOT/dist/HeyCodex.app\""
