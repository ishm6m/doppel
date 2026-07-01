#!/usr/bin/env bash
#
# release.sh — archive → sign (Developer ID) → notarize → staple → verify, then stage for the Sparkle
# appcast. Implements RELEASE.md §3. Everything credential-specific comes from env vars so no secret is
# ever committed. Run on the maintainer's Mac with the Developer ID cert already in the keychain.
#
# ponytail: NOT verifiable end-to-end without a real Developer ID cert + notary creds, so it is written
# to fail fast on missing inputs rather than pretend. Ships a .zip (Sparkle's native delivery), not a
# DMG — add a DMG step only if you distribute outside Sparkle too.
#
# Required env:
#   DEVELOPER_ID   e.g. "Developer ID Application: Jane Dev (TEAMID123)"
#   TEAM_ID        Apple Developer Team ID, e.g. TEAMID123
#   NOTARY_PROFILE keychain profile name created once via:
#                    xcrun notarytool store-credentials NOTARY_PROFILE \
#                      --apple-id you@example.com --team-id TEAMID123 --password <app-specific-pw>
# Optional env:
#   CONFIG         build configuration (default: Release)
#   OUT_DIR        output dir (default: ./build/release)
set -euo pipefail

: "${DEVELOPER_ID:?set DEVELOPER_ID (see header)}"
: "${TEAM_ID:?set TEAM_ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (xcrun notarytool store-credentials …)}"
CONFIG="${CONFIG:-Release}"
OUT_DIR="${OUT_DIR:-build/release}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/Doppel.xcarchive"
APP="$OUT_DIR/Doppel.app"

echo "▸ Regenerating project from project.yml"
xcodegen generate

echo "▸ Archiving ($CONFIG, Developer ID, hardened runtime)"
xcodebuild -scheme Doppel -configuration "$CONFIG" -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID"

echo "▸ Exporting Developer ID app"
EXPORT_PLIST="$OUT_DIR/ExportOptions.plist"
cat >"$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$OUT_DIR"

echo "▸ Notarizing (submit + wait)"
ZIP="$OUT_DIR/Doppel.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling the ticket"
xcrun stapler staple "$APP"

echo "▸ Verifying (Gatekeeper + codesign + entitlements)"
spctl --assess --type execute --verbose "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# Prove the ONLY egress entitlement present is network.client (Sparkle) — never network.server.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'network.server'; then
  echo "✗ network.server entitlement present — aborting (golden rule 1)"; exit 1
fi

# Re-zip the stapled app for delivery, then hand off to Sparkle's appcast generator.
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ Notarized, stapled build at: $ZIP"
echo
echo "Next (appcast — RELEASE.md §5): put $ZIP in your updates dir and run Sparkle's"
echo "  ./bin/generate_appcast <updates-dir>"
echo "which signs each entry with your EdDSA private key (in the keychain). Publish the resulting"
echo "appcast.xml + zip to the SUFeedURL host. Keep the previous build+entry for rollback (§7)."
