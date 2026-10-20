# Listener: plan and architecture

Started as the M0 proposal. You then asked for the whole app to be built in one go with
as many agents as needed, so the milestones below are delivered together rather than
one approval at a time.

## 1. What changed from the original spec

Following your instructions:

- **No lookups.** The tool layer (BigQuery, Jira mocks), entity detection, background
  prefetch and fact cards are gone. Old M4 (prefetch) is dropped and old M5 (summary)
  becomes M4. Answers come from the transcript plus Claude's general knowledge.
- **One guard kept from "facts before prose".** The system prompt tells the model not to
  invent call-specific details (amounts, account numbers, dates, names) that are not in
  the transcript, and to say so when it doesn't know. It costs nothing and stops you
  repeating a made-up figure to a broker. Say if you want it removed.
- **The no-stealth rule is gone**, but I have not built a "hide from screen sharing"
  option because macOS no longer supports one reliably (section 3.8). Capture still
  starts only when you press Start, and the listening indicator stays, because both
  protect you, not the other side.
- **Code style section dropped.** Language chosen on merit (section 2).

## 2. Language: Swift

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

## 3. Challenges to the technical defaults

### 3.1 Python, PySide6 -> Swift, AppKit/SwiftUI
Section 2.

### 3.2 System audio: Core Audio process tap instead of ScreenCaptureKit
Recommendation: a Core Audio process tap (macOS 14.2+) on all system audio except our own
process, with ScreenCaptureKit kept as a fallback (`capture.systemAudioBackend = "sck"`,
`--system sck` in the spike).

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

The spike measures both backends on your Mac (continuity, gaps, CPU, separation). Those
numbers are the evidence that settles it.

### 3.3 Global hotkeys do not need Accessibility
The spec asks to document the Accessibility permission. Carbon's `RegisterEventHotKey`,
which every mainstream Mac hotkey library uses (including sindresorhus/KeyboardShortcuts),
needs no Accessibility or Input Monitoring permission. Only event taps and global
`NSEvent` monitors do. We use `RegisterEventHotKey`, so there is nothing to grant.

### 3.4 The 1.5 s target includes your reaction time
"First tokens within 1.5 s of the speaker finishing" starts the clock before you press
the hotkey. We cannot control how fast you press it, so every answer logs both:

