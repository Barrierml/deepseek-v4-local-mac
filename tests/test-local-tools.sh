#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for file in config.env bin/download-model.sh bin/verify-model.sh bin/install-launch-agent.sh bin/start.sh bin/stop.sh bin/status.sh bin/smoke-test.sh bin/tool-call-test.sh bin/acceptance-test.sh bin/openai-request-log-proxy.py; do
    [ -f "$ROOT/$file" ] || fail "$file is missing"
done

for file in bin/download-model.sh bin/verify-model.sh bin/install-launch-agent.sh bin/start.sh bin/stop.sh bin/status.sh bin/smoke-test.sh bin/tool-call-test.sh bin/acceptance-test.sh bin/openai-request-log-proxy.py; do
    [ -x "$ROOT/$file" ] || fail "$file is not executable"
done

grep -q '"tools"' "$ROOT/bin/tool-call-test.sh" ||
    fail "tool-call test does not send OpenAI tools"
grep -q 'tool_calls' "$ROOT/bin/tool-call-test.sh" ||
    fail "tool-call test does not assert returned tool_calls"
grep -q 'tool_choice' "$ROOT/bin/tool-call-test.sh" ||
    fail "tool-call test does not cover tool_choice"

grep -q 'LAUNCH_MODE:=launchd' "$ROOT/config.env" ||
    fail "production config does not use launchd"

PLIST_PATH="$TMP/ai.deepseek-v4-local.plist"
PLIST_PATH="$PLIST_PATH" PLIST_ONLY=1 LAUNCH_LABEL=ai.deepseek-v4-local.test \
    "$ROOT/bin/install-launch-agent.sh" >/dev/null
plutil -lint "$PLIST_PATH" >/dev/null ||
    fail "generated LaunchAgent plist is invalid"
grep -q '<string>--ssd-streaming</string>' "$PLIST_PATH" ||
    fail "generated LaunchAgent does not enable SSD streaming"
KV_DISK_DIR="$TMP/kv-cache" PLIST_PATH="$PLIST_PATH" PLIST_ONLY=1 LAUNCH_LABEL=ai.deepseek-v4-local.test \
    "$ROOT/bin/install-launch-agent.sh" >/dev/null
grep -q '<string>--kv-disk-dir</string>' "$PLIST_PATH" ||
    fail "generated LaunchAgent does not include KV disk cache when configured"
grep -q 'launchctl print.*LAUNCH_LABEL' "$ROOT/bin/start.sh" ||
    fail "start does not detect an already-loaded LaunchAgent"
grep -q 'cmp -s.*PLIST_PATH' "$ROOT/bin/install-launch-agent.sh" ||
    fail "LaunchAgent installer does not preserve an unchanged loaded service"

cli_block=$(sed -n '/"$DS4_CLI"/,/^[[:space:]]*)/p' "$ROOT/bin/acceptance-test.sh")
if printf '%s\n' "$cli_block" | grep -q -- '--chdir'; then
    fail "acceptance CLI command uses server-only --chdir"
fi
grep -q '2>"$CLI_RUNTIME_LOG"' "$ROOT/bin/acceptance-test.sh" ||
    fail "acceptance CLI command does not separate runtime logs from generated stdout"

MODEL="$TMP/model.gguf"
printf 'fixture-model\n' >"$MODEL"
SIZE=$(wc -c <"$MODEL" | tr -d ' ')
SHA=$(shasum -a 256 "$MODEL" | awk '{print $1}')
VERIFIED_STAMP="$TMP/model.verified"

MODEL_PATH="$MODEL" MODEL_SIZE="$SIZE" MODEL_SHA256="$SHA" VERIFIED_STAMP="$VERIFIED_STAMP" \
    "$ROOT/bin/verify-model.sh" >/dev/null

cat >"$TMP/shasum" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod +x "$TMP/shasum"
MODEL_PATH="$MODEL" MODEL_SIZE="$SIZE" MODEL_SHA256="$SHA" \
    VERIFIED_STAMP="$VERIFIED_STAMP" PATH="$TMP:$PATH" \
    "$ROOT/bin/verify-model.sh" >/dev/null ||
    fail "verify-model did not reuse the unchanged verified-file stamp"

if MODEL_PATH="$MODEL" MODEL_SIZE="$((SIZE + 1))" MODEL_SHA256="$SHA" \
    VERIFIED_STAMP="$VERIFIED_STAMP" \
    "$ROOT/bin/verify-model.sh" >/dev/null 2>&1; then
    fail "verify-model accepted a wrong file size"
fi

if MODEL_PATH="$MODEL" MODEL_SIZE="$SIZE" MODEL_SHA256=deadbeef \
    VERIFIED_STAMP="$VERIFIED_STAMP" \
    "$ROOT/bin/verify-model.sh" >/dev/null 2>&1; then
    fail "verify-model accepted a wrong checksum"
fi

FAKE_SERVER="$TMP/fake-server"
cat >"$FAKE_SERVER" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "$FAKE_SERVER"

PID_FILE="$TMP/server.pid"
LOG_FILE="$TMP/server.log"
COMMON_ENV="ROOT=$ROOT MODEL_PATH=$MODEL MODEL_SIZE=$SIZE MODEL_SHA256=$SHA VERIFIED_STAMP=$VERIFIED_STAMP DS4_SERVER=$FAKE_SERVER PID_FILE=$PID_FILE LOG_FILE=$LOG_FILE SKIP_HEALTH_CHECK=1 LAUNCH_MODE=direct"

env $COMMON_ENV "$ROOT/bin/start.sh" >/dev/null
[ -s "$PID_FILE" ] || fail "start did not create a pid file"
PID=$(cat "$PID_FILE")
kill -0 "$PID" 2>/dev/null || fail "recorded server process is not alive"

env $COMMON_ENV "$ROOT/bin/start.sh" >/dev/null
[ "$(cat "$PID_FILE")" = "$PID" ] || fail "second start replaced the live server"

env $COMMON_ENV "$ROOT/bin/status.sh" >/dev/null
env $COMMON_ENV "$ROOT/bin/stop.sh" >/dev/null
if kill -0 "$PID" 2>/dev/null; then
    fail "stop left the server process alive"
fi

if env $COMMON_ENV "$ROOT/bin/status.sh" >/dev/null 2>&1; then
    fail "status reported a stopped server as running"
fi

printf 'PASS: local deployment tool contract\n'
