# Listener: plan and architecture

The decisions behind Listener and how it is put together.

## 1. Language: Swift

Recommendation: a single native Swift app. Not Rust, not Python plus a Swift helper.

"Fastest" is decided by the network, not the language. Per answer the time goes to the
speech-to-text final (hundreds of ms) and the LLM's first token (hundreds of ms).
Processing a 100 ms audio chunk takes microseconds in any compiled language. Swift and
Rust are equally fast here. What separates them is how directly they reach the macOS
APIs this app is made of:

| Need | Swift | Rust | Python |
| --- | --- | --- | --- |
| System audio (Core Audio tap, ScreenCaptureKit) | first-party API | community bindings (objc2, screencapturekit crate) | PyObjC, or the Swift helper the spec already allows |
| Mic with echo cancellation (AVAudioEngine voice processing) | first-party | raw FFI | PyObjC |
| Floating, non-activating, always-on-top panel that never steals focus from Meet or Teams | `NSPanel`, a few lines | winit plus objc2 patches | Qt window flags that approximate it |
| Global hotkeys, Keychain, permission prompts tied to an `.app` bundle | first-party | crates, mostly fine | PyObjC, permissions land on Terminal |
| Streaming gRPC to Google Speech | grpc-swift 2 (official gRPC project) plus generated code | tonic, excellent | official SDK |
| Anthropic API | small client over URLSession (no official Swift SDK) | same (no official Rust SDK) | official SDK |
| Processes and languages in the finished app | 1 and 1 | 1 and 1 | 2 and 2 (Python core, Swift audio helper, socket between) |

Swift wins every row that is specific to this app and only loses on gRPC tooling, which
is a one-off code generation step. Rust's real advantage, cross-platform code, buys
nothing for a Mac-only tool. Python means two processes, a socket protocol, a Python
runtime to ship, and macOS permissions granted to Terminal instead of the app.

Structure that keeps this honest: all logic that is not macOS glue (turn detection,
prompt building, token budget, cost, storage, WAV handling, provider clients) lives in
`ListenerCore`, which is plain Foundation and builds and tests on Linux too. The UI and
capture code stay thin.

## 2. Challenges to the technical defaults

### 2.1 Python, PySide6 -> Swift, AppKit/SwiftUI
Section 1.

### 2.2 System audio: Core Audio process tap instead of ScreenCaptureKit
Recommendation: a Core Audio process tap (macOS 14.2+) on all system audio except our own
process, with ScreenCaptureKit kept as a fallback (`capture.systemAudioBackend = "sck"`).

| | Core Audio tap | ScreenCaptureKit |
| --- | --- | --- |
| Permission | "System Audio Recording Only" | full Screen Recording (the app could see your screen) |
| Recurring prompt | none found | "...is requesting to bypass the system private window picker..." every 30 days, still on macOS 26 and 27 |
| What runs | audio only | a video stream must run alongside the audio |
| Apple's advice | DTS recommends taps for audio-only capture | |
| Missing permission | silent buffers, no error | silent buffers, no error |

Known tap pitfalls, all handled in the capture layer:
- No API reports whether permission was granted; the app detects a channel that is pure
  digital silence and tells you which permission to check.
- Reports of taps going silent mid-session on macOS 26.x: a watchdog rebuilds the tap
  after sustained digital silence.
- The aggregate device has to be rebuilt when the output device changes (headset plugged
  in, Bluetooth connects).
- If the output device also has inputs (a headset), their buffers arrive in front of the
  tap's. Reading them as tap audio would put your voice on the "Them" channel, so only
  the tap's trailing buffers are read.
- With AirPods in call mode the tap and its stream report 48 kHz but the frames arrive
  at 24 kHz, the rate of the aggregate device's clock. Read at 48 kHz, "Them" played at
  double speed and an octave up, and the first two real calls came out as nonsense
  ("to, to, to", 95 s turns of a dozen words). The tap now reads at the aggregate's
  nominal rate, and for as long as it runs counts the frames that arrive against the
  host clock, switching to another standard rate when two one-second spans in a row
  agree on it (`DeliveredRateMonitor`). That also covers pressing Start before joining,
  when the AirPods only switch to call mode mid-recording. Every build logs the formats
  Core Audio reports.

