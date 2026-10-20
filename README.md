# Listener

A macOS app that transcribes both sides of a call live (your mic as "Me", system
audio as "Them") and, when you press a hotkey, streams a suggested answer from Claude
into an always-on-top window. After the call it writes a summary and action items.

Status: **M0, plan and audio spike.** The plan, architecture and the decisions behind
them are in [docs/PLAN.md](docs/PLAN.md).

## Requirements

- Apple Silicon Mac on macOS 15 (Sequoia) or later.
- Swift 6: Xcode 16 or later, or just the Command Line Tools (`xcode-select --install`).
  Check with `swift --version`.
- A microphone that works with the lid closed. In clamshell mode the MacBook's built-in
  mics are off, so use a headset, USB mic or webcam mic.
- Headphones on calls. On speakers the mic also hears the other side, so "Me" would
  transcribe them too. The spike measures this for your setup.

## M0: run the audio spike

```sh
scripts/spike.sh                     # system audio via a Core Audio process tap (recommended)
scripts/spike.sh --system sck        # system audio via ScreenCaptureKit, for comparison
scripts/spike.sh --voice-processing  # add Apple's echo cancellation to the mic
```

The script builds and signs `build/Listener.app`, launches it, and shows its log. After a
3 second countdown it walks you through three 10 second phases:

1. **Voice only**: talk, with nothing playing on the Mac.
2. **System audio only**: stay quiet and play something with speech (a YouTube video, or
   a Google Meet test call at meet.google.com > "Check your audio and video").
3. **Both**: keep it playing and talk over it.

It prints a level meter per channel every second, then a report with PASS/FAIL checks:
both channels deliver a continuous 16 kHz stream, each is active when it should be and
quiet when it should be, plus timing, gaps and CPU use. Everything lands in
`~/Library/Application Support/Listener/spike/<timestamp>/`:

| File | Contents |
| --- | --- |
| `me.wav`, `them.wav` | The two channels exactly as speech-to-text will receive them |
| `report.json` | Every measurement and verdict |
| `spike.log` | What you saw in the terminal |

Listen to the two WAV files: `me.wav` should hold only your voice, `them.wav` only the
Mac's audio. Please send me the report text for one `tap` run and one `sck` run.

Use `--phase-seconds 15` for longer phases and `--help` for all options.

## macOS permissions

| Permission | Used for | Where to change it |
| --- | --- | --- |
| Microphone | "Me" channel | System Settings > Privacy & Security > Microphone |
| System Audio Recording | "Them" channel, tap backend | System Settings > Privacy & Security > Screen & System Audio Recording, "System Audio Recording Only" list |
| Screen Recording | "Them" channel, only with `--system sck` | Same pane, "Screen & System Audio Recording" list |

macOS asks the first time each one is used. Allow it, then run the spike again: a
channel that ran without permission records silence, and the report says so.

**Accessibility is not needed.** The hotkeys (M3) use `RegisterEventHotKey`, which macOS
allows without Accessibility or Input Monitoring access.

### Keep permissions across rebuilds

macOS ties these permissions to the app's code signature. `scripts/build-app.sh` signs
ad hoc by default, and an ad hoc signature changes with every build, so macOS asks
again after each rebuild. To avoid that, create a stable signing identity once:

1. Open Keychain Access > Keychain Access menu > Certificate Assistant > Create a Certificate.
2. Name it `Listener Dev`, Identity Type "Self Signed Root", Certificate Type "Code Signing".
3. Add `export LISTENER_SIGNING_IDENTITY="Listener Dev"` to your shell profile.

### Why the script launches the app with `open`

macOS asks for permission on behalf of the app that is "responsible" for a process.
Running `swift run listener spike` from Terminal works, but the permissions are then
granted to Terminal (or iTerm) rather than to Listener. `scripts/spike.sh` launches
`Listener.app` through LaunchServices so Listener owns its permissions.

## Development

```sh
swift build                 # build everything
swift test                  # run the tests (the core module also builds and tests on Linux)
swift format lint --strict --recursive Sources Tests Package.swift
swift format --in-place --recursive Sources Tests Package.swift
```

Layout:

```
Sources/ListenerCore   platform independent logic (Foundation only), unit tested
Sources/ListenerMac    macOS capture: AVAudioEngine mic, Core Audio tap, ScreenCaptureKit
Sources/ListenerApp    the `listener` executable and its subcommands
Tests/                 swift-testing tests for ListenerCore
App/Info.plist         bundle metadata and permission prompts
scripts/               build-app.sh, spike.sh
docs/PLAN.md           architecture, decisions, milestones
```

### CI

`ci/github-actions.yml` lints and tests on Linux and builds, tests and bundles the app
on a macOS runner. GitHub only accepts workflow files from tokens with the `workflow`
scope, which this repository's automation token lacks, so enable it from your machine:

```sh
mkdir -p .github/workflows && git mv ci/github-actions.yml .github/workflows/ci.yml
git commit -m "Enable CI" && git push
```

macOS runner minutes count ten times against a private repository's Actions quota.
