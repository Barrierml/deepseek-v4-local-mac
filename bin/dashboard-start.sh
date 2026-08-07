#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

: "${DASHBOARD_PID_FILE:=$STATE_DIR/dashboard.pid}"
: "${DASHBOARD_LOG_FILE:=$STATE_DIR/dashboard.log}"

mkdir -p "$STATE_DIR"
"$ROOT/bin/dashboard-install-launch-agent.sh" >/dev/null

for _ in $(seq 1 60); do
    if curl -fsS "http://$DASHBOARD_HOST:$DASHBOARD_PORT/api/stats" >/dev/null 2>&1; then
        pid=$(launchctl print "gui/$(id -u)/$DASHBOARD_LABEL" 2>/dev/null |
            awk '/pid =/ { print $3; exit }')
        [ -n "$pid" ] && printf '%s\n' "$pid" >"$DASHBOARD_PID_FILE"
        printf 'dashboard ready: http://%s:%s (pid %s)\n' \
            "$DASHBOARD_HOST" "$DASHBOARD_PORT" "${pid:-unknown}"
        exit 0
    fi
    sleep 1
done

printf 'dashboard did not become healthy; inspect %s\n' "$DASHBOARD_LOG_FILE" >&2
exit 1
