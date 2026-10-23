# Speech Bench

Compares speech-to-text engines on one side of a recorded call, all on this Mac. It is a
separate package so the app and its build stay free of the models' dependencies until
one of them earns a place.

```sh
cd Tools/SpeechBench
swift build -c release
.build/release/SpeechBench ~/Library/Application\ Support/Listener/sessions/<call>/them.wav
```

It cuts the recording into the segments a live call would produce, using Listener's own
voice detector and pause length (`turns` in settings.json), and gives every engine the
same segments one at a time. For each engine it reports:

- **Words** and **words per minute of speech**: an engine that misses speech catches
  fewer.
- **Repeats**: words said twice in a row, the "to, to, to" loops of a struggling model.
- **WER**, with `--reference what-was-said.txt`: the word error rate against what was
  actually said. Type out a few minutes and test just that stretch with `--start` and
  `--duration`.
- **Speed** and **segment times**: the segment time is how long after a speaker pauses
  the words would appear live, on top of the pause itself.
- How far apart the engines are from each other, which says something even without a
  reference: engines that agree are more likely to be right than one that disagrees
  with all of them.

It also reports the recording's levels. When even its quiet parts are louder than the
speech threshold, Listener never sees a pause on that channel, which is worth knowing
before blaming the model.

The report goes to `speech-bench/` next to the recording: `report.html` with the
transcripts side by side, one `.txt` per engine and `results.json`. It holds what was
said on the call, so it lives and expires with the call's own folder.

## Engines

| Name | Model | Download |
| --- | --- | --- |
| `apple-<locale>` | Apple's on-device SpeechTranscriber, what Listener uses today | Installed by macOS |
| `whisper-turbo` | Whisper large-v3 turbo, through WhisperKit | About 1.5 GB |
| `whisper-large-v3` | Whisper large-v3, the full model | About 3 GB |
| `parakeet-v2` | NVIDIA Parakeet TDT 0.6B v2, English only, through FluidAudio | About 0.5 GB |
| `parakeet-v3` | Parakeet TDT 0.6B v3, 25 languages | About 0.5 GB |
| `parakeet-ultra` | Parakeet Ultra, a post-trained v3 | About 0.6 GB |

The open models download once into `~/Library/Application Support/Listener/Models/`.
Delete that folder to get the space back.
