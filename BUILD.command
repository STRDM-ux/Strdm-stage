#!/bin/bash
# Double-click to build STRDM Stage. Output goes to build.log next to this file.
cd "$(dirname "$0")"
{
  echo "=== $(date) ==="
  sw_vers 2>&1
  xcode-select -p 2>&1
  swift --version 2>&1
  bash ./build.sh 2>&1
  echo "EXIT CODE: $?"
} > build.log 2>&1
if grep -q "EXIT CODE: 0" build.log; then open "dist/STRDM Stage.app"; fi
exit 0
