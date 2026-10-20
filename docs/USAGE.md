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

2. **Speech-to-text.** Google Cloud is the default. Sign in once with Application Default
   Credentials and tell Listener your project:

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

   On macOS 26 you can transcribe on the Mac instead: set `speech.provider` to `"apple"`.
   No Google account is needed and call audio is not sent anywhere for transcription
   (answers still go to Claude). Listener checks Apple's speech model for your language
   as soon as the setting is in place and macOS downloads it if needed; the checklist
   shows the progress.

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
   means System Audio Recording is off for Listener.

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

From top to bottom:

- **Header.** While recording, a red "Listening" pill with a pulsing dot and the
  call's elapsed time; a grey dot and "Not listening" otherwise. **Start** and **Stop**
  sit on the right, next to the button that hides the window (show it again from the
  menu bar).
- **Banners.** Warnings during the call, such as a silent channel or a capture restart.
- **Answer card.** Appears at the top when you press an answer hotkey: a **Quick** or
  **Deep** badge, the model, the time from the hotkey to the first word, a copy button
  and a close button. A placeholder shimmers until the first word arrives; words then
  appear as they stream, without moving. Lists and **bold** are formatted, and notes in
  square brackets, which are for you and not to be said, are shown apart under
  "For you". Copy leaves those notes out. A failed answer offers **Try Again**. Closing
  a card that is still streaming cancels it.
- **Transcript.** Turns are grouped by speaker under "Me" (teal) or "Them" (amber) with
  the time they started. Text still being recognised is dimmed until it settles. The
  transcript follows the newest line; scroll up to read back and it stays where you
  are, with a **Jump to latest** button to return.
- **After Stop.** A card shows the call being saved and summarised, then "Call saved"
  with its length, turns and cost, and **Open Summary** and **Show in Finder**.
- **Footer.** The call's running cost (hover for the split between speech-to-text and
  Claude), the first-word time of the last answer, and the answer hotkeys.

The window follows Light and Dark Mode. With Reduce Motion on, the dot and the answer
placeholder stay still and cards appear without sliding; with Reduce Transparency the
background is solid.

### Menu bar

The icon becomes a red capsule while Listener is listening. Its menu shows whether
Listener is listening and for how long, then Start/Stop Listening, Quick Answer and Deep
Answer with their hotkeys, Show Window, Open Last Summary (after a call), Open Sessions
Folder, Open Settings File and Quit Listener. Quitting during a call stops and saves it first, and so does `kill` or
Ctrl-C in the terminal that started the app (press Ctrl-C twice to quit without waiting).

## Hotkeys

| Action | Default |
| --- | --- |
| Quick answer (Haiku 5.5) | Control-Option-Space (`ctrl+option+space`) |
| Deep answer (Sonnet 5.5) | Control-Option-Shift-Space (`ctrl+option+shift+space`) |
| Start or stop listening | Control-Option-L (`ctrl+option+l`) |

Change them in `settings.json` under `hotkeys`, then restart Listener. A hotkey is
modifiers and one key joined by `+`:

- Modifiers: `ctrl`, `option` (or `alt`), `shift`, `cmd`.
- Keys: `a` to `z`, `0` to `9`, `space`, `return`, `tab`, `escape`, `f1` to `f12`, and
  `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backslash`,
  `leftbracket`, `rightbracket`, `grave`.
- Every hotkey needs `ctrl`, `option` or `cmd`, except function keys. macOS 15 ignores
  hotkeys that use only `option` or `option+shift`, so Listener refuses those.

If another app already owns a combination, the window says so and that hotkey is left
out; the menu still works.

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
| q, then Enter | Stop and save |
| Ctrl-C | Stop and save. Press it again to quit without waiting. |

The answer streams below the transcript, followed by its first-token time and cost.
Capture restarts (for example after switching headsets) and on-device model downloads
show as dimmed lines.

## Replay

Replay plays two recordings through exactly the same pipeline as a live call. It is how
to try the app without a call, compare settings, and measure latency.

```sh
listener replay me.wav them.wav
listener replay me.wav them.wav --script call.json --speed 4
listener replay me.wav them.wav --ask-at 12.5,30,1:05 --tier quick
```

- The recordings are 16-bit PCM WAV files, such as the `me.wav` and `them.wav` that the
  spike or `storage.saveAudio` write.
- `--script call.json` takes the words from a script instead of Google, so no
  speech-to-text account or network is needed for the transcript. The format:

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
  minutes:seconds), as if you had pressed the hotkey. `--tier deep` uses the deep model.
  At the end a table shows, per answer, the time from the end of speech and from the
  hotkey to the first token and to the end, the cost, and the medians against the 1.5 s
  target.

Replays are saved like any other call.

## Saved calls

Each call is saved in its own folder under
`~/Library/Application Support/Listener/sessions/` (or `storage.directory`):

| File | Contents |
| --- | --- |
| `transcript.jsonl` | One settled turn per line |
| `session.json` | Settings used, answers with their latency and cost, total cost |
| `summary.md` | Summary and action items, written when the call stops |
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
| `speech` | Provider (`google`, `apple` for on-device on macOS 26, or `fake` for scripted replays), Google project, location, endpoint, model (`chirp_3`), language (`en-GB`), endpointing sensitivity, credentials file, stream rotation, silence skipping |
| `turns` | When a pause ends a turn: `silenceMs`, the voice activity threshold, minimum speech length |
| `answers` | The `quick` and `deep` models (model, effort, thinking, max tokens), transcript budget, and `context`: who you are and what your calls are about |
| `summary` | Whether to write a summary, and its model |
| `capture` | System audio backend (`tap` or `sck`), echo cancellation for calls on speakers |
| `storage` | Sessions folder, retention in days, whether to keep the audio |
| `hotkeys` | The three hotkeys |
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

After a rebuild with an ad hoc signature, macOS may ask whether Listener can read its
Keychain item. Choose Always Allow, or sign with a stable identity (README).

## Where files go

| Path | What |
| --- | --- |
| `~/Library/Application Support/Listener/settings.json` | Settings |
| `~/Library/Application Support/Listener/.env` | Optional API keys |
| `~/Library/Application Support/Listener/sessions/` | Saved calls |
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
- **"Me" picks up the other side.** You are on speakers. Use headphones, or set
  `capture.voiceProcessing` to `true`.
- **No microphone with the lid closed.** The built-in mics are off in clamshell mode;
  plug in a headset or USB mic.
- **A hotkey does nothing.** The window lists hotkeys that could not be registered.
  Pick another combination in `hotkeys`. macOS's own shortcuts win without telling
  Listener: Control-Option-Space is also "Select next source in Input menu" under System
  Settings > Keyboard > Keyboard Shortcuts > Input Sources. Turn that off, or choose
  another hotkey.
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
