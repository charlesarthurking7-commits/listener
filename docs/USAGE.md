# Using Listener

Listener runs as a menu bar app with a floating window, or from the terminal. Both
capture your microphone as "Me" and the Mac's audio as "Them", transcribe them
separately, suggest an answer when you press a hotkey, and save the call with a
summary when you stop.

## First run

1. **Build and open the app.**

   ```sh
   scripts/run.sh
   ```

   This builds `build/Listener.app`, signs it and opens it. A waveform icon appears in
   the menu bar and the Listener window appears on the right of your second display, or
   in the top right corner if you have one display.
   See the README for keeping permissions across rebuilds with a stable signing identity;
   once a certificate named `Listener Dev` is in your keychain, the build uses it.

2. **Speech-to-text.** By default (`speech.provider` is `"auto"`) Listener transcribes on
   the Mac with Apple's on-device recognition when your Mac supports it (macOS 26 and
   later): free, no account, and call audio is not sent anywhere for transcription
   (answers still go to Claude). Listener checks Apple's speech model for your language
   when it starts and macOS downloads it if needed; the checklist shows the progress.

   On older systems, or if you set `speech.provider` to `"google"`, it uses Google Cloud
   Speech-to-Text in the EU. Sign in once with Application Default Credentials and tell
   Listener your project:

   ```sh
   gcloud auth application-default login
   ```

   Then choose **Open Settings File** in the menu bar menu and set your project ID:

   ```json
   { "speech": { "googleProjectID": "your-gcp-project-id" } }
   ```

   A service account key works too: set `speech.googleCredentialsFile` to its path. If the
   credentials file names a quota project, that project is used when `googleProjectID`
   is not set.

   Set `speech.provider` to `"apple"` or `"google"` to pin one regardless of the Mac.

3. **Answers (Anthropic).** Store your API key in the Keychain. The `listener` command
   is the binary inside the app, so from the repository folder run:

   ```sh
   build/Listener.app/Contents/MacOS/listener secrets set anthropic
   ```

   (The checklist shows this command with a **Copy** button that copies it with the full
   path, and
   [Running the command line](#running-the-command-line) shows how to make `listener`
   a command.) Paste the key and press Enter; it is not shown. Without a key the
   transcript works but answers and the summary are off.

4. **Permissions.** Until everything is in place the window shows a setup checklist
   with a fix for each item; once it is, a short "Ready when you are" screen with the
   hotkeys and a compact status list. Nothing is recorded until you press **Start**. On
   the first Start macOS asks for:

   | Permission | Used for | Where to change it |
   | --- | --- | --- |
   | Microphone | "Me" | System Settings > Privacy & Security > Microphone |
   | System Audio Recording | "Them" (default tap backend) | Privacy & Security > Screen & System Audio Recording, "System Audio Recording Only" |
   | Screen Recording | "Them", only with `capture.systemAudioBackend` set to `sck` | Same pane, "Screen & System Audio Recording" |
   | Speech Recognition | Only with `speech.provider` set to `apple`, and only if macOS asks | Privacy & Security > Speech Recognition |

   Accessibility is not needed: the hotkeys use `RegisterEventHotKey`, which macOS
   allows without it. If "Them" stays silent, the window warns you; it almost always
   means System Audio Recording is off for Listener. macOS gives apps no way to check
   that permission up front, so the checklist shows System audio as allowed once a call
   has heard the other side.

### Running the command line

The `listener` command is the binary inside the app bundle. Running it from the
bundle keeps one build for both:

```sh
alias listener="$PWD/build/Listener.app/Contents/MacOS/listener"
listener --help
```

`swift run listener ...` works as well. When a command captures audio from Terminal,
macOS asks for permission on behalf of your terminal app, not Listener.

## The window

The window floats above other windows, appears on every Space and over full-screen
Meet or Teams, and never takes keyboard focus from them: clicking its buttons leaves
your call app active. Drag it by the empty part of its top or bottom bar and resize it
from any edge; it reopens where you left it, on the same display if it is still there.

During a call it shrinks to a slim bar: a red pill with a pulsing dot and the call's
time, **Quick**, **Deep** and **Recap** buttons, the transcript button, **Stop** and the
button that hides the window. An answer opens as a card under the bar and stays until
you close it or ask for another, and the window shrinks back after. The transcript is
still recorded and saved, and answers, recaps and the summary use it; the speech-bubble
button shows it.

Before and after a call, from top to bottom:

- **Header.** A grey dot and "Not listening", **Start**, and the button that hides the
  window (show it again from the menu bar, or with Control-Option-H).
- **Banners.** Warnings during the call, such as a silent channel or a capture restart.
- **Answer card.** Appears at the top when you press an answer hotkey: a **Quick**,
  **Deep** or **Recap** badge, the model, the time from the hotkey to the first word, a
  copy button and a close button. When nothing has been asked of you, an answer starts
  with a note saying so and what is being discussed, then at most one line you could
  add. A **Recap** reads the whole call so far, not just the recent part, and gives the
  gist, the main points, anything asked of you that is still open, and anything agreed. A placeholder shimmers until the first word arrives; words then
  appear as they stream, without moving. Lists and **bold** are formatted, and notes in
  square brackets, which are for you and not to be said, are shown apart under
  "For you". Copy leaves those notes out. A failed answer offers **Try Again**. Closing
  a card that is still streaming cancels it.
- **Transcript.** Turns are grouped by speaker under "Me" (teal) or "Them" (amber) with
  the time they started. Text still being recognised is dimmed until it settles. Short
  fillers that speech recognition makes up in near silence ("Yeah.", "Okay.") are
  dropped when Listener heard no speech under them. The
  transcript follows the newest line; scroll up to read back and it stays where you
  are, with a **Jump to latest** button to return.
- **After Stop.** A card shows the call being saved and summarised, then "Call saved"
  with its length, turns and cost, **Open Summary**, **Show in Finder**, and **New Call**
  to go back to the start screen and set up the next call.
- **Footer.** The call's running cost (hover for the split between speech-to-text and
  Claude), the first-word time of the last answer, and **Quick**, **Deep** and **Recap**
  buttons with their hotkeys. Clicking one does the same as pressing its hotkey.

