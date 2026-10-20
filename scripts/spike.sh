#!/bin/bash
# Runs the M0 audio spike as a proper app so that macOS asks for permissions on
# behalf of Listener.app rather than Terminal. Extra arguments go to `listener spike`,
# for example: scripts/spike.sh --system sck --phase-seconds 15
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

output="$HOME/Library/Application Support/Listener/spike/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output"
log="$output/spike.log"
touch "$log"

tail -n +1 -f "$log" &
tail_pid=$!
trap 'kill "$tail_pid" 2>/dev/null || true' EXIT

open -W -n build/Listener.app --args spike --out "$output" "$@"
sleep 0.5

echo
echo "Recordings, report.json and spike.log are in: $output"
open "$output"
