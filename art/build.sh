#!/bin/bash
#
# Regenerates every icon asset from the SVGs in art/.
#
#   art/bus-app.svg            -> mac/Resources/Sidebus.icns
#   art/bus-template.svg       -> mac/Sources/SidebusApp/Resources/MenuBar.pdf
#   art/bus-template-active.svg -> mac/Sources/SidebusApp/Resources/MenuBarActive.pdf
#
# The Android icons are VectorDrawables written by hand, converted once
# fois depuis les memes SVG : elles ne sont pas regenerees ici. Voir README.md.
#
# Usage : art/build.sh

set -euo pipefail

ART="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="$(cd "$ART/.." && pwd)"

for outil in rsvg-convert iconutil; do
	command -v "$outil" >/dev/null 2>&1 || {
		echo "$outil introuvable (rsvg-convert : brew install librsvg)" >&2
		exit 1
	}
done

# --- macOS application icon -----------------------------------------------
# Un iconset complet, 16 a 512, chacun en 1x et 2x, assemble par iconutil.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/Sidebus.iconset"
mkdir -p "$ICONSET"

for taille in 16 32 128 256 512; do
	rsvg-convert -w "$taille" -h "$taille" \
		"$ART/bus-app.svg" -o "$ICONSET/icon_${taille}x${taille}.png"
	rsvg-convert -w "$((taille * 2))" -h "$((taille * 2))" \
		"$ART/bus-app.svg" -o "$ICONSET/icon_${taille}x${taille}@2x.png"
done

mkdir -p "$RACINE/mac/Resources"
iconutil --convert icns "$ICONSET" --output "$RACINE/mac/Resources/Sidebus.icns"
echo "written: mac/Resources/Sidebus.icns"

# --- gabarits de la barre de menus ----------------------------------------
# En PDF et non en PNG : NSImage charge un PDF en vectoriel, donc le meme
# fichier sert en 1x et en 2x. Le SVG fait 24 px, soit 18 points dans le PDF,
# la hauteur attendue dans la barre de menus.
RES="$RACINE/mac/Sources/SidebusApp/Resources"
mkdir -p "$RES"
rsvg-convert --format pdf "$ART/bus-template.svg" --output "$RES/MenuBar.pdf"
rsvg-convert --format pdf "$ART/bus-template-active.svg" --output "$RES/MenuBarActive.pdf"
echo "written: mac/Sources/SidebusApp/Resources/MenuBar.pdf"
echo "written: mac/Sources/SidebusApp/Resources/MenuBarActive.pdf"
