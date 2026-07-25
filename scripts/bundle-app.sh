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
# Drop local/debug symbols before signing. The static sherpa-onnx + onnxruntime
# archives carry a large symbol table that nothing needs at runtime (~8 MB).
# This must run before codesign, or it invalidates the signature.
strip -x "$APP/Contents/MacOS/HeyCodex"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$APP/Contents/Resources/"

# A release bundle must be self-contained: use a physical copy, never a source
# checkout symlink. Models are fetched separately by scripts/fetch-models.sh.
#
# Copy only what the shipped app loads - the keyword spotter and its keyword
# list. The Parakeet ASR model in Models/ is a development asset for the
# selftest decode probes; Hey Codex never transcribes, so bundling it added
# 631 MB to a download for a capability the product does not have. Anything the
# app needs at runtime must be added here explicitly, not swept in wholesale.
#
# Within the wake-word model, copy only the files the app opens: the three onnx
# models and tokens.txt for WakeWordEngine, plus bpe.vocab for KeywordTokenizer,
# which encodes a wake phrase into model tokens. The released directory also ships
# int8 variants, test WAVs and a README; none of those are read at runtime.
# bpe.vocab is generated from bpe.model by scripts/make-bpe-vocab.py and is 12 KB.
#
# bpe.model itself is deliberately NOT bundled, but it is not inert either:
# WakeWordEngine.init does a FileManager.fileExists check for it (by the name in
# KeywordTuning.bpeVocabName) to decide modeling_unit "bpe" vs falling back to
# "cjkchar". Leaving it out of KWS_FILES means that check always misses on a
# shipped build, so every release currently runs with the cjkchar fallback -
# see WakeWordEngine.swift and P1.4 in AUDIT-2026-07-24.md. Keep in sync with
# WakeWordEngine.init and KeywordTokenizer - a missing file fails loudly there.
KWS_MODEL="sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
KWS_FILES=(
    "encoder-epoch-12-avg-2-chunk-16-left-64.onnx"
    "decoder-epoch-12-avg-2-chunk-16-left-64.onnx"
    "joiner-epoch-12-avg-2-chunk-16-left-64.onnx"
    "tokens.txt"
    "bpe.vocab"
)
if [ ! -f "$ROOT/Models/keywords.txt" ]; then
    echo "Missing Models/keywords.txt. Run ./scripts/fetch-models.sh before bundling." >&2
    exit 1
fi
mkdir -p "$APP/Contents/Resources/Models/$KWS_MODEL"
for f in "${KWS_FILES[@]}"; do
    if [ ! -f "$ROOT/Models/$KWS_MODEL/$f" ]; then
        if [ "$f" = "bpe.vocab" ]; then
            # bpe.vocab is tracked in git (see .gitignore), so a normal clone
            # already has it. It's only missing here if the KWS model was
            # re-pinned to a new bpe.model without regenerating this file.
            echo "Missing wake-word model file: $KWS_MODEL/$f." >&2
            echo "Regenerate it with:" >&2
            echo "  pip install sentencepiece" >&2
            echo "  python3 scripts/make-bpe-vocab.py Models/$KWS_MODEL" >&2
            echo "then commit the resulting Models/$KWS_MODEL/bpe.vocab." >&2
        else
            echo "Missing wake-word model file: $KWS_MODEL/$f. Run ./scripts/fetch-models.sh before bundling." >&2
        fi
        exit 1
    fi
    cp "$ROOT/Models/$KWS_MODEL/$f" "$APP/Contents/Resources/Models/$KWS_MODEL/$f"
done
cp "$ROOT/Models/keywords.txt" "$APP/Contents/Resources/Models/keywords.txt"

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