The window follows Light and Dark Mode. With Reduce Motion on, the dot and the answer
placeholder stay still and cards appear without sliding; with Reduce Transparency the
background is solid.

### Window options

Under **Window** in the menu bar:

- **Move to Top Centre** puts the window just under the menu bar, near the camera, so
  reading an answer looks like looking at the person.
- **Transparency.** **Glass** (the default) is macOS's Liquid Glass, which frosts what is
  behind; over a plain white page it looks much like Solid, since there is nothing to
  blur. **Clear** doesn't blur: it tints the background dark under light text, which reads
  over video or a busy desktop, and during a call it fades between answers until an
  answer arrives or the pointer is over it. **Solid** shows nothing behind.
- **Show Transcript During Calls** keeps the full window, transcript included, in a call.
- **Hide During Screen Sharing**, on by default, leaves the window out when you share
  your whole screen in Meet, Zoom or Teams, and out of screenshots and recordings. A small
  dot beside the menu bar icon shows it is on. It can't hide the window from a display
  mirrored to a TV or projector, or from a camera pointed at the screen. Turn it off to
  take a screenshot of the window.

### Menu bar

The waveform icon is filled while Listener is listening, with a small dot beside it
while the window is hidden from screen sharing. Its menu shows whether
Listener is listening and for how long, then Start/Stop Listening, Quick Answer, Deep
Answer and Recap So Far with their hotkeys, Call Type, Show or Hide Window, Window, Open
Last Summary (after a call), Open Sessions Folder, Open Settings File and Quit Listener. Quitting during a call stops and saves it first, and so does `kill` or
Ctrl-C in the terminal that started the app (press Ctrl-C twice to quit without waiting).

## Call types

Before Start, the **This call** card at the top of the window says what kind of call is
next and what Claude should know about it. Everything there goes with every answer,
recap and summary of the call. None of it needs the keyboard, so the window never
takes focus from Meet or Teams.

- **Call type.** Work call or Meeting, picked from the menu on the card or under Call
  Type in the menu bar. Each changes how answers go: Work call keeps to the general rules,
  and Meeting gives only a note when nothing has been asked of you. A call keeps the type
  it started with.
- **Files.** Drop a CV or other files onto the card: PDF, Word, RTF, HTML and text. A
  scanned PDF has no text and shows "No text found". The x moves a file to the Bin.
