#!/usr/bin/env bash
# Guard: the screen boundary defaults in the Swift/Kotlin binding layers must
# be BUSINESS names, never the Snowplow convention kind "screen_view".
#
# Why this exists: config load is async in every host (FPT Life iOS defers
# start() onto the main queue, or falls back to a 3s remote fetch). Any screen
# that fires before initialize() completes ships whatever the field default is.
# When that default was "screen_view", weeks of production events reached the
# collector with event_action="screen_view" — the iglu schema PARENT, which
# screen_viewed/screen_exited/screen_load_completed all share, so the data team
# could not tell entry from exit.
#
# ponytail: grep, not a test framework. There is no Swift/Kotlin test target in
# this repo (only tests/core_tests.cpp), and standing two up to assert two
# string literals costs more than it protects. Promote to a real unit test if
# the binding layer ever grows logic worth exercising.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

# Every binding copy of the screen-boundary defaults. Kept explicit so a new
# platform port that forgets the guard shows up as a missing-file error.
files=(
  platforms/ios/Sources/UniTrack/UniTrack.swift
  platforms/react-native/ios/Native/swift/UniTrack.swift
  platforms/flutter/ios/Native/swift/UniTrack.swift
  platforms/android/unitrack/src/main/java/com/unitrack/sdk/UniTrack.kt
  platforms/flutter/android/unitrack_sdk/src/main/java/com/unitrack/sdk/UniTrack.kt
)

for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL  missing: $f"; fail=1; continue
  fi

  # Any default/fallback that resolves to the schema kind is the bug.
  # Matches the three shapes: field initialiser, applyHotConfig empty-string
  # reset, and the initialize() nil/empty fallback -- Swift and Kotlin alike.
  if bad=$(grep -nE 'screen(Start|End)EventName[^=]*=.*"screen_view"' "$f"); then
    echo "FAIL  $f -- default resolves to schema kind \"screen_view\":"
    echo "$bad" | sed 's/^/        /'
    fail=1
  else
    echo "ok    $f"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "Screen defaults must be business names (screen_viewed / screen_exited)."
  echo "\"screen_view\" is the iglu schema kind and must never ship as event_action."
  exit 1
fi

echo
echo "PASS  screen event defaults are business names in all ${#files[@]} bindings"
