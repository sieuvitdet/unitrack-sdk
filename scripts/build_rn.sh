#!/usr/bin/env bash
# Packages the React Native module for npm.
#
# Usage: ./scripts/build_rn.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/platforms/react-native"

npm install
npm run build

mkdir -p "$ROOT/dist"
npm pack --pack-destination "$ROOT/dist"

echo "[build_rn] wrote $ROOT/dist/unitrack-react-native-*.tgz"
