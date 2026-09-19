#!/bin/bash
#
# Construit mac/build/Sidebus.app et le signe en ad hoc.
#
# Signature : une identité de signature locale si le trousseau en contient une, sinon
# ad hoc. La différence compte pour TCC, qui mémorise les autorisations (Enregistrement
# de l'écran, Accessibilité, Réseau local) par règle de signature :
#
#   ad hoc     -> "identifier app.sidebus and cdhash H<...>"   change à chaque build,
#                 donc l'autorisation est perdue à chaque recompilation
#   identité   -> "identifier app.sidebus and certificate leaf = H<...>"   stable
#
# Forcer un choix avec SIDEBUS_CODESIGN_IDENTITY (nom de l'identité, ou "-" pour ad hoc).
# La signature Developer ID et la notarisation arrivent en phase 9.
#
# Usage : Scripts/bundle.sh [release|debug]   (défaut : release)

set -euo pipefail

CONFIG="${1:-release}"
MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$MAC_DIR/build/Sidebus.app"

cd "$MAC_DIR"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/SidebusApp"
if [[ ! -x "$BIN" ]]; then
	echo "binaire introuvable : $BIN" >&2
	exit 1
fi

echo "==> assemblage de $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SidebusApp"
cp "$MAC_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icône de l'application, déclarée par CFBundleIconFile. Régénérée par art/build.sh.
cp "$MAC_DIR/Resources/Sidebus.icns" "$APP/Contents/Resources/Sidebus.icns"

# Bundle de ressources SwiftPM : il porte les gabarits de la barre de menus,
# que Bundle.module va chercher dans Contents/Resources.
RESOURCES="$(swift build -c "$CONFIG" --show-bin-path)/Sidebus_SidebusApp.bundle"
if [[ -d "$RESOURCES" ]]; then
	cp -R "$RESOURCES" "$APP/Contents/Resources/"
else
	echo "bundle de ressources introuvable : $RESOURCES" >&2
	exit 1
fi

IDENTITY="${SIDEBUS_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
	IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 && NF>1 {print $2}')"
	IDENTITY="${IDENTITY:--}"
fi

if [[ "$IDENTITY" == "-" ]]; then
	echo "==> signature ad hoc (autorisations TCC perdues à chaque build)"
else
	echo "==> signature avec l'identité « $IDENTITY »"
fi
codesign --force --sign "$IDENTITY" --identifier app.sidebus --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo
echo "prêt : $APP"
echo "lancer : open $APP"
