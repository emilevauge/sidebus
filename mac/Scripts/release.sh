#!/bin/bash
#
# Builds, signs and notarizes Sidebus for distribution outside the App Store.
#
# The App Store is out of reach: `CGVirtualDisplay` is a private API. Distribution is
# therefore direct, which demands a Developer ID signature and notarization, without which
# Gatekeeper refuses the app on any machine but the one that built it.
#
# Expected variables:
#   SIDEBUS_DEVELOPER_ID   "Developer ID Application: Nom (TEAMID)"
#   SIDEBUS_NOTARY_PROFILE name of a profile stored with:
#                          xcrun notarytool store-credentials
#
# Usage: Scripts/release.sh [--skip-notarization]

set -euo pipefail

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$MAC_DIR/build/Sidebus.app"
DMG="$MAC_DIR/build/Sidebus.dmg"
SKIP_NOTARIZATION="${1:-}"

cd "$MAC_DIR"

if [[ -z "${SIDEBUS_DEVELOPER_ID:-}" ]]; then
	cat >&2 <<'MSG'
SIDEBUS_DEVELOPER_ID is not set.

Without a Developer ID identity the app can be neither notarized nor opened on another
machine. For local use, Scripts/bundle.sh is enough: it signs with a keychain identity,
which keeps the TCC permissions across builds.
MSG
	exit 1
fi

echo "==> construction"
SIDEBUS_CODESIGN_IDENTITY="$SIDEBUS_DEVELOPER_ID" ./Scripts/bundle.sh release

echo "==> signing with the hardened runtime"
codesign --force --options runtime --timestamp \
	--entitlements "$MAC_DIR/Resources/Sidebus.entitlements" \
	--sign "$SIDEBUS_DEVELOPER_ID" \
	--identifier app.sidebus \
	"$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> image disque"
rm -f "$DMG"
hdiutil create -volname Sidebus -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

if [[ "$SKIP_NOTARIZATION" == "--skip-notarization" ]]; then
	echo "notarization skipped on request"
	echo "ready: $DMG"
	exit 0
fi

if [[ -z "${SIDEBUS_NOTARY_PROFILE:-}" ]]; then
	echo "SIDEBUS_NOTARY_PROFILE is not set, cannot notarize" >&2
	exit 1
fi

echo "==> notarisation, quelques minutes"
xcrun notarytool submit "$DMG" --keychain-profile "$SIDEBUS_NOTARY_PROFILE" --wait

echo "==> agrafage"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Checks what Gatekeeper will see on the user's machine.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo
echo "ready: $DMG"
