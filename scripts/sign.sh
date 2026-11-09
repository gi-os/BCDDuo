#!/usr/bin/env bash
# Usage: sign.sh <in.ipa> <out.ipa> <identity> <app profile> <JIT helper profile> <memory host profile>
#
# Development-signs the patched IPA. Run by the sign job, which holds the signing secrets, so it only ever
# reads the third-party bundle: nothing in it is executed. By hand rather than fastlane's resign because
# BCD keeps libraries outside Frameworks/ (gl/, d3d12/), and those have to be re-signed too.
set -euo pipefail
IN="$1"; OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; ID="$3"
APP_PROFILE="$4"; JIT_PROFILE="$5"; MEMORY_PROFILE="$6"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PB=/usr/libexec/PlistBuddy

unzip -q "$IN" -d "$WORK/x"
APP="$(find "$WORK/x/Payload" -maxdepth 1 -name '*.app' | head -1)"

sign() { /usr/bin/codesign --force --sign "$ID" --timestamp=none --generate-entitlement-der "$@"; }

# Signs a bundle with what development signing needs (get-task-allow is what lets JIT attach), plus any
# extra boolean entitlements its profile allows. A capability missing from the App ID is a warning: the
# app still installs, it just shows Memory+ off.
sign_bundle() {   # <bundle> <profile> [entitlement...]
  local bundle="$1" profile="$2" decoded ents team id key; shift 2
  decoded="$WORK/$(basename "$bundle").profile.plist"; ents="$WORK/$(basename "$bundle").entitlements"
  security cms -D -i "$profile" >"$decoded"
  team="$("$PB" -c 'Print :TeamIdentifier:0' "$decoded")"
  id="$("$PB" -c 'Print :CFBundleIdentifier' "$bundle/Info.plist")"
  [[ "$("$PB" -c 'Print :Entitlements:get-task-allow' "$decoded")" == true ]] \
    || { echo "not a development profile: $id" >&2; exit 1; }
  cat >"$ents" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$team.$id</string>
  <key>com.apple.developer.team-identifier</key><string>$team</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>$team.$id</string></array>
</dict></plist>
PLIST
  for key in "$@"; do
    if "$PB" -c "Print :Entitlements:$key" "$decoded" >/dev/null 2>&1; then
      "$PB" -c "Add :$key bool true" "$ents"
    else
      echo "::warning::$id: the profile doesn't allow $key"
    fi
  done
  cp "$profile" "$bundle/embedded.mobileprovision"
  sign --entitlements "$ents" "$bundle"
}

# Inside out: loose libraries, then frameworks, then extensions, then the app.
while IFS= read -r FILE; do
  DIR="$(dirname "$FILE")"
  case "$DIR" in
    *.app|*.appex|*.framework)
      [[ "$(basename "$FILE")" == "$("$PB" -c 'Print :CFBundleExecutable' "$DIR/Info.plist")" ]] && continue ;;
  esac
  sign "$FILE"
done < <(find "$APP" -type f -print0 | xargs -0 file -F $'\t' | awk -F'\t' '/Mach-O/ { print $1 }')
for FRAMEWORK in "$APP"/Frameworks/*.framework; do sign "$FRAMEWORK"; done
sign_bundle "$APP/PlugIns/MadeiraJITHelper.appex" "$JIT_PROFILE"
sign_bundle "$APP/PlugIns/MadeiraMemoryHost.appex" "$MEMORY_PROFILE"
sign_bundle "$APP" "$APP_PROFILE" \
  com.apple.developer.kernel.increased-memory-limit \
  com.apple.developer.kernel.extended-virtual-addressing

/usr/bin/codesign --verify --deep --strict "$APP"
# Key names only: the values carry the team ID, and the repo's logs are public.
echo "App entitlements: $(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | awk -F'"' '/^  "/ { print $2 }' | tr '\n' ' ')"

rm -f "$OUT"
( cd "$WORK/x" && zip -qry "$OUT" Payload )
echo "wrote $OUT"
