#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/config.env"

[ -f "$MODEL_PATH" ] || {
    printf 'model is missing: %s\n' "$MODEL_PATH" >&2
    exit 1
}

actual_size=$(wc -c <"$MODEL_PATH" | tr -d ' ')
[ "$actual_size" = "$MODEL_SIZE" ] || {
    printf 'model size mismatch: expected %s, got %s\n' "$MODEL_SIZE" "$actual_size" >&2
    exit 1
}

model_mtime=$(stat -f '%m' "$MODEL_PATH")
stamp_value="$MODEL_PATH|$actual_size|$model_mtime|$MODEL_SHA256"
if [ -f "$VERIFIED_STAMP" ] &&
    [ "$(cat "$VERIFIED_STAMP")" = "$stamp_value" ]; then
    printf 'model verification stamp valid: %s\n' "$MODEL_PATH"
    exit 0
fi

actual_sha=$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')
[ "$actual_sha" = "$MODEL_SHA256" ] || {
    printf 'model checksum mismatch: expected %s, got %s\n' "$MODEL_SHA256" "$actual_sha" >&2
    exit 1
}

mkdir -p "$(dirname "$VERIFIED_STAMP")"
printf '%s\n' "$stamp_value" >"$VERIFIED_STAMP.tmp"
mv "$VERIFIED_STAMP.tmp" "$VERIFIED_STAMP"
printf 'model verified: %s\n' "$MODEL_PATH"
