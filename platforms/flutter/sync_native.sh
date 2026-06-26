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

# Vendor C++ core sources INTO the plugin so consumer apps that build via
# `dependency_overrides: path:` or `flutter pub publish` cache see a
# self-contained CMakeLists. Without this the old UT_CORE_ROOT="../../../core"
# path only worked when building from THE monorepo direct — every other
# consumer hit "sqlite3.c not found" at CMake configure time.
ANDROID_CPP="$SCRIPT_DIR/android/unitrack_sdk/src/main/cpp"
echo "[sync] Android cpp/core/ (vendored core + sqlite3)"
rm -rf "$ANDROID_CPP/core"
mkdir -p "$ANDROID_CPP/core/src" \
         "$ANDROID_CPP/core/include/unitrack" \
         "$ANDROID_CPP/core/third_party/sqlite3"
cp "$ROOT/core/src/"*.cpp "$ANDROID_CPP/core/src/"
cp "$ROOT/core/src/"*.h "$ANDROID_CPP/core/src/"
cp "$ROOT/core/include/unitrack/unitrack.h" "$ANDROID_CPP/core/include/unitrack/"
cp "$ROOT/core/third_party/sqlite3/sqlite3.c" "$ANDROID_CPP/core/third_party/sqlite3/"
cp "$ROOT/core/third_party/sqlite3/sqlite3.h" "$ANDROID_CPP/core/third_party/sqlite3/"

echo "[sync] Done. Verify:"
echo "  - ios/Native/swift/UniTrack.swift            $(test -f "$SCRIPT_DIR/ios/Native/swift/UniTrack.swift" && echo OK || echo MISSING)"
echo "  - ios/Native/core/include/unitrack/unitrack.h $(test -f "$SCRIPT_DIR/ios/Native/core/include/unitrack/unitrack.h" && echo OK || echo MISSING)"
echo "  - ios/Classes/include/unitrack.h              $(test -f "$SCRIPT_DIR/ios/Classes/include/unitrack.h" && echo OK || echo MISSING)"
echo "  - android/unitrack_sdk/src/main/cpp/jni_bridge.cpp $(test -f "$SCRIPT_DIR/android/unitrack_sdk/src/main/cpp/jni_bridge.cpp" && echo OK || echo MISSING)"
echo "  - android/unitrack_sdk/src/main/java          $(test -d "$SCRIPT_DIR/android/unitrack_sdk/src/main/java" && echo OK || echo MISSING)"

echo ""
echo "Now: git add . && git commit -m 'sync native flutter pod' && flutter pub publish"
