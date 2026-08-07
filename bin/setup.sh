#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

: "${DS4_REPOSITORY:=https://github.com/antirez/ds4.git}"
: "${DS4_REF:=b0309611041655f4e45671cfd9c9886aff161406}"
: "${MIN_FREE_GIB:=8}"

for command in cc make git curl shasum plutil python3; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command" >&2
        exit 1
    }
done

[ "$(uname -s)" = Darwin ] || {
    printf 'this deployment targets macOS with Apple Metal\n' >&2
    exit 1
}

mkdir -p "$(dirname "$MODEL_PATH")"
existing_bytes=0
if [ -f "$MODEL_PATH" ]; then
    existing_bytes=$(wc -c <"$MODEL_PATH" | tr -d ' ')
    [ "$existing_bytes" -le "$MODEL_SIZE" ] || {
        printf 'existing model is larger than expected: %s\n' "$MODEL_PATH" >&2
        exit 1
    }
fi
remaining_bytes=$((MODEL_SIZE - existing_bytes))
free_kib=$(df -Pk "$(dirname "$MODEL_PATH")" | awk 'NR == 2 { print $4 }')
required_kib=$(( (remaining_bytes + 1023) / 1024 + MIN_FREE_GIB * 1024 * 1024 ))
[ "${free_kib:-0}" -ge "$required_kib" ] || {
    printf 'insufficient disk space: %.1f GiB remains to download plus %s GiB safety headroom\n' \
        "$(awk -v bytes="$remaining_bytes" 'BEGIN { printf "%.1f", bytes / 1073741824 }')" \
        "$MIN_FREE_GIB" >&2
    exit 1
}

if [ ! -d "$DS4_DIR/.git" ]; then
    mkdir -p "$(dirname "$DS4_DIR")"
    git clone "$DS4_REPOSITORY" "$DS4_DIR"
fi

if [ -n "$(git -C "$DS4_DIR" status --short)" ]; then
    printf 'refusing to modify dirty ds4 checkout: %s\n' "$DS4_DIR" >&2
    exit 1
fi

git -C "$DS4_DIR" fetch origin "$DS4_REF"
git -C "$DS4_DIR" checkout --detach "$DS4_REF"
make -C "$DS4_DIR" -j"$(sysctl -n hw.ncpu)"

"$ROOT/bin/download-model.sh"
"$ROOT/bin/start.sh"
"$ROOT/bin/smoke-test.sh"

printf '\nDeepSeek V4 Flash is ready at http://%s:%s/v1\n' \
    "$SERVER_HOST" "$SERVER_PORT"
