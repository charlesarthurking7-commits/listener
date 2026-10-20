# Listener

A macOS app that sits beside your calls. It transcribes both sides live, your mic as
"Me" and the Mac's audio as "Them", in a floating window that never takes focus from
Meet or Teams. Press a hotkey and it streams a suggested answer from Claude. When the
call ends it writes a summary with action items.

- **Quick answer** (Control-Option-Space): Claude Haiku 5.5, short and speakable, first
  words in well under a second.
- **Deep answer** (Control-Option-Shift-Space): Claude Sonnet 5.5 for harder questions.
- **Grounded**: answers may use general knowledge but never invent call-specific facts
  (amounts, account or ticket numbers, dates, names); they say what to check instead.
- **Speech-to-text**: Apple's on-device recognition (macOS 26 and later, free) or Google
  Cloud Speech-to-Text v2 in the EU (about $1.92 per call-hour for both channels).
- **Visible**: a pulsing red indicator in the window and a red menu bar icon while
  listening. Nothing is recorded until you press Start.
- **Measured**: every answer logs end-of-speech, hotkey, first-token and done times; the
  running cost is in the window and saved with each call.
- **Local**: calls are saved under `~/Library/Application Support/Listener/sessions`
  with 30-day retention. Raw audio is not kept unless you turn it on.

**Status:** all features are built and the macOS code type-checks against the macOS 15.5
and 26.5 SDKs, but it was developed without a Mac, so the first build and run on yours
is the first real test. Start with the audio spike below.

## Requirements

- Apple Silicon Mac, macOS 15 or later (macOS 26 or later for on-device speech).
- Xcode 16.3 or later, or its Command Line Tools (`xcode-select --install`). Xcode 26 is
  needed to build the on-device speech provider.
- A microphone that works with the lid closed (the built-in mics are off in clamshell
  mode), and headphones on calls so the mic does not hear the other side.
- An Anthropic API key for answers and summaries.
- For Google speech-to-text only: a GCP project with the Speech-to-Text API enabled and
  `gcloud auth application-default login`.

## Quick start

```sh
scripts/spike.sh                          # 1. check both audio channels on this Mac (30 s, guided)
scripts/run.sh                            # 2. build and open the app
build/Listener.app/Contents/MacOS/listener secrets set anthropic   # 3. store your API key
```

Then choose **Open Settings File** from the menu bar icon and set the speech provider:

```json
{ "speech": { "provider": "apple" } }
```

or, for Google, `{ "speech": { "provider": "google", "googleProjectID": "your-project" } }`.
Add a line about yourself to `answers.context` so answers fit your role
(see [`settings.example.json`](settings.example.json)). Press **Start** in the window.

Try it without a call by replaying a fixture through the full pipeline:

```sh
listener replay Fixtures/delayed-executions/me.wav Fixtures/delayed-executions/them.wav \
    --script Fixtures/delayed-executions/script.json --ask-at 0:30,0:39
```

[docs/USAGE.md](docs/USAGE.md) covers everything: the window, hotkeys, terminal mode,
replay, settings, environment variables, API keys, where files go and troubleshooting.
[docs/PLAN.md](docs/PLAN.md) explains the architecture and the decisions behind it.

## The audio spike

`scripts/spike.sh` builds the app, launches it and walks you through three 10 second
phases: talk with nothing playing, stay quiet while something plays, then both. It
reports PASS/FAIL checks for each channel (continuous 16 kHz stream, active when it
should be, quiet when it should be), timing, gaps and CPU, and writes `me.wav`,
`them.wav` and `report.json` to `~/Library/Application Support/Listener/spike/`.

```sh
scripts/spike.sh --system sck           # compare with the ScreenCaptureKit backend
scripts/spike.sh --voice-processing     # echo cancellation, if you are on speakers
```

## macOS permissions

| Permission | Used for | Where to change it |
| --- | --- | --- |
| Microphone | "Me" | System Settings > Privacy & Security > Microphone |
| System Audio Recording | "Them" (default Core Audio tap) | Privacy & Security > Screen & System Audio Recording, "System Audio Recording Only" |
| Screen Recording | "Them", only with the `sck` backend | Same pane, "Screen & System Audio Recording" |

macOS asks the first time each is used. A channel without permission records silence
rather than failing, and the window warns you. **Accessibility is not needed**: the
hotkeys use `RegisterEventHotKey`, which macOS allows without it.

macOS ties permissions to the app's code signature. `scripts/build-app.sh` signs ad hoc,
which changes with every build, so macOS asks again after rebuilds. To keep permissions,
create a stable identity once: Keychain Access > Certificate Assistant > Create a
Certificate, name `Listener Dev`, "Self Signed Root", "Code Signing"; then
`export LISTENER_SIGNING_IDENTITY="Listener Dev"`.

The scripts launch the app through `open` so that macOS asks on behalf of Listener. A
command run straight from Terminal gets its permissions through your terminal app.

## Development

```sh
swift build                 # everything (the macOS targets build only on macOS)
swift test                  # ListenerCore, GoogleSpeech and ClaudeAPI tests, also on Linux
swift format lint --strict --recursive Sources Tests Package.swift
swift format --in-place --recursive Sources Tests Package.swift
scripts/generate-protos.sh  # regenerate the Speech-to-Text gRPC client
```

```
Sources/ListenerCore   platform independent: audio framing, VAD, resampling, turn detection,
                       the call session, prompts, cost, settings, storage, replay, fakes
Sources/GoogleSpeech   Speech-to-Text v2 streaming over gRPC, Google credentials
Sources/ClaudeAPI      Anthropic Messages API client with streaming
Sources/ListenerMac    capture (Core Audio tap, AVAudioEngine, ScreenCaptureKit), on-device
                       speech, hotkeys, Keychain, the floating window and menu bar item
Sources/ListenerApp    the `listener` executable: the app and its subcommands
Tests/                 swift-testing suites, including end-to-end runs on the fixtures
Fixtures/              three mock broker calls (two channels plus script) for replay;
                       see Fixtures/README.md to regenerate them
Protos/                trimmed Speech-to-Text v2 proto the gRPC client is generated from
App/Info.plist         bundle metadata and permission prompts
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
