#!/bin/zsh
# Unit tests run on the macOS destination: no simulator to boot, so they never contend
# for this machine's shared simulator lock. Extra args pass through to xcodebuild.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
xcodebuild test \
  -project Foon.xcodeproj \
  -scheme Foon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  "$@"
