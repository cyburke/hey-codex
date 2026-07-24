#!/usr/bin/env bash
# Build a locally distributable Hey Codex.app. It embeds models, license notices,
# and an ad-hoc or Developer ID signature; it does not claim notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/dist/HeyCodex.app"
cd "$ROOT"

swift build --product HeyCodexApp -c "$CONFIG"
BIN="$(swift build --product HeyCodexApp -c "$CONFIG" --show-bin-path)/HeyCodexApp"

# The target is deliberately exact and release-scoped.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HeyCodex"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$APP/Contents/Resources/"

# A release bundle must be self-contained: use a physical copy, never a source
# checkout symlink. Models are fetched separately by scripts/fetch-models.sh.
if [ ! -d "$ROOT/Models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01" ] || \
   [ ! -d "$ROOT/Models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8" ]; then
    echo "Missing models. Run ./scripts/fetch-models.sh before bundling." >&2
    exit 1
fi
ditto "$ROOT/Models" "$APP/Contents/Resources/Models"

SIGN_ID="${HEYCODEX_SIGN_ID:-}"
ENTITLEMENTS="$ROOT/scripts/entitlements.plist"
# Microphone capture is entitlement-gated on modern macOS. Keep this attached
# on every signature so the visible first-run consent can actually trigger.
# Do not silently fall back to ad-hoc signing when a caller explicitly asked
# for a stable identity.
if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
    echo "Signed with $SIGN_ID"
else
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
    echo "Ad-hoc signed. Gatekeeper may require Control-click → Open; this bundle is not notarized."
fi
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP"