- **Paste.** Copy a job description, or its link, and press **Paste**. A link is read
  once, tidied by the quick model into the posting alone and saved as a file, with where
  it came from; check it before the call. Sites that need a sign-in, LinkedIn among them,
  can't be read; copy the text instead. `listener read-page <url>` shows what Paste would
  save.
- **Brief.** **Edit Brief** opens `brief.md` in TextEdit for your own notes: who the call
  is with and what it is for.
- **Stories.** **Edit Stories** in the card's menu opens `stories.md`, for your answers to
  "tell me about a time" questions: one block per story, with a short name, a "Good for:"
  line listing the kinds of question it answers, and its situation, task, action and
  result. The "Good for:" line is what picks the right story mid-call.
- **Instructions.** Each type's `instructions.md` says how answers should go, and wins
  over Listener's general rules where they differ. Open it with **Edit Instructions** in
  the card's menu. For a new type, copy a folder in Finder (**Show in Finder**) and rename
  it.

Each type is a folder under `~/Library/Application Support/Listener/Call Types/`, read
again at every Start, so changes in Finder or TextEdit count from the next call. Up to 20k
tokens of files go with each request. Listener writes them to Claude's prompt cache when
the call starts and refreshes it through quiet stretches, so even the first answer reads
them from there: a CV and a job description cost about $0.0001 per quick answer and add
no noticeable time. Text in `<!-- comments -->` is left out.

When nothing has been asked of you, an answer opens with a note saying so, and any line
after it is labelled "If you want to chip in".

## Hotkeys

| Action | Default |
| --- | --- |
| Quick answer (Haiku 5.5) | Control-Option-A (`ctrl+option+a`) |
| Deep answer (Sonnet 5.5) | Control-Option-Shift-A (`ctrl+option+shift+a`) |
| Recap so far (Sonnet 5.5) | Control-Option-S (`ctrl+option+s`) |
| Start or stop listening | Control-Option-L (`ctrl+option+l`) |
| Show or hide the window | Control-Option-H (`ctrl+option+h`) |

Change them in `settings.json` under `hotkeys`, then restart Listener. A hotkey is
modifiers and one key joined by `+`:

- Modifiers: `ctrl`, `option` (or `alt`), `shift`, `cmd`.
- Keys: `a` to `z`, `0` to `9`, `space`, `return`, `tab`, `escape`, `f1` to `f12`, and
  `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backslash`,
  `leftbracket`, `rightbracket`, `grave`.
- Every hotkey needs `ctrl`, `option` or `cmd`, except function keys. macOS 15 ignores
  hotkeys that use only `option` or `option+shift`, so Listener refuses those.

If another app already holds a combination, macOS refuses it and the window says so;
the menu still works. macOS's own shortcuts, and apps that watch the keyboard directly
rather than registering hotkeys, are not reported, so if a hotkey does nothing, pick
another.

## Live in the terminal

```sh
listener live --terminal
```

Settled turns print once with their time and speaker. What someone is saying right now
sits on the last line and updates in place.

| Key | Does |
| --- | --- |
| Enter | Quick answer |
| d, then Enter | Deep answer |
| r, then Enter | Recap so far |
| q, then Enter | Stop and save |
| Ctrl-C | Stop and save. Press it again to quit without waiting. |

The answer streams below the transcript, followed by its first-token time and cost.
Capture restarts (for example after switching headsets) and on-device model downloads
show as dimmed lines.

## Demo

```sh
listener demo                                  # a recorded call in the window, answers from Claude
listener demo --scripted-answers               # canned answers: no API key, Keychain or network
listener demo --call Fixtures/leverage-mirroring
```

Opens the app with a recorded call in place of your microphone and system audio. Press
**Start** and it plays into the window as if it were live, so every part of the window
can be tried without a call. Nothing on the Mac is captured.

## Replay

Replay plays two recordings through exactly the same pipeline as a live call. It is how
to try the app without a call, compare settings, and measure latency.

```sh
listener replay me.wav them.wav
listener replay me.wav them.wav --script call.json --speed 4
listener replay me.wav them.wav --ask-at 12.5,30,1:05 --tier quick
listener replay me.wav them.wav --ask-at 0:24 --call-type Meeting
```

- The recordings are 16-bit PCM WAV files, such as the `me.wav` and `them.wav` that the
  spike or `storage.saveAudio` write.