### 2.3 Global hotkeys do not need Accessibility
The spec asks to document the Accessibility permission. Carbon's `RegisterEventHotKey`,
which every mainstream Mac hotkey library uses (including sindresorhus/KeyboardShortcuts),
needs no Accessibility or Input Monitoring permission. Only event taps and global
`NSEvent` monitors do. We use `RegisterEventHotKey`, so calls need nothing granted.

Dictation is the exception. fn on its own is not a hotkey `RegisterEventHotKey` can
take, and pasting into another app means posting Command-V, so dictation watches fn
through a listen-only event tap and asks for Accessibility, which covers both. It looks
only at fn, Escape, and whether another key went down.

### 2.4 The 1.5 s target includes your reaction time
"First tokens within 1.5 s of the speaker finishing" starts the clock before you press
the hotkey. We cannot control how fast you press it, so every answer logs both:

- **end of speech -> first token** (the spec's number), and
- **hotkey -> first token** (what the app controls, target under 1.0 s).

Two design choices protect the budget:

- On hotkey we send the transcript *including the current interim result*, so we never
  wait for the speech-to-text final to arrive.
- The HTTP/2 connection to the Anthropic API is opened at Start, where the key and every
  model ID are checked, and kept open with a small request every 45 s, so no answer
  pays for a new connection after a quiet stretch.
- With documents, the quick and deep system prompts are written to the prompt cache at
  Start and before they expire. A warm-up carries the tier's own thinking and effort,
  since both are part of the cached prompt. Haiku's is sent with `max_tokens` 0; Sonnet
  with adaptive thinking caches `max_tokens` too, so its warm-up is the real request,
  stopped at `message_start`. Checked on the live API: the first answer of each tier
  read the warm-up's cache.

Optional, off by default: **draft ahead** (`answers.draftAhead`). When "Them" finishes a
turn, start generating a suggestion in the background and show it instantly if you press
the hotkey. On Haiku 5.5 a draft costs about $0.0005, so even 100 turns per call is about
5 cents.

### 2.5 Haiku 5.5: thinking off, low effort
Haiku 5.5 runs adaptive thinking by default, which adds time before the first visible
token. For the hotkey answer we turn thinking off (allowed on Haiku 5.5 at effort `high`
or below) and set effort `low`. Every answer logs its time to first token, so the choice
can be checked against measurements. The escalation hotkey (Sonnet 5.5) keeps
adaptive thinking at `low` or `medium` effort, since that path is for hard questions.

### 2.6 Prompt caching: what it actually buys here
With the tool definitions gone, the system prompt is a few hundred tokens. The minimum
cacheable prefix on Haiku 5.5 and Sonnet 5.5 is 512 tokens, so caching the system prompt
alone does nothing. The transcript is where caching pays, so the rolling window is
built to keep its prefix stable:

- The window start moves in steps (for example, drop the oldest 25% when the budget is
  exceeded) rather than sliding line by line. Between steps every request shares the
  previous request's prefix, so it is read from cache at 10% of the input price, which
  also shortens time to first token.
- A cache breakpoint sits at the end of the transcript in each request.

Budget: default 8k transcript tokens (about 20 minutes of non-stop conversation, more
with real pauses), hard cap 60k,
well under the 100k point where Haiku 5.5 pricing goes from $0.10/$0.50 to $0.50/$2.50
per million tokens. Each hotkey request is a fresh single-turn request, not a growing
conversation, which keeps requests small and avoids any thinking-block bookkeeping.

### 2.7 Speech-to-text: Google is the weak link for latency
Google Cloud Speech-to-Text v2 stays the default as specified (EU multi-region endpoint
`eu-speech.googleapis.com`, location `eu`), behind the provider interface. But the
research says it is the stage most likely to break the 1.5 s budget. Because the hotkey
sends whatever text exists at that moment, slow STT doesn't so much delay the answer as
make it miss the last words of the question, which is worse.

- **Models in `eu` for en-GB**: `chirp_3`, `long`, `short`, `telephony`,
  `telephony_short`. Chirp 3 is the current model and supports streaming; its only
  latency control is `endpointing_sensitivity` (`SHORT`, `SUPERSHORT`).
- **No forced finalize.** Google cannot be told "the speaker stopped, give me the final
  now". Deepgram has a `Finalize` message for exactly this.
- **Published measurements** (third party, US region): Chirp 3 median final about 475 ms
  after the stream closes, and a median time to first text of about 4.5 s with interim
  results on, which suggests Chirp 3 interims are late or sparse. Deepgram Nova-3 in the
  same benchmarks: about 100 to 250 ms. Google was slightly more accurate (WER 2.8% vs
  3.8%). Nobody has published `eu` numbers.
- **Streams last at most 5 minutes**, so each channel rotates to a new stream at a pause
  around the 4 minute mark and re-sends audio after the last final. Audio goes in 100 ms
  frames (3,200 bytes, well under the per-request limit).
- **Voice activity timeouts close the stream**, they are not endpointing, so we don't
  use them; our own VAD marks end of speech.
- **Cost**: $0.016 per minute per channel, billed per second. Two channels for an hour is
  about $1.92. Skipping silence on the "Me" channel with the local VAD (keeping a short
  pre-roll so word onsets aren't clipped) roughly halves that channel's cost.
- **Swift client**: Google's new Swift SDK for Speech v2 is REST only, with no
  `streamingRecognize`. We generate a gRPC client from a trimmed copy of Google's proto
  with grpc-swift-2 (needs macOS 15). Auth is our own: Application Default Credentials
  from `gcloud auth application-default login` are refreshed in-process, and any other
  credential type falls back to `gcloud auth application-default print-access-token`.
  The `x-goog-user-project` quota header is sent for user credentials.

Decision after the cost discussion: on-device recognition (section 2.11) is the default,
being free and the lowest latency; Google stays as the specified cloud option. Cheaper cloud alternatives exist if on-device accuracy falls short on real calls:
AssemblyAI Universal-Streaming (about $0.15 per hour per stream) and Soniox (about $0.12,
vendor figure), both far below Google's $0.96 per hour per channel. Deepgram Nova-3 is
the fastest in published tests at roughly $0.29 to $0.46 per hour per channel. Any of
them needs an account, so none is built in. The comparison should run on recordings of
real calls (`storage.saveAudio`), not only on the fixtures, which are clean synthetic
speech and flatter every engine.

### 2.8 "Hide from screen sharing": measured, and built
Apple's documentation calls `NSWindow.SharingType.none` a legacy constant and says not to
rely on it, and on some macOS 15 releases ScreenCaptureKit was reported to ignore it, so
this section first advised against it. Measured on macOS 26.3.1 instead: a window marked
`.none` is left out of ScreenCaptureKit display captures, both screenshots and the live
stream that Chrome, and so Google Meet, shares screens with, while the same window marked
`.readOnly` shows. So Listener hides its window from whole-screen shares and screenshots
while Window > Hide During Screen Sharing is on (the default). It cannot hide a display
mirrored to a TV or projector. Because Apple does not promise this behaviour, check it
again after macOS updates: share the whole screen in Meet and look at its preview.

### 2.9 The hardware setup matters more than any code
- **Clamshell mode**: the built-in mics are off with the lid closed. You need an external
  mic.
- **Headphones vs speakers**: on speakers the mic hears the other side, so "Me" would
  contain their words too. Options, in order of preference: headphones; Apple's voice
  processing (echo cancellation, `capture.voiceProcessing`); dropping "Me" segments
  that duplicate a recent "Them" segment.
- **Bluetooth headsets**: using a Bluetooth headset's mic switches its output to a low
  quality call profile and changes the output device's sample rate mid-call. The capture
  layer rebuilds the tap when the default output device or its format changes.

### 2.10 macOS 15 as the minimum
Core Audio taps need 14.2, grpc-swift 2 needs 15. macOS 26 and 27 are supported; the
optional on-device speech provider needs 26.

### 2.11 On-device speech recognition as an option
macOS 26 added `SpeechAnalyzer`/`SpeechTranscriber`: on-device, long-form, streaming
recognition with interim ("volatile") results. Against Google it costs nothing, has no
network round trip, and keeps call audio on the Mac, which matters for client calls at
a regulated firm. Accuracy on British English and trading jargon is unknown until
measured. It is the default: `speech.provider = "auto"` picks it on Macs that support it
and Google elsewhere; `"apple"` or `"google"` pins one. The comparison that matters is on
recordings of real calls (`storage.saveAudio`).

## 3. Architecture

### 3.1 Modules

```
ListenerCore  (Foundation only, builds and tests on Linux)
  Audio/          AudioChunk, LevelMeter, WAV I/O, VoiceActivityDetector, AudioFramer,
                  GapFiller and the capture recovery logic
  Transcription/  SpeechToTextProvider protocol, the on-device rotating stream logic
  Transcript/     Turn, TranscriptSnapshot, TurnDetector, ConversationScript
  Answering/      LanguageModelProvider protocol, PromptBuilder, TranscriptWindow
  Dictation/      FnTapDetector, DictationRecorder, DictationTidier (the clean-up prompt)
  Metrics/        PriceTable, CostTracker, LatencyStats
  Session/        CallSession (the actor that wires everything), SessionStore,
                  SessionSummarizer, SessionEvent
  Config/         Settings, SettingsLoader, secrets, paths
  App/            window and terminal state reduced from session events, hotkey parsing,
                  display formatting, the setup checklist logic
  Replay/, Fakes/ ReplaySource, ScriptedSpeechToText, ScriptedLanguageModel

GoogleSpeech  Speech-to-Text v2 streaming over gRPC (generated client), credentials
ClaudeAPI     Anthropic Messages API client with SSE streaming and retries

ListenerMac   (macOS only)
  Capture/        MicrophoneCapture, SystemAudioTap, ScreenCaptureAudio, PCMConverter,
                  LiveAudioSources, CapturePermissions
  Speech/         AppleSpeechProvider (SpeechAnalyzer, macOS 26+)
  Network/        URLSessionStreamingTransport for ClaudeAPI
  Hotkeys/        RegisterEventHotKey wrapper
  Dictation/      fn event tap, DictationController, pasting, the capsule on screen
  Secrets/        Keychain store and the standard secret chain
  UI/             floating NSPanel, SwiftUI views, menu bar item, CallModel

ListenerApp   the `listener` executable: the app with no arguments, plus the
              live, replay, sessions, summarize, read-page, dictate, demo and secrets
              subcommands
```

### 3.2 Data flow

```
 Mic (AVAudioEngine) ----\                        +--> STT session "Me"   --\
                          +--> PCMConverter -------+                          +--> TurnDetector --> CallSession --> UI
 System audio (tap) -----/     16 kHz mono Int16  +--> STT session "Them" --/          |                 |
 Replay (WAV files) ----/      100 ms chunks                                         VAD end-of-speech    |
                                                                                                         v
 Hotkey (Haiku) / Hotkey (Sonnet) --> CallSession --> PromptBuilder (system + window + interim) --> Anthropic SSE --> UI
                                            |
                                            +--> AnswerLatency: end of speech, STT final, hotkey, response begins, first token, done
 CostTracker: STT seconds per channel + LLM tokens (input, cache read, cache write, output) per model --> UI footer, session.json
 Stop --> Summary (Sonnet 5.5, full transcript) --> summary.md
```

Replay feeds WAV files through the same converter-to-chunk path at real-time pace (or
faster with `--speed`), so the whole pipeline, including latency logging, runs the same
way as live.

### 3.3 Key interfaces

The seams are protocols in ListenerCore: `AudioCaptureSource`
(`Audio/AudioCaptureSource.swift`), `SpeechToTextProvider` and `SpeechStream`
(`Transcription/SpeechToText.swift`), and `LanguageModelProvider`
(`Answering/LanguageModel.swift`).

Swapping Google for Deepgram is a new `SpeechToTextProvider`. Moving Claude to Vertex
AI is a new `LanguageModelProvider` (different base URL, auth and model naming) chosen
in config.

### 3.4 Concurrency

Swift 6 strict concurrency throughout. Capture sources call back on their own queues
and hand over `AudioChunk` values (plain value types). Each channel's STT stream runs in
its own task. `CallSession` is an actor that owns the transcript, turn detector and
metrics; the UI observes it through an `@Observable` model on the main actor. No locks
outside the capture edge.

### 3.5 Turn detection

Per channel. A local energy VAD on the 16 kHz stream gives a precise end-of-speech time
(needed for latency numbers; the STT provider's own timestamps are relative to stream
audio and arrive late). A turn ends when the STT final for the speech has arrived **and**
the VAD has seen `turns.silenceMs` of silence (default 700 ms). Consecutive finals from
the same speaker inside that gap merge into one turn. Thresholds live in settings and
replay mode makes tuning them repeatable.

### 3.6 Answer prompt

```
system:   role, the "no invented specifics" rule, answer style (short, speakable,
          bullets when listing), who "Me" and "Them" are          [stable]
user:     <transcript> window of finalized turns, oldest first     [cache breakpoint]
          current interim text for each channel, marked as in progress
          "Suggest what I should say next." (or the escalation variant)
```

### 3.7 Cost tracking

`PriceTable` lives in settings, so price changes need no code change. Per session we
record STT seconds per channel and, per model, input, cache-read, cache-write and output
tokens from each response's `usage`. The UI footer shows the running total; it is saved
in `session.json`.

Rough cost of a one-hour call with Google speech-to-text:

| Item | Assumption | Cost |
| --- | --- | --- |
| Speech-to-text | 2 channels x 60 min x $0.016 | $1.92 (about $1.40 with silence skipping on "Me") |
| Quick answers, Haiku 5.5 | 20 per call, 6k input + 150 output tokens each | $0.01 |
| Escalations, Sonnet 5.5 | 5 per call, 6k input + 400 output tokens each | $0.08 |
| Summary, Sonnet 5.5 | 13k input + 1.5k output tokens | $0.04 |
| **Total** | | **about $2 per hour, over 90% of it speech-to-text** |

The LLM side is cheap enough that cost should not steer prompt design; latency should.

### 3.8 Storage, retention, privacy

- Sessions in `~/Library/Application Support/Listener/sessions/<date-time>/`:
  `transcript.jsonl`, `session.json` (settings snapshot, latency, cost), `summary.md`.
- Retention: sessions older than `storage.retentionDays` (default 30) are deleted at
  launch.
- Raw audio is not saved unless `storage.saveAudio` is on (useful for making replay
  fixtures).
- Logging through Apple's unified logging (`os.Logger`) with transcript text and secrets
  marked private, so they are redacted from log output. Transcript text only leaves the
  machine to the configured STT and LLM providers.
- Dictation keeps nothing on disk. Its audio stays on the Mac (Apple's on-device model
  only); the words, the app's name and its window title go to Claude for tidying. The
  last text typed is kept in memory for **Copy Last Dictation**.
- Secrets: Anthropic key in the Keychain (`listener secrets set anthropic`) or `.env`
  (gitignored). Google uses Application Default Credentials
  (`gcloud auth application-default login`) or a service account key file whose path is
  in settings. Keys are never logged.

### 3.9 Testing

- Unit tests (swift-testing) for turn detection, transcript window and token budget,
  prompt building, cost calculation, SSE parsing, WAV handling, settings loading.
- Provider clients tested against recorded responses (no network in tests).
- End-to-end replay test: fixture WAV pair -> real pipeline -> scripted fake STT and fake
  LLM -> assert transcript, turns, answer text, latency records and cost.
- `ListenerCore` tests run on Linux and macOS. Capture code has no unit tests; it is
  checked on real calls.

## 4. Next

Agreed after the first week of use, in this order:

1. **Echo warning.** When the mic hears the call (speakers instead of headphones), the
   same words land on both channels and every "Them" line comes back as "Me" too. Spot
   matching text on both channels within a second or two and say so.
2. **Memory across calls.** Include the last summary with the same contact, so answers
   know what was promised and what is still open.
3. **Bookmark hotkey.** Mark a moment mid-call; the summary puts marked moments first.
4. **Setup from the calendar.** Call type, attendees and agenda from the meeting invite.
5. **Answers without the hotkey**, opt-in: show the draft when a question is aimed at Me.

Also considered: **vision**, a hotkey that sends what is on screen (say, a customer
complaint someone is sharing) to Claude with the transcript. ScreenCaptureKit is already
in the project, Claude reads images, and Listener's own window is left out of captures.
It needs Screen Recording permission, which macOS re-confirms from time to time.
