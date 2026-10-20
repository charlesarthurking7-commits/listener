#!/bin/bash
# Builds build/Listener.app around the SwiftPM binary.
#
# macOS ties Microphone and System Audio Recording permissions to the app's code
# signature. An ad-hoc signature changes on every build, so macOS asks again after
# each rebuild. A certificate named "Listener Dev" in the keychain (see README) is
# used automatically to keep permissions across builds; LISTENER_SIGNING_IDENTITY
# picks another.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
identity="${LISTENER_SIGNING_IDENTITY:-}"
if [ -z "$identity" ] && security find-identity -p codesigning 2>/dev/null | grep '"Listener Dev"' >/dev/null; then
    identity="Listener Dev"
fi
identity="${identity:--}"
app="build/Listener.app"

swift build --configuration "$configuration" --product listener
binary="$(swift build --configuration "$configuration" --show-bin-path)/listener"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/listener"
cp App/Info.plist "$app/Contents/Info.plist"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "$identity" "$app"

echo "Built $app (signed with ${identity/#-/ad-hoc identity})"
