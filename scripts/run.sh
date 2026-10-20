#!/bin/bash
# Builds build/Listener.app and opens it: the menu bar app with its floating window.
# Arguments go to the app, for example: scripts/run.sh --settings ~/listener-test.json
#
# The app is opened through LaunchServices so macOS asks for Microphone and System
# Audio Recording on behalf of Listener rather than Terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

binary="build/Listener.app/Contents/MacOS/listener"
if pgrep -f "$PWD/$binary" >/dev/null; then
    echo "Listener is already running. Quit it from its menu bar icon (Quit Listener), which saves"
    echo "a call in progress, then run this again."
    exit 1
fi

scripts/build-app.sh

if [ "$#" -gt 0 ]; then
    open build/Listener.app --args "$@"
else
    open build/Listener.app
fi
echo "Listener is running: look for the waveform icon in the menu bar."
