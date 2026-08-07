#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

base="http://$SERVER_HOST:$SERVER_PORT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$ROOT/bin/status.sh"

cat >"$tmp/tool-call-request.json" <<'JSON'
{
  "model": "deepseek-v4-flash",
  "messages": [
    {
      "role": "user",
      "content": "Use get_weather for Shanghai. Do not answer directly."
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": { "type": "string" }
          },
          "required": ["city"]
        }
      }
    }
  ],
  "tool_choice": "auto",
  "max_tokens": 128,
  "temperature": 0,
  "reasoning_effort": "none",
  "stream": false
}
JSON

curl -fsS "$base/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d @"$tmp/tool-call-request.json" \
    >"$tmp/tool-call.json"

python3 - "$tmp/tool-call.json" "$tmp/tool-call-id.txt" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
choice = (data.get("choices") or [{}])[0]
message = choice.get("message") or {}
calls = message.get("tool_calls") or []
assert choice.get("finish_reason") == "tool_calls", data
assert calls, data
call = calls[0]
assert call.get("type") == "function", data
fn = call.get("function") or {}
assert fn.get("name") == "get_weather", data
args = json.loads(fn.get("arguments") or "{}")
assert args.get("city", "").lower() in ("shanghai", "上海"), data
open(sys.argv[2], "w").write(call.get("id") or "call_weather")
print("tool call:", fn.get("name"), json.dumps(args, ensure_ascii=False))
PY

tool_call_id=$(cat "$tmp/tool-call-id.txt")

python3 - "$tmp/tool-call.json" "$tmp/tool-result-request.json" "$tool_call_id" <<'PY'
import json
import sys

first = json.load(open(sys.argv[1]))
message = first["choices"][0]["message"]
tool_call_id = sys.argv[3]
payload = {
    "model": "deepseek-v4-flash",
    "messages": [
        {
            "role": "user",
            "content": "Use get_weather for Shanghai. Do not answer directly.",
        },
        message,
        {
            "role": "tool",
            "tool_call_id": tool_call_id,
            "content": "{\"city\":\"Shanghai\",\"condition\":\"clear\",\"temperature_c\":26}",
        },
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get current weather for a city.",
                "parameters": {
                    "type": "object",
                    "properties": {"city": {"type": "string"}},
                    "required": ["city"],
                },
            },
        }
    ],
    "tool_choice": "auto",
    "max_tokens": 96,
    "temperature": 0,
    "reasoning_effort": "none",
    "stream": False,
}
json.dump(payload, open(sys.argv[2], "w"))
PY

curl -fsS "$base/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d @"$tmp/tool-result-request.json" \
    >"$tmp/tool-result.json"

python3 - "$tmp/tool-result.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
choice = (data.get("choices") or [{}])[0]
message = choice.get("message") or {}
content = message.get("content") or ""
assert content.strip(), data
assert not message.get("tool_calls"), data
print("tool result response:", content.strip().replace("\n", " ")[:200])
PY

cat >"$tmp/tool-choice-none-request.json" <<'JSON'
{
  "model": "deepseek-v4-flash",
  "messages": [
    {
      "role": "user",
      "content": "Use get_weather for Shanghai if tools are available; otherwise say NO_TOOL."
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a city.",
        "parameters": {
          "type": "object",
          "properties": {
            "city": { "type": "string" }
          },
          "required": ["city"]
        }
      }
    }
  ],
  "tool_choice": "none",
  "max_tokens": 64,
  "temperature": 0,
  "reasoning_effort": "none",
  "stream": false
}
JSON

curl -fsS "$base/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d @"$tmp/tool-choice-none-request.json" \
    >"$tmp/tool-choice-none.json"

python3 - "$tmp/tool-choice-none.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
message = ((data.get("choices") or [{}])[0].get("message")) or {}
assert not message.get("tool_calls"), data
observed = (message.get("content") or "") + (message.get("reasoning_content") or "")
assert observed.strip(), data
print("tool_choice none response observed")
PY

printf 'PASS: OpenAI tools, tool result replay, and tool_choice none\n'
