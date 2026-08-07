#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

mkdir -p "$(dirname "$DASHBOARD_PLIST_PATH")" "$STATE_DIR"
tmp_plist="$DASHBOARD_PLIST_PATH.tmp"
cat >"$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$DASHBOARD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(command -v python3)</string>
    <string>$ROOT/dashboard/server.py</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DASHBOARD_HOST</key>
    <string>$DASHBOARD_HOST</string>
    <key>DASHBOARD_PORT</key>
    <string>$DASHBOARD_PORT</string>
    <key>DS4_BASE</key>
    <string>http://$SERVER_HOST:$SERVER_PORT</string>
    <key>LAUNCH_LABEL</key>
    <string>$LAUNCH_LABEL</string>
    <key>EXPERT_CACHE</key>
    <string>$EXPERT_CACHE</string>
    <key>SERVER_CTX</key>
    <string>$SERVER_CTX</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$STATE_DIR/dashboard.log</string>
  <key>StandardErrorPath</key>
  <string>$STATE_DIR/dashboard.log</string>
</dict>
</plist>
EOF
plutil -lint "$tmp_plist" >/dev/null

domain="gui/$(id -u)"
loaded=0
if launchctl print "$domain/$DASHBOARD_LABEL" >/dev/null 2>&1; then
    loaded=1
fi
unchanged=0
if [ -f "$DASHBOARD_PLIST_PATH" ] && cmp -s "$tmp_plist" "$DASHBOARD_PLIST_PATH"; then
    unchanged=1
fi
if [ "$unchanged" = 1 ]; then
    rm -f "$tmp_plist"
else
    if [ "$loaded" = 1 ]; then
        launchctl bootout "$domain/$DASHBOARD_LABEL"
        loaded=0
    fi
    mv "$tmp_plist" "$DASHBOARD_PLIST_PATH"
fi
if [ "$loaded" = 0 ]; then
    launchctl bootstrap "$domain" "$DASHBOARD_PLIST_PATH"
fi
launchctl enable "$domain/$DASHBOARD_LABEL"
if [ "$unchanged" = 0 ]; then
    launchctl kickstart -k "$domain/$DASHBOARD_LABEL"
fi
printf 'dashboard LaunchAgent installed: %s\n' "$DASHBOARD_PLIST_PATH"
