#!/usr/bin/env bash
# Copies the native iOS Swift SDK and the C++ core into this pod's Native/ dir.
#
# CocoaPods only includes source files that physically live inside the pod
# directory (it does not glob through `..` paths or symlinks), so the shared
# native sources must be copied in. Run this whenever the SDK source changes.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"           # platforms/flutter/ios
SDK_SWIFT="$HERE/../../ios/Sources/UniTrack"     # native iOS Swift SDK
CORE="$HERE/../../../core"                        # C++ core

rm -rf "$HERE/Native"
mkdir -p "$HERE/Native/swift" "$HERE/Native/core"
cp -R "$SDK_SWIFT/." "$HERE/Native/swift/"
cp -R "$CORE/src"     "$HERE/Native/core/src"
cp -R "$CORE/include" "$HERE/Native/core/include"

# Keep the C public header (used for the umbrella) in sync too.
mkdir -p "$HERE/Classes/include"
cp "$HERE/../../ios/Sources/UniTrackCore/include/unitrack.h" "$HERE/Classes/include/unitrack.h"

echo "[sync_native] copied native SDK + core into $HERE/Native"
