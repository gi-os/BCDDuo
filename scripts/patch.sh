#!/usr/bin/env bash
# Usage: patch.sh <out.ipa>   (macOS + Xcode with vtool; needs gh)
#
# Turns BCD's release IPA into an unsigned one for the iPhone Duo. BCD is linked against the iOS 26.2 SDK,
# which iOS shows in a small window on the inner display, so raise the app's Mach-O linked-SDK to 27.1 for
# the full-edge layout (Apple's "Prepare your app for iPhone Duo"; same technique as LiquidTok's
# patch_duo.sh). Only the app's binary: the two extensions show no UI. Every bundle also gets our own ID.
set -euo pipefail
TAG=v0.1.634
SHA256=8bdbab38e99c52ad38f1ff67840119b9aa3bd9986082900d80fb30d49885c292   # a stranger's release: pinned
UPSTREAM=com.thebcd69.bcd
PREFIX=com.gios.bcd
TARGET=27.1

mkdir -p "$(dirname "$1")"
OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PB=/usr/libexec/PlistBuddy

gh release download "$TAG" -R thebcd69/bcd-games -p BCD.ipa -D "$WORK/dl"
echo "$SHA256  $WORK/dl/BCD.ipa" | shasum -a 256 -c -
unzip -q "$WORK/dl/BCD.ipa" -d "$WORK/x"
APP="$(find "$WORK/x/Payload" -maxdepth 1 -name '*.app' | head -1)"
BIN="$APP/$("$PB" -c 'Print :CFBundleExecutable' "$APP/Info.plist")"

MINOS="$(xcrun vtool -show-build "$BIN" | awk '$1 == "minos" { print $2; exit }')"
SDK="$(xcrun vtool -show-build "$BIN" | awk '$1 == "sdk" { print $2; exit }')"
[[ -n "$MINOS" && -n "$SDK" ]] || { echo "no LC_BUILD_VERSION in $BIN" >&2; exit 1; }
xcrun vtool -set-build-version ios "$MINOS" "$TARGET" -replace -output "$BIN.new" "$BIN"
mv "$BIN.new" "$BIN"
xcrun vtool -show-build "$BIN" | grep -q "sdk $TARGET" || { echo "SDK bump failed: $BIN" >&2; exit 1; }
echo "SDK $SDK -> $TARGET (minos $MINOS)"
"$PB" -c "Set :DTSDKName iphoneos$TARGET" "$APP/Info.plist"
"$PB" -c "Set :DTPlatformVersion $TARGET" "$APP/Info.plist"

# A distinct, higher CFBundleVersion per run, or iOS won't install a new build over the old one.
VERSION="$("$PB" -c 'Print :CFBundleVersion' "$APP/Info.plist").${GITHUB_RUN_NUMBER:-$(date +%s)}"
for BUNDLE in "$APP" "$APP"/PlugIns/*.appex; do
  OLD="$("$PB" -c 'Print :CFBundleIdentifier' "$BUNDLE/Info.plist")"
  [[ "$OLD" == "$UPSTREAM"* ]] || { echo "unexpected bundle ID: $OLD" >&2; exit 1; }
  NEW="$PREFIX${OLD#"$UPSTREAM"}"
  "$PB" -c "Set :CFBundleIdentifier $NEW" "$BUNDLE/Info.plist"
  "$PB" -c "Set :CFBundleVersion $VERSION" "$BUNDLE/Info.plist"
  echo "$OLD -> $NEW"
done
echo "CFBundleVersion -> $VERSION"

rm -f "$OUT"
( cd "$WORK/x" && zip -qry "$OUT" Payload )
echo "wrote $OUT"
