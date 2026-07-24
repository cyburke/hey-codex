#!/usr/bin/env bash
# Package dist/HeyCodex.app for a GitHub release and print the Homebrew cask
# that matches it. Run AFTER build-release.sh (or build-signed-local.sh).
#
# The cask is printed rather than written because its sha256 must describe the
# exact zip that gets uploaded - generating it from a guessed URL is how casks
# end up pointing at a checksum nobody ever verified.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/HeyCodex.app"
VERSION="${1:-}"

if [ ! -d "$APP" ]; then
    echo "No dist/HeyCodex.app. Run ./scripts/build-release.sh first." >&2
    exit 1
fi
if [ -z "$VERSION" ]; then
    echo "usage: ./scripts/make-release.sh <version>   e.g. 0.1.0" >&2
    exit 1
fi

ZIP="$ROOT/dist/HeyCodex-$VERSION.zip"
rm -f "$ZIP"
# ditto preserves the bundle's symlinks and resource forks; `zip -r` does not,
# and a mangled bundle fails to launch in ways that look like a code bug.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1)"

echo
echo "Built $ZIP  ($SIZE)"
echo "sha256: $SHA"
echo
echo "-------- Casks/hey-codex.rb (commit this to cyburke/homebrew-tap) --------"
cat <<CASK
cask "hey-codex" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/cyburke/hey-codex/releases/download/v#{version}/HeyCodex-#{version}.zip"
  name "Hey Codex"
  desc "Menu-bar wake word that opens ChatGPT Voice"
  homepage "https://github.com/cyburke/hey-codex"

  depends_on macos: ">= :sonoma"

  app "HeyCodex.app"

  caveats <<~EOS
    Hey Codex is not notarized, so it must be installed with --no-quarantine:

      brew install --cask --no-quarantine cyburke/tap/hey-codex

    On first launch, grant Microphone and Accessibility permission when asked.
    Accessibility is what lets Hey Codex press the ChatGPT Voice hotkey.
  EOS

  uninstall quit: "com.heycodex.app"

  zap trash: [
    "~/Library/Application Support/HeyCodex",
    "~/Library/Preferences/com.heycodex.app.plist",
  ]
end
CASK
echo "-------------------------------------------------------------------------"
echo
echo "Next:"
echo "  1. gh release create v$VERSION $ZIP --title \"Hey Codex $VERSION\" --notes-file <notes>"
echo "  2. Commit the cask above to github.com/cyburke/homebrew-tap as Casks/hey-codex.rb"
echo "  3. Verify: brew install --cask --no-quarantine cyburke/tap/hey-codex"
