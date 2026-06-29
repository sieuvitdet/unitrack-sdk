#!/usr/bin/env bash
# Refreshes the vendored copy of the shared C/C++ core inside this iOS package.
#
# Layout (kept in sync with monorepo `core/`):
#   Sources/UniTrackCore/src/             ← real .cpp/.h files (committed)
#   Sources/UniTrackCore/include/unitrack/unitrack.h
#
# Why vendored — both SwiftPM and CocoaPods build from physical files inside the
# package/pod root. SPM refuses symlinks that escape the package; `pod lib lint`
# runs in a sandbox where `../../core` does not exist. So we COMMIT real copies
# and resync from the monorepo whenever the C core changes. Run this script
# BEFORE you commit a core change — never as a `prepare_command` at install time
# (lint would fail in clean checkouts).
#
# Usage: bash platforms/ios/sync_core.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"   # platforms/ios
CORE="$HERE/../../core"
DEST="$HERE/Sources/UniTrackCore"

if [ ! -d "$CORE/src" ] || [ ! -d "$CORE/include/unitrack" ]; then
  echo "[sync_core] ERROR: cannot find monorepo core/ at $CORE" >&2
  echo "[sync_core] this script is for monorepo developers only — distributed" >&2
  echo "[sync_core] packages already ship the vendored copy in Sources/UniTrackCore/." >&2
  exit 1
fi

rm -rf "$DEST/src" "$DEST/include/unitrack"
mkdir -p "$DEST/include/unitrack"
cp -R "$CORE/src/." "$DEST/src/"
cp -R "$CORE/include/unitrack/." "$DEST/include/unitrack/"
echo "[sync_core] refreshed $DEST/{src, include/unitrack} from $CORE"
