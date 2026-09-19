#!/bin/bash
#
# Cuts a Sidebus release: bumps the version, builds both applications, packages the disk
# image, tags, and publishes on GitHub with the two artifacts attached.
#
# The Mac application checks that release once a day and can replace itself from the disk
# image, so the asset must keep the name `Sidebus.dmg`. See
# `mac/Sources/SidebusApp/UpdateChecker.swift`.
#
# Usage:
#   Scripts/publish.sh patch        0.1.0 -> 0.1.1
#   Scripts/publish.sh minor        0.1.0 -> 0.2.0
#   Scripts/publish.sh major        0.1.0 -> 1.0.0
#   Scripts/publish.sh 1.4.2        an explicit version
#   Scripts/publish.sh patch --dry-run   builds and packages, publishes nothing
#
# The disk image is signed with the local identity, not with a Developer ID. Gatekeeper
# would refuse it on another Mac, but the self updater strips the quarantine flag, so the
# in app path works. A download by hand on a third party Mac needs `xattr -dr
# com.apple.quarantine` or a proper notarized build through `mac/Scripts/release.sh`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUMP="${1:-}"
DRY_RUN="${2:-}"

if [[ -z "$BUMP" ]]; then
	echo "usage: Scripts/publish.sh <patch|minor|major|X.Y.Z> [--dry-run]" >&2
	exit 1
fi

# --- preflight -------------------------------------------------------------

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
	echo "working tree is not clean, commit or stash first" >&2
	git status --short >&2
	exit 1
fi

BRANCH="$(git branch --show-current)"
if [[ "$BRANCH" != "main" ]]; then
	echo "releases are cut from main, currently on $BRANCH" >&2
	exit 1
fi

CURRENT="$(cat VERSION)"

case "$BUMP" in
	major|minor|patch)
		IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT"
		case "$BUMP" in
			major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
			minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
			patch) PATCH=$((PATCH + 1)) ;;
		esac
		VERSION="$MAJOR.$MINOR.$PATCH"
		;;
	[0-9]*.[0-9]*.[0-9]*)
		VERSION="$BUMP"
		;;
	*)
		echo "unknown bump: $BUMP" >&2
		exit 1
		;;
esac

echo "==> $CURRENT -> $VERSION"

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
	echo "tag v$VERSION already exists" >&2
	exit 1
fi

# --- build -----------------------------------------------------------------

echo "$VERSION" > VERSION

# Tests before anything is published. A broken release is worse than a late one.
echo "==> Swift tests"
(cd mac && swift test >/dev/null)

echo "==> Kotlin tests"
(cd android && ./gradlew --quiet testDebugUnitTest)

echo "==> macOS bundle"
(cd mac && ./Scripts/bundle.sh >/dev/null)

echo "==> Android APK"
(cd android && ./gradlew --quiet assembleRelease || ./gradlew --quiet assembleDebug)

APK="$ROOT/android/app/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || APK="$ROOT/android/app/build/outputs/apk/release/app-release-unsigned.apk"
[[ -f "$APK" ]] || APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
[[ -f "$APK" ]] || { echo "no APK produced" >&2; exit 1; }

# --- package ---------------------------------------------------------------

APP="$ROOT/mac/build/Sidebus.app"
DMG="$ROOT/mac/build/Sidebus.dmg"

echo "==> Sidebus.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sidebus" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

STAGED_APK="$ROOT/mac/build/Sidebus.apk"
cp "$APK" "$STAGED_APK"

echo "    $(du -h "$DMG" | cut -f1)  Sidebus.dmg"
echo "    $(du -h "$STAGED_APK" | cut -f1)  Sidebus.apk"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
	git checkout -- VERSION
	echo "==> dry run, nothing published, VERSION restored"
	exit 0
fi

# --- publish ---------------------------------------------------------------

NOTES="$(git log --pretty='- %s' "v$CURRENT..HEAD" 2>/dev/null || git log --pretty='- %s' -20)"

git add VERSION
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "Sidebus $VERSION"
git push -q origin main
git push -q origin "v$VERSION"

gh release create "v$VERSION" \
	--title "Sidebus $VERSION" \
	--notes "$NOTES" \
	"$DMG#Sidebus.dmg" \
	"$STAGED_APK#Sidebus.apk"

echo "==> published https://github.com/emilevauge/sidebus/releases/tag/v$VERSION"
