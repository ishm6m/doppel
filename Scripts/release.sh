#!/usr/bin/env bash
#
# release.sh — build a distributable Doppel.app with NO Apple Developer account: ad-hoc code signing +
# a zip + a SHA-256 for the Homebrew cask. Implements the open-source distribution model (RELEASE.md).
#
# There is no notarization (that needs a paid Developer ID). Users get past Gatekeeper once on first
# launch (right-click ▸ Open, or `brew install --cask --no-quarantine`, or `xattr -dr
# com.apple.security.quarantine Doppel.app`) — documented in README. Updates ship via `brew upgrade`.
#
# ponytail: ad-hoc signing (codesign -s -) is the whole trick — free, no account, and the app still runs
# once quarantine is cleared. Skipped notarization/DMG entirely; add them only if you ever get a cert.
#
# Usage: ./Scripts/release.sh              # builds ./build/release/Doppel.zip (+ prints sha256)
# Env:   CONFIG (default Release), OUT_DIR (default build/release)
set -euo pipefail

CONFIG="${CONFIG:-Release}"
OUT_DIR="${OUT_DIR:-build/release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/Doppel.xcarchive"
APP="$OUT_DIR/Doppel.app"
ZIP="$OUT_DIR/Doppel.zip"

echo "▸ Regenerating project from project.yml"
xcodegen generate

echo "▸ Archiving ($CONFIG, ad-hoc signed, hardened runtime)"
xcodebuild -scheme Doppel -configuration "$CONFIG" -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual

# Copy the built .app out of the archive (no -exportArchive: Developer-ID export needs a real identity).
cp -R "$ARCHIVE/Products/Applications/Doppel.app" "$APP"

echo "▸ Re-signing ad-hoc (deep, so bundled frameworks are covered)"
codesign --force --deep --sign - --options runtime "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Prove the golden-rule-1 guarantee holds in the shipped binary: no network entitlement at all.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'network'; then
  echo "✗ a network entitlement is present — aborting (golden rule 1)"; exit 1
fi

echo "▸ Zipping for release"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

echo
echo "✓ $ZIP"
echo "  sha256: $SHA"
echo "  Attach the zip to a GitHub Release, then update Casks/doppel.rb (sha256 + version)."
echo "  (The release.yml workflow does this automatically on a v* tag.)"
