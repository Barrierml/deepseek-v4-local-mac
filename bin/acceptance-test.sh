#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

mkdir -p "$ROOT/acceptance" "$STATE_DIR"
REPORT="$ROOT/acceptance/acceptance-report.md"
INSPECT_LOG="$ROOT/acceptance/inspect.log"
CLI_LOG="$ROOT/acceptance/cli-generation.log"
CLI_RUNTIME_LOG="$ROOT/acceptance/cli-runtime.log"

"$ROOT/bin/verify-model.sh"
[ -x "$DS4_CLI" ] || {
    printf 'ds4 CLI is missing or not executable: %s\n' "$DS4_CLI" >&2
    exit 1
}

"$ROOT/bin/stop.sh" >/dev/null

(
    cd "$DS4_DIR"
    "$DS4_CLI" \
        -m "$MODEL_PATH" \
        --metal \
        --ssd-streaming \
        --ssd-streaming-cache-experts "$EXPERT_CACHE" \
        --ctx 4096 \
        --inspect
) >"$INSPECT_LOG" 2>&1

(
    cd "$DS4_DIR"
    "$DS4_CLI" \
        -m "$MODEL_PATH" \
        --metal \
        --ssd-streaming \
        --ssd-streaming-cache-experts "$EXPERT_CACHE" \
        --prefill-chunk 512 \
        --ctx 4096 \
        --tokens 24 \
        --temp 0 \
        --nothink \
        -p 'Reply with exactly: LOCAL_CLI_OK'
) >"$CLI_LOG" 2>"$CLI_RUNTIME_LOG"
grep -q '[^[:space:]]' "$CLI_LOG"

"$ROOT/bin/start.sh"
"$ROOT/bin/smoke-test.sh"

"$ROOT/bin/stop.sh"
"$ROOT/bin/start.sh"
"$ROOT/bin/smoke-test.sh"

launch_evidence=
if [ "$LAUNCH_MODE" = launchd ]; then
    launchctl print "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null
    launch_pid=$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" |
        awk '/pid =/ { print $3; exit }')
    [ -n "$launch_pid" ]
    launch_ppid=$(ps -o ppid= -p "$launch_pid" | tr -d ' ')
    [ "$launch_ppid" = 1 ]
    launch_evidence="- macOS LaunchAgent \`$LAUNCH_LABEL\` 已加载，服务 PID $launch_pid 由 PID 1 托管"
fi

model_sha=$MODEL_SHA256
model_size=$MODEL_SIZE
ds4_commit=$(git -C "$DS4_DIR" rev-parse HEAD)
completed_at=$(date '+%Y-%m-%d %H:%M:%S %Z')

cat >"$REPORT" <<EOF
# DeepSeek V4 Flash 本地部署验收报告

- 完成时间：$completed_at
- 模型：$MODEL_PATH
- 模型字节数：$model_size
- 模型 SHA256：$model_sha
- ds4 commit：$ds4_commit
- API：http://$SERVER_HOST:$SERVER_PORT/v1
- Context：$SERVER_CTX
- SSD 专家缓存：$EXPERT_CACHE

## 已覆盖且通过

- 模型文件大小和 SHA256 校验
- ds4 Metal 构建识别真实 GGUF（\`acceptance/inspect.log\`）
- CLI SSD streaming 真实生成（\`acceptance/cli-generation.log\`，运行日志在 \`acceptance/cli-runtime.log\`）
- \`GET /v1/models\`
- OpenAI \`POST /v1/chat/completions\` 非流式生成
- OpenAI \`POST /v1/chat/completions\` SSE 流式生成及 \`[DONE]\`
- 服务停止后重启
- 重启后健康检查与第二次真实生成
- 验收结束后服务保持在线
$launch_evidence

## 未覆盖

- DSpark speculative decoding：需要额外支持模型，不是基础服务门槛。
- 多会话 batching：48 GB 机器采用单会话，避免重复 KV 状态挤占工作集。
EOF

printf 'PASS: full local acceptance; server remains online\n'