- **end of speech -> first token** (the spec's number), and
- **hotkey -> first token** (what the app controls, target under 1.0 s).

Two design choices protect the budget:

- On hotkey we send the transcript *including the current interim result*, so we never
  wait for the speech-to-text final to arrive.
- The HTTP/2 connection to the Anthropic API is opened at Start and kept warm, which
  saves the TLS handshake on the first answer.

Optional, off by default: **draft ahead**. When "Them" finishes a turn, start generating
a suggestion in the background and show it instantly if you press the hotkey. On Haiku
5.5 a draft costs about $0.0005, so even 100 turns per call is about 5 cents. Worth
trying in M3 if the measured latency disappoints.

### 3.5 Haiku 5.5: thinking off, low effort
Haiku 5.5 runs adaptive thinking by default, which adds time before the first visible
token. For the hotkey answer we turn thinking off (allowed on Haiku 5.5 at effort `high`
or below) and set effort `low`. M3 measures time-to-first-token with and without
thinking so the choice rests on numbers. The escalation hotkey (Sonnet 5.5) keeps
adaptive thinking at `low` or `medium` effort, since that path is for hard questions.

### 3.6 Prompt caching: what it actually buys here
With the tool definitions gone, the system prompt is a few hundred tokens. The minimum
cacheable prefix on Haiku 5.5 and Sonnet 5.5 is 512 tokens, so caching the system prompt
alone does nothing. The transcript is where caching pays, so the rolling window is
built to keep its prefix stable:

- The window start moves in steps (for example, drop the oldest 25% when the budget is
  exceeded) rather than sliding line by line. Between steps every request shares the
  previous request's prefix, so it is read from cache at 10% of the input price, which
  also shortens time to first token.
- A cache breakpoint sits at the end of the transcript in each request.

Budget: default 8k transcript tokens (about 10 minutes of conversation), hard cap 60k,
well under the 100k point where Haiku 5.5 pricing goes from $0.10/$0.50 to $0.50/$2.50
per million tokens. Each hotkey request is a fresh single-turn request, not a growing
conversation, which keeps requests small and avoids any thinking-block bookkeeping.

### 3.7 Speech-to-text: Google is the weak link for latency
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

Decision after the cost discussion: on-device recognition (section 3.12) is the default
choice for you, being free and the lowest latency; Google stays as the specified cloud
option. Cheaper cloud alternatives exist if on-device accuracy falls short on real calls:
AssemblyAI Universal-Streaming (about $0.15 per hour per stream) and Soniox (about $0.12,
vendor figure), both far below Google's $0.96 per hour per channel. Deepgram Nova-3 is
the fastest in published tests at roughly $0.29 to $0.46 per hour per channel. Any of
them needs an account, so none is added without your go-ahead. The comparison should run
on recordings of your own calls (`storage.saveAudio`), not only on the fixtures, which
are clean synthetic speech and flatter every engine.

### 3.8 "Hide from screen sharing" does not work reliably any more
Apple's current documentation calls `NSWindow.SharingType.none` "a legacy constant that
macOS no longer uses" and says not to rely on it to keep content out of captures. Apple
DTS: "there are no public APIs for preventing screen capture". ScreenCaptureKit ignores
the setting, and Chrome (so Google Meet) shares screens through ScreenCaptureKit on
macOS 14.4 and later. Chromium hides its own windows with a private API instead. A toggle
would seem to work in some apps and silently fail in Meet, which is worse than no
toggle, so I have not built it. What works: keep the window on your second monitor and
share a window or a tab rather than the whole screen.

### 3.9 Your hardware setup matters more than any code
- **Clamshell mode**: the built-in mics are off with the lid closed. You need an external
  mic. The spike reports which input device it used.
- **Headphones vs speakers**: on speakers the mic hears the other side, so "Me" would
  contain their words too. Options, in order of preference: headphones; Apple's voice
  processing (echo cancellation, `--voice-processing` in the spike); dropping "Me"
  segments that duplicate a recent "Them" segment. The spike's phase 2 measures this.
- **Bluetooth headsets**: using a Bluetooth headset's mic switches its output to a low
  quality call profile and changes the output device's sample rate mid-call. The capture
  layer rebuilds the tap when the default output device or its format changes (M1).

### 3.10 macOS 15 as the minimum
Core Audio taps need 14.2, grpc-swift 2 needs 15. macOS 26 and 27 are supported; the
optional on-device speech provider needs 26.

### 3.11 Pushing and CI
The spec says not to push or create remotes. This repository already has a GitHub remote
and this session is set up to push to `claude/exciting-mayer-txjtxk`, so I push there
and nowhere else. I wrote a CI workflow (lint and Linux tests, macOS build and bundle),
but GitHub refuses workflow files from this session's token, so it sits in `ci/` until
you move it (README, "CI").

### 3.12 On-device speech recognition as an option
macOS 26 added `SpeechAnalyzer`/`SpeechTranscriber`: on-device, long-form, streaming
recognition with interim ("volatile") results. Against Google it costs nothing, has no
network round trip, and keeps call audio on your Mac, which matters for client calls at
a regulated firm. Accuracy on British English and trading jargon is unknown until
measured. It is built as `speech.provider = "apple"` alongside Google; the replay
benchmark compares the two on the fixture calls.

## 4. Architecture

### 4.1 Modules

```
ListenerCore  (Foundation only, builds and tests on Linux)
  Audio/          AudioChunk, LevelMeter, WAV I/O, VoiceActivityDetector, AudioFramer,
                  Resampler, GapFiller and the capture recovery logic
  Transcription/  SpeechToTextProvider protocol, the on-device rotating stream logic
  Transcript/     Turn, TranscriptSnapshot, TurnDetector, ConversationScript
  Answering/      LanguageModelProvider protocol, PromptBuilder, TranscriptWindow
  Metrics/        PriceTable, CostTracker, LatencyStats
  Session/        CallSession (the actor that wires everything), SessionStore,
                  SessionSummarizer, SessionEvent
  Config/         Settings, SettingsLoader (JSON + LISTENER_* env), secrets, paths
  App/            window and terminal state reduced from session events, hotkey parsing,
                  display formatting, the setup checklist logic
  Replay/, Fakes/ ReplaySource, ScriptedSpeechToText, ScriptedLanguageModel
  Spike/          the audio spike's analysis

GoogleSpeech  Speech-to-Text v2 streaming over gRPC (generated client), credentials
ClaudeAPI     Anthropic Messages API client with SSE streaming and retries

ListenerMac   (macOS only)
  Capture/        MicrophoneCapture, SystemAudioTap, ScreenCaptureAudio, PCMConverter,
                  LiveAudioSources, CapturePermissions
  Speech/         AppleSpeechProvider (SpeechAnalyzer, macOS 26+)
  Network/        URLSessionStreamingTransport for ClaudeAPI
  Hotkeys/        RegisterEventHotKey wrapper
  Secrets/        Keychain store and the standard secret chain
  UI/             floating NSPanel, SwiftUI views, menu bar item, CallModel

ListenerApp   the `listener` executable: the app with no arguments, plus the
              live, replay, secrets, sessions, summarize and spike subcommands
```

### 4.2 Data flow

```
 Mic (AVAudioEngine) ----\                        +--> STT session "Me"   --\
                          +--> PCMConverter -------+                          +--> TurnDetector --> TranscriptStore --> UI
 System audio (tap) -----/     16 kHz mono Int16  +--> STT session "Them" --/          |                 |
 Replay (WAV files) ----/      100 ms chunks                                         VAD end-of-speech    |
                                                                                                         v
 Hotkey (Haiku) / Hotkey (Sonnet) --> AnswerService --> PromptBuilder (system + window + interim) --> Anthropic SSE --> UI
                                            |
                                            +--> LatencyTrace: end of speech, STT final, hotkey, request sent, first token, done
 CostTracker: STT seconds per channel + LLM tokens (input, cache read, cache write, output) per model --> UI footer, session.json
 Stop --> Summary (Sonnet 5.5, full transcript) --> summary.md
```

Replay feeds WAV files through the same converter-to-chunk path at real-time pace (or
faster with `--speed`), so the whole pipeline, including latency logging, runs the same
way as live.

### 4.3 Key interfaces

```swift
public protocol AudioCaptureSource: AnyObject, Sendable {
    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) async throws -> ChannelInfo
    func stop()
}

public protocol SpeechToTextProvider: Sendable {
    func openStream(for speaker: Speaker) async throws -> any SpeechStream
}

public protocol SpeechStream: Sendable {
    func send(_ chunk: AudioChunk) async throws
    var events: AsyncThrowingStream<TranscriptEvent, Error> { get }
    func finish() async
}

public enum TranscriptEvent: Sendable {
    case speechStarted(Speaker, audioOffset: Duration)
    case speechEnded(Speaker, audioOffset: Duration)
    case interim(Speaker, text: String)
    case final(Speaker, text: String, audioStart: Duration, audioEnd: Duration)
}

public protocol LanguageModelProvider: Sendable {
    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error>
}

public enum AnswerEvent: Sendable {
    case text(String)
    case usage(TokenUsage)
}
```

Swapping Google for Deepgram is a new `SpeechToTextProvider`. Moving Claude to Vertex
AI is a new `LanguageModelProvider` (different base URL, auth and model naming) chosen
in config.

### 4.4 Concurrency

Swift 6 strict concurrency throughout. Capture sources call back on their own queues
and hand over `AudioChunk` values (plain value types). Each channel's STT stream runs in
its own task. `CallSession` is an actor that owns the transcript, turn detector and
metrics; the UI observes it through an `@Observable` model on the main actor. No locks
outside the capture edge.

### 4.5 Turn detection

Per channel. A local energy VAD on the 16 kHz stream gives a precise end-of-speech time
(needed for latency numbers; the STT provider's own timestamps are relative to stream
audio and arrive late). A turn ends when the STT final for the speech has arrived **and**
the VAD has seen `silence_ms` of silence (default 700 ms). Consecutive finals from the same
speaker inside that gap merge into one turn. Thresholds live in settings and replay mode
makes tuning them repeatable.

### 4.6 Answer prompt

```
system:   role, the "no invented specifics" rule, answer style (short, speakable,
          bullets when listing), who "Me" and "Them" are          [stable]
user:     <transcript> window of finalized turns, oldest first     [cache breakpoint]
          current interim text for each channel, marked as in progress
          "Suggest what I should say next." (or the escalation variant)
```

### 4.7 Cost tracking

`PriceTable` lives in settings, so price changes need no code change. Per session we
record STT seconds per channel and, per model, input, cache-read, cache-write and output
tokens from each response's `usage`. The UI footer shows the running total; it is saved
in `session.json`.

Rough cost of a one-hour call (to be replaced by measured numbers from M1 and M3):

| Item | Assumption | Cost |
| --- | --- | --- |
| Speech-to-text | 2 channels x 60 min x $0.016 | $1.92 (about $1.40 with silence skipping on "Me") |
| Quick answers, Haiku 5.5 | 20 per call, 6k input + 150 output tokens each | $0.01 |
| Escalations, Sonnet 5.5 | 5 per call, 6k input + 400 output tokens each | $0.08 |
| Summary, Sonnet 5.5 | 13k input + 1.5k output tokens | $0.04 |
| **Total** | | **about $2 per hour, over 90% of it speech-to-text** |

The LLM side is cheap enough that cost should not steer prompt design; latency should.

### 4.8 Storage, retention, privacy

- Sessions in `~/Library/Application Support/Listener/sessions/<date-time>/`:
  `transcript.jsonl`, `session.json` (settings snapshot, latency, cost), `summary.md`.
- Retention: sessions older than `retention_days` (default 30) are deleted at launch.
- Raw audio is not saved unless `save_audio` is on (useful for making replay fixtures).
- Logging through Apple's unified logging (`os.Logger`) with transcript text and secrets
  marked private, so they are redacted from log output. Transcript text only leaves the
  machine to the configured STT and LLM providers.
- Secrets: Anthropic key in the Keychain (`listener secrets set anthropic`) or `.env`
  (gitignored). Google uses Application Default Credentials
  (`gcloud auth application-default login`) or a service account key file whose path is
  in settings. Keys are never logged.

### 4.9 Testing

- Unit tests (swift-testing) for turn detection, transcript window and token budget,
  prompt building, cost calculation, SSE parsing, WAV handling, settings loading.
- Provider clients tested against recorded responses (no network in tests).
- End-to-end replay test: fixture WAV pair -> real pipeline -> scripted fake STT and fake
  LLM -> assert transcript, turns, answer text, latency records and cost.
- `ListenerCore` tests run on Linux and macOS; capture code is exercised by the spike.

## 5. Milestones

You asked for the whole app at once, so the milestones were built in parallel and
merged together:

| | Deliverable | Status | How you try it |
| --- | --- | --- | --- |
| M0 | Plan, audio spike | built | `scripts/spike.sh` |
| M1 | Terminal transcript, replay, fixture calls, Google STT (EU), on-device STT, turn detection, storage | built | `listener live --terminal`, `listener replay ...` |
| M2 | Floating window, Start/Stop, listening indicator, menu bar item, setup checklist | built | `scripts/run.sh` |
| M3 | Quick and deep hotkey answers, latency logging, cost tracking | built | the hotkeys, or `listener replay ... --ask-at` |
| M4 | Post-call summary and action items as Markdown | built | press Stop |

Everything outside ListenerMac and ListenerApp is covered by tests that run on Linux,
including end-to-end runs of the fixture calls through the real pipeline with scripted
speech-to-text and model. The macOS code type-checks against the macOS 15.5 and 26.5
SDKs but has not been linked or run, because this was built without a Mac.

## 6. Open questions for you

1. Which macOS version are you on? On-device speech needs 26 or later.
2. Headphones on calls, or speakers? Which mic do you use with the lid closed?
3. Speech-to-text: on-device (free) to start with? If its accuracy on your real calls
   falls short, AssemblyAI or Soniox stream for roughly 25 to 30 cents per call-hour,
   much less than Google; either needs an account, so I'm asking before adding one.
4. Default hotkeys: Control-Option-Space (quick), Control-Option-Shift-Space (deep),
   Control-Option-L (start/stop). Any clashes with your setup?

## 7. First run on your Mac

1. `scripts/spike.sh` with headphones on: both channels should pass. Then
   `scripts/spike.sh --system sck` for comparison.
2. `scripts/run.sh`, `listener secrets set anthropic`, choose a speech provider in the
   settings file, press Start on a test call (Meet's "Check your audio and video" works).
3. `listener replay` on a fixture with `--ask-at` to see the latency table.
4. Send me any build error, spike report or odd behaviour, and turn on
   `storage.saveAudio` for a couple of real calls so we can compare providers on them.
