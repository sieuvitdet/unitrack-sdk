#!/bin/bash
# Sync native source code into the Flutter pod so it ships with `flutter pub
# publish`. Run after editing iOS Swift / Android Kotlin / C++ core. The
# vendored copies live at:
#   ios/Native/      — iOS Swift SDK + C++ core (used by ios/sync_native.sh)
#   ios/Classes/include/unitrack.h — C public header
#   android/unitrack_sdk/src/ — Android SDK source (Kotlin + JNI/C++)
#
# After this script runs, commit the diff. `flutter pub publish` filters by
# `git ls-files`, so untracked files DO NOT make it into the published archive.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

echo "[sync] iOS Native/ + Classes/include/unitrack.h"
bash "$SCRIPT_DIR/ios/sync_native.sh"

echo "[sync] Android unitrack_sdk/src/"
rm -rf "$SCRIPT_DIR/android/unitrack_sdk/src"
cp -R "$ROOT/platforms/android/unitrack/src" "$SCRIPT_DIR/android/unitrack_sdk/"

echo "[sync] Done. Verify:"
echo "  - ios/Native/swift/UniTrack.swift            $(test -f "$SCRIPT_DIR/ios/Native/swift/UniTrack.swift" && echo OK || echo MISSING)"
echo "  - ios/Native/core/include/unitrack/unitrack.h $(test -f "$SCRIPT_DIR/ios/Native/core/include/unitrack/unitrack.h" && echo OK || echo MISSING)"
echo "  - ios/Classes/include/unitrack.h              $(test -f "$SCRIPT_DIR/ios/Classes/include/unitrack.h" && echo OK || echo MISSING)"
echo "  - android/unitrack_sdk/src/main/cpp/jni_bridge.cpp $(test -f "$SCRIPT_DIR/android/unitrack_sdk/src/main/cpp/jni_bridge.cpp" && echo OK || echo MISSING)"
echo "  - android/unitrack_sdk/src/main/java          $(test -d "$SCRIPT_DIR/android/unitrack_sdk/src/main/java" && echo OK || echo MISSING)"

echo ""
echo "Now: git add . && git commit -m 'sync native flutter pod' && flutter pub publish"
