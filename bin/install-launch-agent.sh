#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

mkdir -p "$(dirname "$PLIST_PATH")" "$STATE_DIR"
tmp_plist="$PLIST_PATH.tmp"
cat >"$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DS4_SERVER</string>
    <string>--chdir</string>
    <string>$DS4_DIR</string>
    <string>-m</string>
    <string>$MODEL_PATH</string>
    <string>--metal</string>
    <string>--ssd-streaming</string>
    <string>--ssd-streaming-cache-experts</string>
    <string>$EXPERT_CACHE</string>
    <string>--prefill-chunk</string>
    <string>$PREFILL_CHUNK</string>
    <string>--ctx</string>
    <string>$SERVER_CTX</string>
    <string>--tokens</string>
    <string>$SERVER_TOKENS</string>
    <string>--host</string>
    <string>$SERVER_HOST</string>
    <string>--port</string>
    <string>$SERVER_PORT</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$DS4_DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
EOF
plutil -lint "$tmp_plist" >/dev/null

if [ "${PLIST_ONLY:-0}" = 1 ]; then
    mv "$tmp_plist" "$PLIST_PATH"
    printf 'LaunchAgent plist written: %s\n' "$PLIST_PATH"
    exit 0
fi

domain="gui/$(id -u)"
loaded=0
if launchctl print "$domain/$LAUNCH_LABEL" >/dev/null 2>&1; then
    loaded=1
fi
unchanged=0
if [ -f "$PLIST_PATH" ] && cmp -s "$tmp_plist" "$PLIST_PATH"; then
    unchanged=1
fi

if [ "$unchanged" = 1 ]; then
    rm -f "$tmp_plist"
else
    if [ "$loaded" = 1 ]; then
        launchctl bootout "$domain/$LAUNCH_LABEL"
        loaded=0
    fi
    mv "$tmp_plist" "$PLIST_PATH"
fi

if [ "$loaded" = 0 ]; then
    launchctl bootstrap "$domain" "$PLIST_PATH"
fi
launchctl enable "$domain/$LAUNCH_LABEL"
if [ "$unchanged" = 0 ]; then
    launchctl kickstart -k "$domain/$LAUNCH_LABEL"
fi
printf 'LaunchAgent installed: %s\n' "$PLIST_PATH"
