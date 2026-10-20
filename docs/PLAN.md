# Listener: plan and architecture (M0)

This is the M0 proposal. Nothing past M0 gets built until you approve it.

## 1. What changed from the original spec

Following your instructions:

- **No lookups.** The tool layer (BigQuery, Jira mocks), entity detection, background
  prefetch and fact cards are gone. Old M4 (prefetch) is dropped and old M5 (summary)
  becomes M4. Answers come from the transcript plus Claude's general knowledge.
- **One guard kept from "facts before prose".** The system prompt tells the model not to
  invent call-specific details (amounts, account numbers, dates, names) that are not in
  the transcript, and to say so when it doesn't know. It costs nothing and stops you
  repeating a made-up figure to a broker. Say if you want it removed.
- **The no-stealth rule is gone.** M2 gets an optional "hide from screen sharing"
  setting, off by default. See section 3.8 for how reliable that is on current macOS.
  Capture still starts only when you press Start, and the listening indicator stays,
  because both protect you, not the other side.
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
<!-- TAP_EVIDENCE -->

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
  `streamingRecognize`. We generate a gRPC client from Google's protos with
  grpc-swift-2 (needs macOS 15) and take auth from Google's `swift-google-auth`
  package (ADC or service account, adds the `x-goog-user-project` quota header).

Plan: M1 builds the Google provider and a replay benchmark that measures, per model and
sensitivity, end of speech -> final, end of speech -> first interim, and accuracy on the
fixture recordings. If Google's median end of speech -> final is above about 700 ms, I
recommend adding Deepgram Nova-3 on its EU endpoint (`api.eu.deepgram.com`) as a second
provider. That needs a Deepgram account, so per your rules I'm asking rather than doing
it: **may I add Deepgram as an option if Google measures slow?**

### 3.8 "Hide from screen sharing"
<!-- SHARING_EVIDENCE -->

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
Core Audio taps need 14.2, grpc-swift 2 needs 15. Tell me if you are on 14.

### 3.11 Pushing and CI
The spec says not to push or create remotes. This repository already has a GitHub remote
and this session is set up to push to `claude/exciting-mayer-txjtxk`, so I push there
and nowhere else. I wrote a CI workflow (lint and Linux tests, macOS build and bundle),
but GitHub refuses workflow files from this session's token, so it sits in `ci/` until
you move it (README, "CI").

## 4. Architecture

### 4.1 Modules

```
ListenerCore  (Foundation only, Linux-testable)
  Audio/          AudioChunk, LevelMeter, WAV reader/writer, 100 ms framing, energy VAD
  Transcription/  SpeechToTextProvider protocol, TranscriptEvent, TurnDetector
  Transcript/     TranscriptStore (segments: speaker, text, audio start/end, final?)
  Answering/      LanguageModelProvider protocol, PromptBuilder, TranscriptWindow, AnswerService
  Providers/      GoogleSpeechV2 (gRPC), AnthropicMessages (HTTPS + SSE), Google auth
  Metrics/        LatencyTrace, CostTracker, PriceTable
  Session/        CallSession (actor that wires everything), SessionStore, Retention, Summary
  Config/         Settings (JSON file + LISTENER_* env vars), SecretStore protocol
  Spike/          M0 spike analysis

ListenerMac   (macOS glue)
  Capture/        MicrophoneCapture, SystemAudioTap, ScreenCaptureAudio, PCMConverter
  Hotkeys/        RegisterEventHotKey wrapper
  Secrets/        KeychainSecretStore
  Window/         floating NSPanel host

ListenerApp   (executable)
  CLI             listener spike | live --terminal | replay | summarize | secrets
  UI              SwiftUI views: transcript, answer, Start/Stop, listening indicator, cost/latency footer
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

## 5. Milestones (revised)

| | Deliverable | How you try it |
| --- | --- | --- |
| M0 | This plan, audio spike | `scripts/spike.sh` |
| M1 | Live speaker-labelled transcript in the terminal, replay mode, sample recordings, Google STT v2 (EU), turn detection, session storage | `listener live --terminal`, `listener replay Fixtures/...` |
| M2 | Floating always-on-top window: transcript, Start/Stop, listening indicator, optional hide-from-sharing | `scripts/run.sh` |
| M3 | Hotkey answers (Haiku 5.5), escalation hotkey (Sonnet 5.5), latency logging, cost tracking | press the hotkeys during replay or a test call |
| M4 | Post-call summary and action items as Markdown | press Stop |

Each milestone ends with tests passing, a commit, and measured numbers (latency per
stage, cost per test session).

## 6. Open questions for you

1. Which macOS version are you on? (15 is the minimum in this plan.)
2. Headphones on calls, or speakers? Which mic do you use with the lid closed?
3. GCP project ID for Speech-to-Text, and do you want ADC (your gcloud login) or a
   service account key?
4. Default hotkeys: Control-Option-Space for the quick answer and
   Control-Option-Shift-Space for escalation. Any clashes with your setup?
5. English variant of your calls: en-GB?

## 7. M0 status

Done:

- Swift package with the module split above. `ListenerCore` has the spike's analysis,
  level metering and WAV I/O, with 21 unit tests passing (run on Linux, Swift 6.4.1).
- `listener spike`: captures the mic and system audio as two separate 16 kHz streams,
  with either backend, guides you through three phases, writes both channels to WAV and
  a report with PASS/FAIL checks. `scripts/spike.sh` bundles, signs and launches it.
- swift-format config, lint clean.

Not verified, and why: this session runs on Linux. There is no Mac to run the spike on,
and GitHub refused the CI workflow (token lacks the `workflow` scope), so the macOS code
(`Sources/ListenerMac`, `Sources/ListenerApp`) has **not been compiled yet**. I checked
every Apple API call against Apple's headers and working open-source code instead, but
expect the first build on your Mac to possibly need a small fix. The proof that capture
works on your Mac is the spike report you get from running it.

What I need from you to close M0:

1. Run `scripts/spike.sh` and `scripts/spike.sh --system sck` (headphones on), and send
   me both reports. If anything fails to compile, send the error.
2. Answers to the questions in section 6, and the Deepgram question in 3.7.
3. Approval of this plan, or changes.