- `--script call.json` takes the words from a script instead of speech-to-text, so the
  transcript is fast and the same every time. The format:

  ```json
  {
    "title": "Fill dispute",
    "lines": [
      { "speaker": "Them", "start": 1.2, "end": 4.0, "text": "We saw slippage on the 14:02 fills." },
      { "speaker": "Me", "start": 4.6, "end": 6.1, "text": "Which account was that?" }
    ]
  }
  ```

- `--speed N` plays N times faster than real time (up to 20).
- `--ask-at` asks for an answer at each time in the recording (seconds, or
  minutes:seconds), as if you had pressed the hotkey. `--tier deep` uses the deep model
  and `--tier recap` asks for recaps.
- `--call-type Meeting` uses that call type's instructions and files, as Start does with
  the one picked in the window. A path to a folder laid out the same way works too.
  `listener live --terminal` takes it as well.
  At the end a table shows, per answer, the time from the end of speech and from the
  hotkey to the first token and to the end, the cost, and the medians against the 1.5 s
  target.

Replays are saved like any other call.

### Comparing speech engines

`Tools/SpeechBench` runs one side of a saved call through Apple's on-device model and
the open Whisper and Parakeet models, on the Mac, and reports words caught, repeated
words, the time each engine adds after a pause and, given a typed reference, the word
error rate. Turn on `storage.saveAudio` for the call first. See
[Tools/SpeechBench/README.md](../Tools/SpeechBench/README.md).

## Saved calls

Each call is saved in its own folder under
`~/Library/Application Support/Listener/sessions/` (or `storage.directory`):

| File | Contents |
| --- | --- |
| `transcript.jsonl` | One settled turn per line |
| `session.json` | Settings used, answers with their latency and cost, total cost |
| `summary.md` | Summary and action items, written when the call stops |
| `context.json` | The call type and documents the call started with |
| `me.wav`, `them.wav` | Only with `storage.saveAudio` on |

```sh
listener sessions                 # newest first, with length, turns, cost and summary
listener summarize "<folder name or path>"   # write summary.md again
```

Calls older than `storage.retentionDays` (30 by default, 0 keeps them forever) are
deleted when Listener starts.

## Settings

Listener reads `~/Library/Application Support/Listener/settings.json`, or the file given
with `--settings` (the app and the `live`, `replay`, `sessions` and `summarize` commands
accept it). **Open Settings File** creates a
starter file with the values people change most. The file only needs the values you
want to change: anything left out keeps its default, at every level.
[`settings.example.json`](../settings.example.json) lists every option with its default.

| Section | What it controls |
| --- | --- |
| `speech` | Provider (`auto` by default: on-device where supported, else Google; or `google`, `apple`, or `fake` for scripted replays), Google project, location, endpoint, model (`chirp_3`), language (`en-GB`), endpointing sensitivity, credentials file, stream rotation, silence skipping |
| `turns` | When a pause ends a turn: `silenceMs`, the voice activity threshold, minimum speech length |
| `answers` | The `quick`, `deep` and `recap` models (model, effort, thinking, max tokens), transcript budget, and `context`: who you are and what your calls are about |
| `summary` | Whether to write a summary, and its model |
| `capture` | System audio backend (`tap` or `sck`), echo cancellation for calls on speakers |
| `storage` | Sessions folder, retention in days, whether to keep the audio |
| `hotkeys` | The five hotkeys |
| `window` | Always on top, opacity, Dock icon |
| `prices` | Dollars per million tokens per model and per minute of speech-to-text, for the cost display |

The window reads the file again on every Start, so changes apply to the next call.
Hotkey and window changes need a restart.

Mistakes are reported with the key that is wrong, for example
`storage.retentionDays should be a whole number, but is "thirty"`. Unknown keys, such as
a typo, are ignored with a warning. If the file has an error when the app starts, the
app opens with defaults and shows the error; Start stays blocked until it is fixed.

### Environment variables

These override the settings file, for one-off runs and scripts. Empty values are ignored.

