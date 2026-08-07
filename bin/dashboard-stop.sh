#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

: "${DASHBOARD_PID_FILE:=$STATE_DIR/dashboard.pid}"

if [ -n "${DASHBOARD_LABEL:-}" ]; then
    launchctl bootout "gui/$(id -u)/$DASHBOARD_LABEL" >/dev/null 2>&1 || true
fi
if [ ! -s "$DASHBOARD_PID_FILE" ]; then
    printf 'dashboard is not running\n'
    exit 0
fi

pid=$(cat "$DASHBOARD_PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
fi
rm -f "$DASHBOARD_PID_FILE"
printf 'dashboard stopped\n'
