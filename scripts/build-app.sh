#!/bin/bash
# Builds build/Listener.app around the SwiftPM binary.
#
# macOS ties Microphone and System Audio Recording permissions to the app's code
# signature. An ad-hoc signature changes on every build, so macOS asks again after
# each rebuild. Set LISTENER_SIGNING_IDENTITY to a stable certificate (see README)
# to keep permissions across builds.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
identity="${LISTENER_SIGNING_IDENTITY:--}"
app="build/Listener.app"

swift build --configuration "$configuration" --product listener
binary="$(swift build --configuration "$configuration" --show-bin-path)/listener"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/listener"
cp App/Info.plist "$app/Contents/Info.plist"
codesign --force --sign "$identity" "$app"

echo "Built $app (signed with ${identity/#-/ad-hoc identity})"
