#!/usr/bin/env bash
# Validates the Flutter plugin package.
#
# Usage: ./scripts/build_flutter.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/platforms/flutter"

flutter pub get
flutter analyze
flutter pub publish --dry-run

echo "[build_flutter] package ready in $ROOT/platforms/flutter"
