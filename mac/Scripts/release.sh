#!/bin/bash
#
# Construit, signe et notarise Sidebus pour une distribution hors App Store.
#
# L'App Store est exclu : `CGVirtualDisplay` est une API privée. La distribution se fait
# donc en direct, ce qui impose une signature Developer ID et une notarisation, sans quoi
# Gatekeeper refuse l'application sur une autre machine que celle qui l'a construite.
#
# Variables attendues :
#   SIDEBUS_DEVELOPER_ID   "Developer ID Application: Nom (TEAMID)"
#   SIDEBUS_NOTARY_PROFILE nom d'un profil enregistré avec :
#                          xcrun notarytool store-credentials
#
# Usage : Scripts/release.sh [--skip-notarization]

set -euo pipefail

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$MAC_DIR/build/Sidebus.app"
DMG="$MAC_DIR/build/Sidebus.dmg"
SKIP_NOTARIZATION="${1:-}"

cd "$MAC_DIR"

if [[ -z "${SIDEBUS_DEVELOPER_ID:-}" ]]; then
	cat >&2 <<'MSG'
SIDEBUS_DEVELOPER_ID n'est pas défini.

Sans identité Developer ID, l'application ne peut être ni notarisée ni ouverte sur une
autre machine. Pour un usage local, Scripts/bundle.sh suffit : il signe avec une identité
du trousseau, ce qui garde les autorisations TCC d'un build à l'autre.
MSG
	exit 1
fi

echo "==> construction"
SIDEBUS_CODESIGN_IDENTITY="$SIDEBUS_DEVELOPER_ID" ./Scripts/bundle.sh release

echo "==> signature avec runtime renforcé"
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
	echo "notarisation ignorée à la demande"
	echo "prêt : $DMG"
	exit 0
fi

if [[ -z "${SIDEBUS_NOTARY_PROFILE:-}" ]]; then
	echo "SIDEBUS_NOTARY_PROFILE n'est pas défini, notarisation impossible" >&2
	exit 1
fi

echo "==> notarisation, quelques minutes"
xcrun notarytool submit "$DMG" --keychain-profile "$SIDEBUS_NOTARY_PROFILE" --wait

echo "==> agrafage"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Vérifie ce que verra Gatekeeper sur la machine de l'utilisateur.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo
echo "prêt : $DMG"
