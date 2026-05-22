#!/usr/bin/env bash
# Master release pipeline.
#
# Usage: ./scripts/release.sh [version]

set -euo pipefail

VERSION=${1:-1.0.0}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "═══════════════════════════════════════"
echo "  Releasing UniTrack v$VERSION"
echo "═══════════════════════════════════════"

# 1. Core: ensure SQLite present
"$ROOT/scripts/fetch_sqlite.sh"

# 2. Core: build + test (host)
mkdir -p "$ROOT/build/host"
( cd "$ROOT/build/host" && \
  cmake "$ROOT/core" -DUT_BUILD_TESTS=ON -DUT_USE_BUNDLED_SQLITE=ON && \
  cmake --build . -j && \
  ./tests/unitrack_tests )

# 3. Per-platform packaging — skip silently if toolchain absent.
if command -v xcodebuild >/dev/null 2>&1; then
    "$ROOT/scripts/build_ios.sh"
else
    echo "[release] xcodebuild not found — skipping iOS"
fi

if [[ -x "$ROOT/platforms/android/gradlew" ]] || command -v gradle >/dev/null 2>&1; then
    "$ROOT/scripts/build_android.sh"
else
    echo "[release] gradle not found — skipping Android"
fi

if command -v npm >/dev/null 2>&1; then
    "$ROOT/scripts/build_rn.sh"
else
    echo "[release] npm not found — skipping React Native"
fi

if command -v flutter >/dev/null 2>&1; then
    "$ROOT/scripts/build_flutter.sh"
else
    echo "[release] flutter not found — skipping Flutter"
fi

echo
echo "═══════════════════════════════════════"
echo "  Artifacts:"
ls -lh "$ROOT/dist/" 2>/dev/null || echo "  (dist/ empty — nothing built)"
echo "═══════════════════════════════════════"
