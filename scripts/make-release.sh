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

if [ ! -d "$APP" ]; then
    echo "No dist/HeyCodex.app. Run ./scripts/build-release.sh first." >&2
    exit 1
fi
# The version comes from the built app's own Info.plist, not a caller-supplied
# argument: a hand-typed argument here is exactly how the published cask ended
# up saying 0.1.1 while Info.plist said 0.1.2 - nothing cross-checked them.
# Reading it from the bundle we are about to package also guarantees the cask
# always names the version that was actually built.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ -z "$VERSION" ]; then
    echo "Could not read CFBundleShortVersionString from $APP/Contents/Info.plist" >&2
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

  depends_on macos: :sonoma

  app "HeyCodex.app"

  # Hey Codex is signed but not notarized, so macOS quarantines the download and
  # blocks the first launch behind System Settings. Homebrew's own
  # --no-quarantine option was removed in Homebrew 6, so clear the attribute
  # here instead. Installing from this tap is the user opting in to that.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/HeyCodex.app"],
                   sudo: false
  end

  caveats <<~EOS
    Launch Hey Codex, then grant Microphone and Accessibility when asked.
    Accessibility is what lets it press the ChatGPT Voice hotkey.
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
echo "  3. Verify: brew install --cask cyburke/tap/hey-codex"
