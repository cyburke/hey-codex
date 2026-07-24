#!/usr/bin/env bash
# Build Hey Codex for a stable, local macOS permission test. This intentionally
# refuses ad-hoc signing: TCC ties microphone and keyboard-event permissions to
# the app's signing identity, so a changing ad-hoc hash creates misleading,
# repeatedly failing permission prompts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_ID="${HEYCODEX_SIGN_ID:-}"

if [ -z "$SIGN_ID" ]; then
    echo "Set HEYCODEX_SIGN_ID to a stable signing identity or certificate SHA-1 fingerprint." >&2
    exit 2
fi

export HEYCODEX_SIGN_ID="$SIGN_ID"
exec "$ROOT/scripts/build-release.sh"
