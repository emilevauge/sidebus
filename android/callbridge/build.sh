#!/bin/sh
# Builds CallBridge.java into a dex: build.sh <output.dex>
# The Mac app carries it and pushes it to the phone; see CallBridge.java.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$HERE/callbridge.dex}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BUILD_TOOLS="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
javac -source 11 -target 11 -nowarn -Xlint:-options -cp "$ANDROID_JAR" -d "$WORK" "$HERE/CallBridge.java"
"$BUILD_TOOLS/d8" --min-api 33 --lib "$ANDROID_JAR" --output "$WORK" "$WORK"/*.class
cp "$WORK/classes.dex" "$OUTPUT"
