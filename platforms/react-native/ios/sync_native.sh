#!/usr/bin/env bash
# Copies the native iOS Swift SDK + C++ core into this RN package's Native/
# directory so the podspec can vendor them (same pattern the Flutter plugin
# uses). Run this whenever the native SDK source changes.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"             # platforms/react-native/ios
SDK_SWIFT="$HERE/../../ios/Sources/UniTrack"      # native iOS Swift SDK
CORE="$HERE/../../../core"                         # C++ core

rm -rf "$HERE/Native"
mkdir -p "$HERE/Native/swift" "$HERE/Native/core"
cp -R "$SDK_SWIFT/." "$HERE/Native/swift/"
cp -R "$CORE/src"     "$HERE/Native/core/src"
cp -R "$CORE/include" "$HERE/Native/core/include"

# C public header — exposed via the umbrella so the Swift code can see the
# ut_* C ABI.
mkdir -p "$HERE/include"
cp "$HERE/../../ios/Sources/UniTrackCore/include/unitrack.h" "$HERE/include/unitrack.h"

echo "[sync_native] copied native SDK + core into $HERE/Native"
echo "[sync_native] If you ADDED or RENAMED a file, re-run 'pod install' in"
echo "[sync_native] the consuming app's ios/ dir — Pods.xcodeproj caches the"
echo "[sync_native] file list."
