#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for file in README.md LICENSE .gitignore config.env bin/setup.sh; do
    [ -f "$ROOT/$file" ] || fail "$file is missing"
done

[ -x "$ROOT/bin/setup.sh" ] || fail "bin/setup.sh is not executable"
grep -q 'config.local.env' "$ROOT/config.env" ||
    fail "config.local.env overrides are not loaded"
grep -q 'remaining_bytes' "$ROOT/bin/setup.sh" ||
    fail "setup does not account for remaining model download bytes"

mkdir -p "$ROOT/.test-public-config"
trap 'rm -rf "$ROOT/.test-public-config"' EXIT
cat >"$ROOT/.test-public-config/config.local.env" <<'EOF'
DS4_DIR=/tmp/public-ds4-override
EOF
(
    ROOT="$ROOT/.test-public-config"
    . "$ROOT/../config.env"
    [ "$DS4_SERVER" = "/tmp/public-ds4-override/ds4-server" ]
) || fail "DS4_DIR local override does not update derived binary paths"

for pattern in '*.gguf' 'run/' 'acceptance/' 'docs/plans/' 'config.local.env'; do
    git -C "$ROOT" check-ignore -q "$pattern" ||
        fail ".gitignore does not cover $pattern"
done

tracked=$(git -C "$ROOT" ls-files)
[ -n "$tracked" ] || fail "repository has no tracked files"

printf '%s\n' "$tracked" | grep -Eq '(^|/)(run|acceptance)(/|$)' &&
    fail "runtime or acceptance artifacts are tracked"
printf '%s\n' "$tracked" | grep -Eq '\.(gguf|safetensors)$' &&
    fail "model weights are tracked"

git -C "$ROOT" grep -n -i -E \
    '(/Users/|/Volumes/|gho_[A-Za-z0-9]+|github_pat_|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' \
    -- . ':!tests/test-public-repo.sh' &&
    fail "tracked files contain local paths or credentials"

emails=$(git -C "$ROOT" grep -I -h -o -E \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    -- . ':!tests/test-public-repo.sh' || true)
[ -z "$emails" ] || fail "tracked files contain an email address"

while IFS= read -r path; do
    [ -n "$path" ] || continue
    size=$(wc -c <"$ROOT/$path" | tr -d ' ')
    [ "$size" -le 1048576 ] || fail "tracked file exceeds 1 MiB: $path"
done <<EOF
$tracked
EOF

if [ -n "${EXPECTED_COMMIT_EMAIL:-}" ]; then
    [ "$(git -C "$ROOT" config user.email)" = "$EXPECTED_COMMIT_EMAIL" ] ||
        fail "repository email does not match EXPECTED_COMMIT_EMAIL"
fi

printf 'PASS: public repository boundary\n'
