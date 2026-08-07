#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

"$ROOT/bin/verify-model.sh" >/dev/null
[ -x "$DS4_SERVER" ] || {
    printf 'ds4-server is missing or not executable: %s\n' "$DS4_SERVER" >&2
    exit 1
}

mkdir -p "$STATE_DIR"
if [ "$LAUNCH_MODE" = launchd ]; then
    if launchctl print "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1 &&
        curl -fsS "http://$SERVER_HOST:$SERVER_PORT/v1/models" >/dev/null 2>&1; then
        launch_pid=$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null |
            awk '/pid =/ { print $3; exit }')
        printf 'server already healthy via LaunchAgent: http://%s:%s (pid %s)\n' \
            "$SERVER_HOST" "$SERVER_PORT" "${launch_pid:-unknown}"
        exit 0
    fi
    "$ROOT/bin/install-launch-agent.sh" >/dev/null
    deadline=$(( $(date +%s) + SERVER_START_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS "http://$SERVER_HOST:$SERVER_PORT/v1/models" >/dev/null 2>&1; then
            launch_pid=$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null |
                awk '/pid =/ { print $3; exit }')
            if [ -n "$launch_pid" ]; then
                printf '%s\n' "$launch_pid" >"$PID_FILE"
            fi
            printf 'server ready via LaunchAgent: http://%s:%s (pid %s)\n' \
                "$SERVER_HOST" "$SERVER_PORT" "${launch_pid:-unknown}"
            exit 0
        fi
        sleep 2
    done
    printf 'LaunchAgent server did not become healthy within %s seconds; inspect %s\n' \
        "$SERVER_START_TIMEOUT" "$LOG_FILE" >&2
    exit 1
fi

if [ -s "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        printf 'server already running (pid %s)\n' "$old_pid"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

(
    cd "$DS4_DIR"
    exec "$DS4_SERVER" \
        --chdir "$DS4_DIR" \
        -m "$MODEL_PATH" \
        --metal \
        --ssd-streaming \
        --ssd-streaming-cache-experts "$EXPERT_CACHE" \
        --prefill-chunk "$PREFILL_CHUNK" \
        --ctx "$SERVER_CTX" \
        --tokens "$SERVER_TOKENS" \
        --host "$SERVER_HOST" \
        --port "$SERVER_PORT"
) >>"$LOG_FILE" 2>&1 &
server_pid=$!
printf '%s\n' "$server_pid" >"$PID_FILE"

if [ "${SKIP_HEALTH_CHECK:-0}" = 1 ]; then
    printf 'server started (pid %s)\n' "$server_pid"
    exit 0
fi

deadline=$(( $(date +%s) + SERVER_START_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        printf 'server exited during startup; inspect %s\n' "$LOG_FILE" >&2
        tail -n 80 "$LOG_FILE" >&2 || true
        exit 1
    fi
    if curl -fsS "http://$SERVER_HOST:$SERVER_PORT/v1/models" >/dev/null 2>&1; then
        printf 'server ready: http://%s:%s (pid %s)\n' "$SERVER_HOST" "$SERVER_PORT" "$server_pid"
        exit 0
    fi
    sleep 2
done

printf 'server did not become healthy within %s seconds; inspect %s\n' \
    "$SERVER_START_TIMEOUT" "$LOG_FILE" >&2
exit 1
