#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

url='https://huggingface.co/antirez/deepseek-v4-gguf/resolve/main/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf'
mkdir -p "$(dirname "$MODEL_PATH")"

if [ -f "$MODEL_PATH" ]; then
    actual_size=$(wc -c <"$MODEL_PATH" | tr -d ' ')
    if [ "$actual_size" = "$MODEL_SIZE" ]; then
        "$ROOT/bin/verify-model.sh"
        exit 0
    fi
    if [ "$actual_size" -gt "$MODEL_SIZE" ]; then
        printf 'existing model is larger than expected; remove it before retrying: %s\n' \
            "$MODEL_PATH" >&2
        exit 1
    fi
fi

curl -L --fail --retry 20 --retry-delay 5 -C - \
    --output "$MODEL_PATH" "$url"

"$ROOT/bin/verify-model.sh"
