#!/usr/bin/env bash
# Usage: install_link.sh [run-id] [minutes]   (on the Mac mini; needs gh, cloudflared, python3)
# Serves the signed IPA from a build run (default: latest successful one on main) as a tap-to-install
# link: a Cloudflare quick tunnel (random https://*.trycloudflare.com host) plus a random path. Prints
# the link, then stops after [minutes] (default 20) so nothing stays exposed. Only devices in the
# development profile can install it.
set -euo pipefail
RUN="${1:-}"; MINUTES="${2:-20}"
REPO=gi-os/BCDDuo
if [[ -z "$RUN" ]]; then
  RUN="$(gh run list -R "$REPO" --workflow build.yml --branch main --status success --limit 1 --json databaseId -q '.[0].databaseId')"
fi
DIR="$(mktemp -d)"; TOKEN="$(openssl rand -hex 16)"; WWW="$DIR/www/$TOKEN"; mkdir -p "$WWW"
: >"$DIR/www/index.html"   # no directory listing at /, so the random path stays secret
PIDS=()
cleanup() { kill ${PIDS[@]+"${PIDS[@]}"} 2>/dev/null || true; rm -rf "$DIR"; }
trap cleanup EXIT

gh run download "$RUN" -R "$REPO" -n BCD-development -D "$WWW"
IPA="$WWW/BCD.ipa"
# Builds upload it encrypted to this Mac (the repo is public): a one-time key encrypted to
# artifact-key.pub.pem, whose private half is ~/.config/liquidbird/artifact-key.pem.
LB_KEY="$(/usr/bin/openssl pkeyutl -decrypt -inkey "$HOME/.config/liquidbird/artifact-key.pem" \
  -pkeyopt rsa_padding_mode:oaep -in "$WWW/BCD.key.enc")" \
  /usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:LB_KEY -in "$IPA.enc" -out "$IPA"
rm "$IPA.enc" "$WWW/BCD.key.enc"
VERSION="$(unzip -p "$IPA" 'Payload/*.app/Info.plist' | plutil -extract CFBundleShortVersionString raw -o - -)"

PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR/www" >"$DIR/http.log" 2>&1 & PIDS+=($!)
# Its own empty config: ~/.cloudflared/config.yml (the named BlueBubbles tunnel) ends in a catch-all
# 404 rule that would otherwise apply to this quick tunnel too.
echo "no-autoupdate: true" >"$DIR/cloudflared.yml"
cloudflared tunnel --config "$DIR/cloudflared.yml" --url "http://127.0.0.1:$PORT" >"$DIR/tunnel.log" 2>&1 & PIDS+=($!)
HOST=""
for _ in $(seq 60); do
  HOST="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$DIR/tunnel.log" | head -1 || true)"
  [[ -n "$HOST" ]] && break; sleep 1
done
[[ -n "$HOST" ]] || { echo "cloudflared didn't start a tunnel:" >&2; tail -20 "$DIR/tunnel.log" >&2; exit 1; }
BASE="$HOST/$TOKEN"

cat >"$WWW/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>$BASE/BCD.ipa</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>com.gios.bcd</string>
    <key>bundle-version</key><string>$VERSION</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>BCD</string>
  </dict>
</dict></array></dict></plist>
PLIST
cat >"$WWW/index.html" <<HTML
<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<title>BCD</title>
<body style="font:20px -apple-system;text-align:center;padding-top:30vh">
<a href="itms-services://?action=download-manifest&amp;url=$BASE/manifest.plist"
   style="padding:16px 32px;border-radius:14px;background:#28c7d9;color:#fff;text-decoration:none">Install BCD $VERSION</a>
HTML

# The tunnel hostname takes a few seconds to resolve everywhere.
for _ in $(seq 30); do curl -fsS -o /dev/null "$BASE/index.html" 2>/dev/null && break; sleep 2; done
echo "Install link (run $RUN, BCD $VERSION), open on the iPhone in Safari: $BASE/index.html"
echo "Stops in $MINUTES minutes."
sleep $(( MINUTES * 60 ))
