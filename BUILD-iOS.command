#!/bin/bash
# Double-click to compile-check the STRDM Live iPhone/iPad app (iOS Simulator). Output: build-ios.log
cd "$(dirname "$0")/iOS/STRDMLive.swiftpm"
{
  echo "=== $(date) ==="
  xcodebuild -scheme "STRDM Live Control" -destination 'generic/platform=iOS Simulator' -derivedDataPath ../.derived build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)|\*\*" | head -80
  echo "EXIT CODE: ${PIPESTATUS[0]}"
} > ../../build-ios.log 2>&1
exit 0