| Variable | Setting |
| --- | --- |
| `LISTENER_GOOGLE_PROJECT` | `speech.googleProjectID` |
| `LISTENER_GOOGLE_CREDENTIALS` | `speech.googleCredentialsFile` |
| `LISTENER_SPEECH_PROVIDER` | `speech.provider` |
| `LISTENER_SPEECH_MODEL` | `speech.model` |
| `LISTENER_LANGUAGE` | `speech.languageCode` |
| `LISTENER_QUICK_MODEL` | `answers.quick.model` |
| `LISTENER_DEEP_MODEL` | `answers.deep.model` |
| `LISTENER_RECAP_MODEL` | `answers.recap.model` |
| `LISTENER_SYSTEM_AUDIO` | `capture.systemAudioBackend` |
| `LISTENER_STORAGE_DIR` | `storage.directory` |
| `LISTENER_RETENTION_DAYS` | `storage.retentionDays` |
| `LISTENER_SAVE_AUDIO` | `storage.saveAudio` (`true`/`false`, `yes`/`no`, `1`/`0`) |

## API keys

Listener looks for `ANTHROPIC_API_KEY` in this order and uses the first it finds:

1. The Keychain: service `Listener`, account `ANTHROPIC_API_KEY`
   (`listener secrets set anthropic`, `listener secrets delete anthropic`).
2. The environment variable `ANTHROPIC_API_KEY`.
3. A `.env` file in the current directory.
4. `~/Library/Application Support/Listener/.env`.

`.env` files hold `KEY=value` lines; quotes and `#` comments work as in a shell.
`listener secrets status` shows where the key was found without printing it. Keys are
never written to logs.

After a rebuild, macOS asks once whether Listener can read its Keychain item: type your
login password, then choose Always Allow. The `Listener Dev` identity keeps Microphone and
System Audio Recording across rebuilds, but not this: the Keychain only trusts an app
across builds when Apple issued its certificate. To avoid the prompt while developing,
keep the key in `~/Library/Application Support/Listener/.env` instead.

## Where files go

| Path | What |
| --- | --- |
| `~/Library/Application Support/Listener/settings.json` | Settings |
| `~/Library/Application Support/Listener/.env` | Optional API keys |
| `~/Library/Application Support/Listener/sessions/` | Saved calls |
| `~/Library/Application Support/Listener/Call Types/` | Call types: instructions, files and briefs |
| `~/Library/Application Support/Listener/spike/` | Audio spike recordings |
| Keychain, service `Listener` | Anthropic API key |
| `~/.config/gcloud/application_default_credentials.json` | Google credentials from `gcloud` |

## Troubleshooting

- **"Them" is silent.** Turn on Listener under Privacy & Security > Screen & System Audio
  Recording, then Stop and Start. With headphones, check the call's audio actually plays
  on this Mac. After a rebuild with an ad hoc signature the switch can show as on while
  macOS no longer applies it to the new build; run `tccutil reset All local.listener`
  and press Start again so macOS asks afresh (this resets Listener's microphone access
  too).
- **"Them" is gibberish while "Me" is fine.** Check the log for "audio arrives at":
  Listener measures the rate the Mac's audio really arrives at and corrects it when Core
  Audio misreports it, as it does for AirPods in call mode. "Them formats" lines show
  what Core Audio reported at each start.
- **"Me" picks up the other side.** You are on speakers. Use headphones, or set
  `capture.voiceProcessing` to `true`.
- **No microphone with the lid closed.** The built-in mics are off in clamshell mode;
  plug in a headset or USB mic.
- **A hotkey does nothing.** The window lists hotkeys that could not be registered.
  Pick another combination in `hotkeys`. macOS's own shortcuts win without telling
  Listener, so avoid the ones listed under System Settings > Keyboard > Keyboard
  Shortcuts; Control-Option-Space, for example, switches input sources. Window managers
  such as Rectangle also use Control-Option combinations.
- **Answers are off.** `listener secrets status` shows whether the key is found.
- **Anything else.** Listener logs what it does (calls starting and stopping, each
  answer's latency, tokens and cost, capture restarts, warnings and errors, never what
  was said) to the macOS log. Watch it live while you reproduce the problem:

  ```sh
  log stream --predicate 'subsystem == "local.listener"' --level info
  ```

  Afterwards, `log show --last 1h --predicate 'subsystem == "local.listener"'` still
  has the starts, stops, warnings and errors; macOS keeps the per-answer lines only
  while streaming, but they are also in each call's `session.json`. Device names and
  file paths show as `<private>`.
