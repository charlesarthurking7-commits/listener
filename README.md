# Listener

A macOS app that sits beside your calls. It transcribes both sides live, your mic as
"Me" and the Mac's audio as "Them", in a floating window that never takes focus from
Meet or Teams. Press a hotkey and it streams a suggested answer from Claude. When the
call ends it writes a summary with action items.

- **Quick answer** (Control-Option-A): Claude Haiku 5.5, short and speakable, first
  words in well under a second.
- **Deep answer** (Control-Option-Shift-A): Claude Sonnet 5.5 for harder questions.
- **Recap so far** (Control-Option-S): what the call has covered, what is still open for
  you and what was agreed, from the whole call.
- **Call types**: pick Work call or Meeting before Start, and drop in files, paste a page
  or its link, or write a brief.
- **Dictation** (fn twice, in any app): speak, press fn again, and the words are typed
  at the cursor, tidied by Claude Sonnet 5.5: fillers gone, corrections applied, laid out
  for the email or chat they are going into, with lists pasted as real lists. Speech is
  recognised on the Mac by Parakeet Ultra, and names you correct are learned.
- **Grounded**: answers may use general knowledge but never invent call-specific facts
  (amounts, account or ticket numbers, dates, names); they say what to check instead.
- **Speech-to-text**: Apple's on-device recognition by default where the Mac supports it
  (macOS 26 and later, free, nothing leaves the Mac), otherwise Google Cloud
  Speech-to-Text v2 in the EU (about $1.92 per call-hour for both channels).
- **Visible**: a pulsing red indicator in the window and a filled menu bar icon while
  listening. Nothing is recorded until you press Start.
- **Measured**: every answer logs end-of-speech, hotkey, first-token and done times; the
  running cost is in the window and saved with each call.
- **Local**: calls are saved under `~/Library/Application Support/Listener/sessions`
  with 30-day retention. Raw audio is not kept unless you turn it on.
- **Main window** (Open Listener in the menu bar): past calls with their summary, ticked
  action items, transcript and answers, and search across everything said; call types,
  the dictation dictionary and every setting, edited in place.

## Requirements

- Apple Silicon Mac, macOS 15 or later (macOS 26 or later for on-device speech).
- Xcode 26 or later, or its Command Line Tools (`xcode-select --install`).
- A microphone that works with the lid closed (the built-in mics are off in clamshell
  mode), and headphones on calls so the mic does not hear the other side.
- An Anthropic API key for answers and summaries.
- For Google speech-to-text only: a GCP project with the Speech-to-Text API enabled and
  `gcloud auth application-default login`.

## Quick start

```sh
scripts/run.sh                            # 1. build and open the app
build/Listener.app/Contents/MacOS/listener secrets set anthropic   # 2. store your API key
```

On macOS 26 and later that is all: speech recognition runs on the Mac by default. On
older systems, or to use Google instead, choose **Open Settings File** from the menu bar
icon and set `{ "speech": { "provider": "google", "googleProjectID": "your-project" } }`.
Add a line about yourself to `answers.context` so answers fit your role
(see [`settings.example.json`](settings.example.json)). Press **Start** in the window.

Try the window without a call with `listener demo`, which plays a recorded call into it,
or replay a fixture through the full pipeline in the terminal:

```sh
listener replay Fixtures/delayed-executions/me.wav Fixtures/delayed-executions/them.wav \
    --script Fixtures/delayed-executions/script.json --ask-at 0:30,0:39
```

[docs/USAGE.md](docs/USAGE.md) covers everything: the window, hotkeys, terminal mode,
replay, settings, API keys, where files go and troubleshooting.
[docs/PLAN.md](docs/PLAN.md) explains the architecture and the decisions behind it.

## macOS permissions

[First run](docs/USAGE.md#first-run), step 4, lists the permissions macOS asks for and
where to change them.

macOS ties permissions to the app's code signature. `scripts/build-app.sh` signs ad hoc,
which changes with every build, so macOS asks again after rebuilds. To keep permissions,
give it a stable identity once. The build script picks it up from then on.

- **Apple Development certificate** (best, free with any Apple ID): in Xcode, Settings >
  Accounts, add your Apple ID, select its team, Manage Certificates, then + and Apple
  Development. Its Team ID also makes the Keychain's "Always Allow" for the API key
  last across rebuilds.
- **Self-signed**: Keychain Access > Certificate Assistant > Create a Certificate, name
  `Listener Dev`, "Self Signed Root", "Code Signing". Permissions last, but a
  certificate without a Team ID can't keep "Always Allow": macOS remembers it for that
  build only, so the Keychain asks again after every rebuild.

Changing from one identity to the other makes macOS ask for each permission once more.

The scripts launch the app through `open` so that macOS asks on behalf of Listener. A
command run straight from Terminal gets its permissions through your terminal app.

## Credits

Dictation recognises speech with [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra)
by moondream, a post-training of NVIDIA's
[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), both under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), run through
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0).

The window is set in [Geist and Geist Mono](https://github.com/vercel/geist-font) by
Vercel, under the [SIL Open Font License 1.1](App/Fonts/OFL.txt).

## Development

```sh
swift build                 # everything (the macOS targets build only on macOS)
swift test                  # ListenerCore, GoogleSpeech and ClaudeAPI tests, also on Linux
scripts/build-app.sh        # release app bundle
swift format lint --strict --recursive Sources Tests Package.swift Tools/SpeechBench/Sources Tools/SpeechBench/Package.swift
swift format --in-place --recursive Sources Tests Package.swift Tools/SpeechBench/Sources Tools/SpeechBench/Package.swift
scripts/generate-protos.sh  # regenerate the Speech-to-Text gRPC client
python3 scripts/make-icon.py # redraw the app icon (needs rsvg-convert: brew install librsvg)
```

Build release binaries with `scripts/build-app.sh` rather than `swift build -c release`.
It compiles the dependencies for the same macOS version as Listener; without that the
optimised app crashes in `Task.sleep` (see the comment in the script).

```
Sources/ListenerCore   platform independent: audio framing, VAD, turn detection,
                       the call session, prompts, call types, web pages, cost, settings,
                       storage, replay, fakes
Sources/GoogleSpeech   Speech-to-Text v2 streaming over gRPC, Google credentials
Sources/ClaudeAPI      Anthropic Messages API client with streaming
Sources/ListenerMac    capture (Core Audio tap, AVAudioEngine, ScreenCaptureKit), on-device
                       speech, reading PDF and Word files, hotkeys, Keychain, the floating
                       window and menu bar item
Sources/ListenerApp    the `listener` executable: the app and its subcommands
Tests/                 swift-testing suites, including end-to-end runs on the fixtures
Fixtures/              three mock broker calls (two channels plus script) for replay;
                       see Fixtures/README.md to regenerate them
Protos/                trimmed Speech-to-Text v2 proto the gRPC client is generated from
App/                   Info.plist (bundle metadata, permission prompts) and the app icon,
                       which scripts/make-icon.py draws
```

### CI

`.github/workflows/ci.yml` lints and runs the tests on Linux for every push, and on a
macOS runner builds and tests the package, bundles the app and replays a fixture call
through it. macOS runner minutes count ten times against a private repository's Actions
quota, so that job runs for pushes to `main`, pull requests, and by hand from the
Actions tab (Run workflow).
