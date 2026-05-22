#!/usr/bin/env bash
# Downloads the SQLite amalgamation into core/third_party/sqlite3/
# so Android NDK and iOS builds can link a bundled SQLite.
#
# Usage: ./scripts/fetch_sqlite.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/core/third_party/sqlite3"
VERSION="3460000"   # SQLite 3.46.0

if [[ -f "$DEST/sqlite3.c" ]]; then
    echo "[fetch_sqlite] already present at $DEST"
    exit 0
fi

mkdir -p "$DEST"
TMP=$(mktemp -d)
URL="https://www.sqlite.org/2024/sqlite-amalgamation-${VERSION}.zip"

echo "[fetch_sqlite] downloading $URL"
curl -fsSL "$URL" -o "$TMP/sqlite.zip"
( cd "$TMP" && unzip -q sqlite.zip )
SUB=$(find "$TMP" -maxdepth 1 -type d -name "sqlite-amalgamation-*")
cp "$SUB/sqlite3.c" "$SUB/sqlite3.h" "$DEST/"
rm -rf "$TMP"
echo "[fetch_sqlite] installed in $DEST"
