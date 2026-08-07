#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

base="http://$SERVER_HOST:$SERVER_PORT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$ROOT/bin/status.sh"

curl -fsS "$base/v1/models" >"$tmp/models.json"
python3 - "$tmp/models.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("data"), data
PY

curl -fsS "$base/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Reply with exactly: LOCAL_OK"}],"max_tokens":24,"temperature":0,"reasoning_effort":"none","stream":false}' \
    >"$tmp/chat.json"
python3 - "$tmp/chat.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
choices = data.get("choices") or []
assert choices, data
content = (choices[0].get("message") or {}).get("content") or ""
assert content.strip(), data
print("non-stream response:", content.strip().replace("\n", " ")[:200])
PY

curl -fsS "$base/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"What is 1+1? Keep the final answer brief."}],"max_tokens":48,"temperature":0,"reasoning_effort":"low","stream":false}' \
    >"$tmp/thinking.json"
python3 - "$tmp/thinking.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
choices = data.get("choices") or []
assert choices, data
message = choices[0].get("message") or {}
observed = (message.get("reasoning_content") or "") + (message.get("content") or "")
assert observed.strip(), data
print("thinking response observed")
PY

curl -fsS -N "$base/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Count from 1 to 3."}],"max_tokens":32,"temperature":0,"reasoning_effort":"none","stream":true}' \
    >"$tmp/stream.txt"
grep -q '^data:' "$tmp/stream.txt"
grep -q '\[DONE\]' "$tmp/stream.txt"

printf 'PASS: models, direct chat, thinking chat, and streaming chat\n'
