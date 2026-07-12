#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'OK: %s\n' "$*"
}

required_files=(
    "VERSION"
    "CHANGELOG.md"
    "RELEASE_NOTES.md"
    "COMPATIBILITY.md"
    "CONTRIBUTING.md"
    "koreaderremote.koplugin/_meta.lua"
    "koreaderremote.koplugin/main.lua"
    "koreaderremote.koplugin/web/index.html"
)

for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || fail "Missing required file: $file"
    [[ -s "$file" ]] || fail "Required file is empty: $file"
done
ok "Required files exist"

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    || fail "VERSION is not valid SemVer: $VERSION"
ok "VERSION format: $VERSION"

CODE_VERSION="$(
    sed -n 's/^local VERSION = "\([^"]*\)".*/\1/p' \
        koreaderremote.koplugin/main.lua | head -n 1
)"
[[ -n "$CODE_VERSION" ]] || fail "Could not find local VERSION in main.lua"
[[ "$CODE_VERSION" == "$VERSION" ]] \
    || fail "VERSION mismatch: VERSION=$VERSION, main.lua=$CODE_VERSION"
ok "Version values match"

grep -Fq 'sorting_hint = "tools"' koreaderremote.koplugin/main.lua \
    || fail 'Missing sorting_hint = "tools"'
ok "Tools menu placement is present"

[[ ! -d "koreaderremote.koplugin/koreaderremote.koplugin" ]] \
    || fail "Nested plugin directory detected"

if find . -type f \( -name '.DS_Store' -o -name 'Thumbs.db' -o -name '.directory' \) \
    -print -quit | grep -q .; then
    fail "Operating-system metadata file found"
fi
ok "No unwanted metadata files"

if command -v luac5.1 >/dev/null 2>&1; then
    LUAC="luac5.1"
elif command -v luac >/dev/null 2>&1; then
    LUAC="luac"
else
    fail "Lua compiler not found. On Arch: sudo pacman -S lua51"
fi

while IFS= read -r -d '' file; do
    "$LUAC" -p "$file"
done < <(find koreaderremote.koplugin -type f -name '*.lua' -print0)
ok "Lua syntax"

while IFS= read -r -d '' file; do
    bash -n "$file"
done < <(find scripts -type f -name '*.sh' -print0)
ok "Shell syntax"

grep -Fq '/api/ping' koreaderremote.koplugin/main.lua \
    || fail "Missing /api/ping"
grep -Fq '/api/next' koreaderremote.koplugin/main.lua \
    || fail "Missing /api/next"
grep -Fq '/api/previous' koreaderremote.koplugin/main.lua \
    || fail "Missing /api/previous"
ok "Required API routes"

printf '\nAll checks passed for KOReader Remote v%s.\n' "$VERSION"
