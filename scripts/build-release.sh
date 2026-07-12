#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash scripts/check.sh

VERSION="$(tr -d '[:space:]' < VERSION)"
DIST="$ROOT/dist"
ARCHIVE="$DIST/koreaderremote-v${VERSION}.zip"
CHECKSUM="$ARCHIVE.sha256"

rm -rf "$DIST"
mkdir -p "$DIST"

zip -r -9 "$ARCHIVE" koreaderremote.koplugin \
    -x '*/.DS_Store' '*/Thumbs.db' '*/.directory' '*~'

unzip -t "$ARCHIVE" >/dev/null

TOP_LEVEL="$(
    unzip -Z1 "$ARCHIVE" |
        sed '/^$/d' |
        cut -d/ -f1 |
        sort -u
)"

[[ "$TOP_LEVEL" == "koreaderremote.koplugin" ]] || {
    printf 'ERROR: Unexpected top-level archive content:\n%s\n' "$TOP_LEVEL" >&2
    exit 1
}

(
    cd "$DIST"
    sha256sum "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
)

printf '\nCreated:\n'
printf '  %s\n' "$ARCHIVE"
printf '  %s\n' "$CHECKSUM"
