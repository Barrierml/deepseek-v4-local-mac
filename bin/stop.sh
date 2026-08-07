#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

if [ "$LAUNCH_MODE" = launchd ]; then
    launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    printf 'LaunchAgent server stopped
'
    exit 0
fi

if [ ! -s "$PID_FILE" ]; then
    printf 'server is not running\n'
    exit 0
fi

pid=$(cat "$PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    remaining=30
    while kill -0 "$pid" 2>/dev/null && [ "$remaining" -gt 0 ]; do
        sleep 1
        remaining=$((remaining - 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid"
    fi
fi
rm -f "$PID_FILE"
printf 'server stopped\n'
