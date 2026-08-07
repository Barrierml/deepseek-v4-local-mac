#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

if [ "$LAUNCH_MODE" = launchd ]; then
    if ! launchctl print "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1; then
        printf 'LaunchAgent server stopped\n'
        exit 1
    fi
    pid=$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null |
        awk '/pid =/ { print $3; exit }')
    if [ "${SKIP_HEALTH_CHECK:-0}" != 1 ]; then
        curl -fsS "http://$SERVER_HOST:$SERVER_PORT/v1/models" >/dev/null || {
            printf 'LaunchAgent is loaded but API is not healthy\n'
            exit 2
        }
    fi
    printf 'server healthy via LaunchAgent: http://%s:%s (pid %s)\n' \
        "$SERVER_HOST" "$SERVER_PORT" "${pid:-unknown}"
    exit 0
fi

if [ ! -s "$PID_FILE" ]; then
    printf 'server stopped\n'
    exit 1
fi

pid=$(cat "$PID_FILE")
if ! kill -0 "$pid" 2>/dev/null; then
    printf 'server stopped (stale pid file)\n'
    exit 1
fi

if [ "${SKIP_HEALTH_CHECK:-0}" != 1 ]; then
    curl -fsS "http://$SERVER_HOST:$SERVER_PORT/v1/models" >/dev/null || {
        printf 'server process is alive but API is not healthy (pid %s)\n' "$pid"
        exit 2
    }
fi

printf 'server healthy: http://%s:%s (pid %s)\n' "$SERVER_HOST" "$SERVER_PORT" "$pid"
