#!/usr/bin/env bash
# Builds Android AAR with bundled native libs for all 4 ABIs.
#
# Usage: ./scripts/build_android.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/fetch_sqlite.sh"

cd "$ROOT/platforms/android"
./gradlew :unitrack:assembleRelease

AAR=$(find "$ROOT/platforms/android/unitrack/build/outputs/aar" -name '*.aar' | head -1)
mkdir -p "$ROOT/dist"
cp "$AAR" "$ROOT/dist/unitrack.aar"

echo "[build_android] wrote $ROOT/dist/unitrack.aar"
