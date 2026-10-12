#!/bin/sh
# Builds CallAudioProbe into a dex, pushes it, and runs it as the shell user.
set -e
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BUILD_TOOLS="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"
OUT="$(mktemp -d)"
javac -source 11 -target 11 -nowarn -cp "$ANDROID_JAR" -d "$OUT" CallAudioProbe.java 2>/dev/null
"$BUILD_TOOLS/d8" --min-api 33 --lib "$ANDROID_JAR" --output "$OUT" "$OUT"/*.class
adb push "$OUT/classes.dex" /data/local/tmp/callaudioprobe.dex >/dev/null
adb shell CLASSPATH=/data/local/tmp/callaudioprobe.dex app_process / CallAudioProbe "$@"
