# Replay fixtures

Three short mock broker calls for replay mode and the end-to-end tests. Each directory
holds the two channels exactly as the capture layer would deliver them, plus the script
they were generated from.

Everything in them is invented. Pelican is real only as the user's employer; the broker
firms, people, account numbers, ticket references and figures are fictional.

## The calls

| Directory | Length | Broker | What "Them" asks |
| --- | --- | --- | --- |
| `delayed-executions` | 64.1 s, 16 lines | Hannah, Kestrelmoor Markets | Why copy trades hit followers up to 30 s late after the US open, whether it is fixed, whether it will happen again, **which accounts were affected and by how much**, **whether Pelican will cover the slippage**, the incident reference |
| `leverage-mirroring` | 61.1 s, 14 lines | Isla, Fernhall Securities | Why follower FR-720418 stopped mirroring after a 30:1 to 10:1 leverage change, why it doesn't just scale down, **whether the account is on fixed lot or proportional**, whether the missed trades will still open |
| `rate-limits-maintenance` | 54.8 s, 13 lines | Ruth, Brackenfield Markets | The rate limit behind their 429s, **which of their keys makes the most calls**, what Saturday's GCP maintenance changes and whether copy trading is affected, what happens if it goes wrong |

Questions in bold can't be answered from anything said in the call, so they test the
"don't invent call-specific facts" rule: a good suggestion says the user will check, not
a made-up number. In each case the recorded "Me" reply does exactly that.

Each call also has a lexical backchannel from "Them" in the middle of a "Me" turn
("Right.", "Yeah."), a filler or two ("um", "er"), a longer pause (0.9 to 1.2 s) before
"Me" answers the harder questions, where you would press the hotkey, and the first and
last calls end with a 0.2 to 0.25 s overlap.

## Format

- `me.wav` is the mic channel, `them.wav` the system audio. 16 kHz, mono, 16-bit PCM, and
  both files in a call have exactly the same number of samples.
- Each channel holds only its own speaker's lines. Everywhere else is Gaussian noise at
  -70 dBFS RMS, so it is never pure digital silence.
- Every "Me" line is at -21 dBFS RMS and every "Them" line at -23 dBFS RMS, measured over
  the line's span. Peaks stay below -2.5 dBFS. (dBFS here is `20 * log10(rms / 32768)`.)
- `script.json` is a `ConversationScript`: a title and lines (`speaker` "Me" or "Them",
  `start`, `end` in seconds, `text`), sorted by start time. Times are exact sample
  positions to the millisecond: each span starts about 20 ms before the first 10 ms frame
  louder than -50 dBFS and ends about 30 ms after the last one, so the span is where the
  speech is. A backchannel's span lies inside the other speaker's line.
- `text` is written the way a good transcript would show it (`INC-4471`, `FR-720418`,
  `30:1`, `429s`). The voice was given a spoken form where that differs.

## Replay

```sh
listener replay Fixtures/delayed-executions/me.wav Fixtures/delayed-executions/them.wav \
    --script Fixtures/delayed-executions/script.json
```

The same pattern works for `leverage-mirroring` and `rate-limits-maintenance`.

## Voices and licences

Generated offline with [Piper](https://github.com/OHF-Voice/piper1-gpl) (`piper-tts`
1.8.0, GPL-3.0-or-later, used as a tool only, nothing of it ships with Listener) and
voices from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) at
revision `b1cb611`. The repository is MIT licensed; the licence that matters for each
voice is that of the data it was trained on, from its model card:

| Role | Voice | Training data and licence |
| --- | --- | --- |
| "Me" in all calls | `en_GB-vctk-medium`, speaker p259 (male), speed 0.95 | [CSTR VCTK Corpus 0.92](https://hdl.handle.net/10283/3443), University of Edinburgh, CC BY 4.0 |
| "Them", `delayed-executions` | `en_GB-cori-high` (female) | LibriVox recordings, public domain; trained from scratch |
| "Them", `leverage-mirroring` | `en_GB-alba-medium` (female, Scottish) | [Alba speech corpus](https://hdl.handle.net/10283/3270), University of Edinburgh, CC BY 4.0 |
| "Them", `rate-limits-maintenance` | `en_GB-vctk-medium`, speaker p276 (female), speed 0.9 | CSTR VCTK Corpus 0.92, CC BY 4.0 |

Attribution for the CC BY 4.0 data: "CSTR VCTK Corpus: English Multi-speaker Corpus for
CSTR Voice Cloning Toolkit (version 0.92)" by Junichi Yamagishi, Christophe Veaux and
Kirsten MacDonald, and "Alba speech corpus" by Cassia Valentini-Botinhao and Junichi
Yamagishi, both University of Edinburgh.

One caveat: the vctk and alba voices were fine-tuned from Piper's `en_US-lessac-medium`,
which was trained on the Blizzard Challenge 2013 Lessac data, released under a research
licence. That is fine for internal test fixtures, but don't reuse these recordings in
anything that ships or is published. `cori-high` has no such dependency.

## Regenerating

Everything comes from the call scripts in `scripts/make-fixtures.py`. Edit a line there
and run:

```sh
python3 -m venv .venv          # Python 3.12 or later
.venv/bin/pip install -r scripts/make-fixtures-requirements.txt
.venv/bin/python scripts/make-fixtures.py                     # every call
.venv/bin/python scripts/make-fixtures.py leverage-mirroring  # or just one
```

The first run downloads the three voice models (about 255 MB) to
`~/.cache/listener/piper-voices` and checks their MD5 sums. Rendering then takes about
30 seconds on four cores. Piper's random noise is seeded and so are the gaps and the
noise floor, so a rerun on the same machine gives byte-identical files. Another CPU or
onnxruntime build can change the audio in the last bits and move times by a few
milliseconds; `script.json` always matches the audio written with it.

In the script, a line's `gap` overrides the pause before it (negative overlaps the
previous line), `after_sentence` turns it into a backchannel spoken after that sentence of
the previous line, and `say` gives the spoken form when it differs from `text`.

Every run ends with a check, which `--check` runs on its own against the files on disk
(it needs only numpy). It prints a row per line and fails on any problem: wrong format,
channel lengths that differ, a noise floor off -70 dBFS, sound outside a speaker's own
lines, a line level outside -25 to -20 dBFS or peaking above -1 dBFS, a span more than
60 ms looser than its speech, the other channel not quiet during a line (apart from the
other speaker's own overlapping lines), or a gap between turns outside -0.3 to 1.2 s.

## Limitations

- Piper can't say "mm-hm". A dozen phoneme spellings all came out as something else
  (Whisper heard "I'm home", "Amen", "Mum"), so the backchannels are real words.
- Synthetic speech is cleaner than a call: no codec artefacts, room sound, crosstalk or
  level drift. Whisper small.en gets 3.9% WER on these lines; most of its errors are names
  and trade jargon ("Isla", "fixed lot"), the same words a real recogniser will find hard.
  Recordings of real calls (with `save_audio` on) should join these once M1 can make them.
