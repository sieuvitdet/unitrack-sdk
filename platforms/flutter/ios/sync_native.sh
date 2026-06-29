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

# Atomic-swap: build into Native.new, then rm+mv. Any interrupt (Ctrl-C, power
# loss, build agent killed) leaves the existing Native/ intact. Without this,
# an interrupted run between `rm -rf Native` and `cp -R` shipped a partial
# tree to pub.dev (the publish archive walks `git ls-files`, but the local
# working tree being torn down silently corrupted future commits if anyone
# ran `git add` on the half-tree).
STAGE="$HERE/Native.new"
rm -rf "$STAGE"
mkdir -p "$STAGE/swift" "$STAGE/core"
cp -R "$SDK_SWIFT/." "$STAGE/swift/"
cp -R "$CORE/src"     "$STAGE/core/src"
cp -R "$CORE/include" "$STAGE/core/include"
rm -rf "$HERE/Native"
mv "$STAGE" "$HERE/Native"

# Keep the C public header (used for the umbrella) in sync too. Stage to a
# sibling temp file then mv — single-syscall replace so a partial header
# never lands in the pod's umbrella dir.
mkdir -p "$HERE/Classes/include"
HDR_SRC="$HERE/../../ios/Sources/UniTrackCore/include/unitrack.h"
HDR_DST="$HERE/Classes/include/unitrack.h"
cp "$HDR_SRC" "$HDR_DST.new"
mv "$HDR_DST.new" "$HDR_DST"

echo "[sync_native] copied native SDK + core into $HERE/Native"
echo "[sync_native] If you ADDED or RENAMED a file, also run 'pod install' in"
echo "[sync_native] the consuming app's ios/ dir — Pods.xcodeproj caches the"
echo "[sync_native] file list and won't pick up new files until then."
