#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
.venv/bin/python -m pytest -q
swift test
if [ -n "${MACCOMMAND_SIMULATOR_ID:-}" ]; then
  xcodebuild -project ios/MacCommand.xcodeproj -scheme MacCommand \
    -destination "platform=iOS Simulator,id=$MACCOMMAND_SIMULATOR_ID" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
fi
