#!/usr/bin/env python3
"""Regenerate the replay fixtures in Fixtures/ from the call scripts in this file.

Each call becomes Fixtures/<name>/me.wav, them.wav and script.json. The WAV files are
16 kHz mono 16-bit PCM of identical length. Each holds only its speaker's lines, at the
times script.json gives, over a -70 dBFS noise floor.

    python3 -m venv .venv    # Python 3.12 or later
    .venv/bin/pip install -r scripts/make-fixtures-requirements.txt
    .venv/bin/python scripts/make-fixtures.py           # synthesise and check every call
    .venv/bin/python scripts/make-fixtures.py --check   # only check the files on disk

Voices are downloaded once into ~/.cache/listener/piper-voices (see --voices-dir).
Levels are dBFS relative to a full-scale square wave: 20 * log10(rms / 32768).
"""

import argparse
import hashlib
import json
import random
import sys
import urllib.request
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000
SAMPLES_PER_MS = SAMPLE_RATE // 1000
FRAME = SAMPLE_RATE // 100

LEAD_IN = 0.8
TAIL = 1.0
SENTENCE_PAUSE = 0.25
BACKCHANNEL_DELAY = 0.05
LEVEL_DBFS = {"Me": -21.0, "Them": -23.0}
NOISE_DBFS = -70.0
# 10 ms frames quieter than this count as silence when trimming lines and checking spans.
SPEECH_DBFS = -50.0

VOICES_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/b1cb611417f8c6d0841becaa6c876255d9f4617c/en/en_GB"
ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Voice:
    model: str
    md5: str
    speaker: str | None = None
    length_scale: float | None = None


VCTK = ("vctk/medium/en_GB-vctk-medium", "573025290fdc68812543b7438ace0c29")
VOICES = {
    "vctk-p259": Voice(*VCTK, speaker="p259", length_scale=0.95),
    "vctk-p276": Voice(*VCTK, speaker="p276", length_scale=0.9),
    "cori": Voice("cori/high/en_GB-cori-high", "3474a80133d9a03e6870d2ac42c18806"),
    "alba": Voice("alba/medium/en_GB-alba-medium", "c07f313752bb3aba8061041666251654"),
}


@dataclass(frozen=True)
class Line:
    speaker: str
    text: str
    say: str | None = None
    gap: float | None = None
    after_sentence: int | None = None


def me(text: str, **options) -> Line:
    return Line("Me", text, **options)


def them(text: str, **options) -> Line:
    return Line("Them", text, **options)


@dataclass(frozen=True)
class Call:
    name: str
    title: str
    voices: dict[str, str]
    lines: list[Line]


# `gap` is the silence before a line, measured from the end of the previous one; a
# negative gap overlaps it. Without one, a natural gap is drawn from a seeded generator.
# `after_sentence` makes a backchannel, said in the pause after that sentence of the
# previous line.
# `say` is what the voice reads when the transcript spelling would be read wrongly.
CALLS = [
    Call(
        name="delayed-executions",
        title="Kestrelmoor Markets: delayed copy-trade executions at the US open",
        voices={"Me": "vctk-p259", "Them": "cori"},
        lines=[
            them("Hi, it's Hannah at Kestrelmoor Markets. We've had a flood of complaints since the US open."),
            me("Hi Hannah, go ahead."),
            them("From half two, copy trades were reaching our followers late, some by thirty seconds. What happened?"),
            me(
                "We saw it too. Volume at the open hit six times normal. That backed up our follower order queue.",
                gap=0.9,
            ),
            them("Right.", after_sentence=2),
            them("Is it fixed now?"),
            me("Yes, we scaled out the workers at two forty. Delays have been under a second since."),
            them("Will it happen again tomorrow?"),
            me("We're adding extra workers before the open, so it shouldn't."),
            them("Which of our accounts were affected, and by how much? Compliance want numbers today."),
            me("Um, I don't have the account list to hand. I'll pull it and send it over this afternoon.", gap=1.1),
            them("And, er, will Pelican cover the slippage on the late fills?"),
            me(
                "That's not my call, I'm afraid. I'll check with client services. "
                "You'll get an incident report within five working days.",
                gap=1.0,
            ),
            them("Fine, what's the incident reference?"),
            me(
                "It's INC-4471. I'll email it over now.",
                say="It's I N C, four four seven one. I'll email it over now.",
            ),
            them("Great, thanks.", gap=-0.25),
        ],
    ),
    Call(
        name="leverage-mirroring",
        title="Fernhall Securities: follower stopped mirroring after a leverage change",
        voices={"Me": "vctk-p259", "Them": "alba"},
        lines=[
            them(
                "Morning, it's Isla at Fernhall Securities. One of our follower accounts has stopped copying, "
                "and I can't see why."
            ),
            me("Morning Isla. Which account?"),
            them(
                "It's FR-720418. The client dropped their leverage from 30:1 to 10:1 yesterday, "
                "and nothing's mirrored since.",
                say="It's F R, seven two zero, four one eight. The client dropped their leverage "
                "from thirty to one, to ten to one yesterday, and nothing's mirrored since.",
            ),
            me(
                "Right, with lower leverage, every trade we copy needs more margin. "
                "If there isn't enough free margin, we skip the trade rather than open a smaller one.",
                gap=1.0,
            ),
            them("Yeah.", after_sentence=1),
            them("But they've got plenty in the account. Shouldn't it just scale down?"),
            me("It depends on the copy mode. In proportional mode it scales down, in fixed lot mode it doesn't."),
            them("So is this account on fixed lot or proportional?"),
            me("I can't see that from here, I'd have to check the account settings.", gap=1.2),
            them("And the trades it missed, will they still open?"),
            me("Er, no, I'm afraid not. Once the margin check passes, it'll only copy new trades from the leader."),
            them("Okay, can you check the settings and get back to me this afternoon?"),
            me("Yep, I'll email you by three."),
            them("Cheers."),
        ],
    ),
    Call(
        name="rate-limits-maintenance",
        title="Brackenfield Markets: API rate limits and the planned GCP maintenance window",
        voices={"Me": "vctk-p259", "Them": "vctk-p276"},
        lines=[
            them("Hi, it's Ruth from integrations at Brackenfield Markets. Two quick ones for you."),
            me("Sure, fire away."),
            them(
                "Since Monday we've been getting 429s on the positions endpoint. What's the rate limit now?",
                say="Since Monday we've been getting four twenty-nines on the positions endpoint. "
                "What's the rate limit now?",
            ),
            me(
                "It's per API key. A hundred requests per ten seconds, with bursts up to two hundred. "
                "That hasn't changed.",
                gap=0.9,
            ),
            them("Odd, we never used to hit it. Can you see which key is making the most calls?"),
            me("Not from here, no. I'll pull the gateway logs and send you a breakdown by key.", gap=1.1),
            them("Thanks for that. What about Saturday's maintenance? Is copy trading affected?"),
            me(
                "It's a database upgrade on our Google Cloud side, six till eight a.m. UK time. "
                "Markets are shut, so copy trading isn't affected, but the API is read-only for about twenty minutes.",
                gap=0.9,
            ),
            them("Right.", after_sentence=1),
            them("And if it goes wrong?"),
            me(
                "We've rehearsed the rollback. Um, if it's not done by half seven, "
                "we roll back and try again next weekend."
            ),
            them("Perfect, thanks."),
            me("Cheers, bye.", gap=-0.2),
        ],
    ),
]


def dbfs(samples: np.ndarray) -> float:
    rms = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
    return 20 * np.log10(max(rms, 1e-9) / 32768)


def frame_dbfs(samples: np.ndarray) -> np.ndarray:
    count = len(samples) // FRAME
    frames = samples[: count * FRAME].astype(np.float64).reshape(count, FRAME)
    return 20 * np.log10(np.maximum(np.sqrt(np.mean(frames**2, axis=1)), 1e-9) / 32768)


def speech_bounds(samples: np.ndarray, threshold: float) -> tuple[int, int]:
    active = np.flatnonzero(frame_dbfs(samples) > threshold)
    return active[0] * FRAME, (active[-1] + 1) * FRAME


def at_level(samples: np.ndarray, level: float) -> np.ndarray:
    return samples * 10 ** ((level - dbfs(samples)) / 20)


def faded(samples: np.ndarray) -> np.ndarray:
    ramp = np.sin(np.linspace(0, np.pi / 2, 5 * SAMPLES_PER_MS)) ** 2
    samples = samples.copy()
    samples[: len(ramp)] *= ramp
    samples[-len(ramp) :] *= ramp[::-1]
    return samples


def md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download_voice(voice: Voice, voices_dir: Path) -> Path:
    voices_dir.mkdir(parents=True, exist_ok=True)
    onnx = voices_dir / f"{Path(voice.model).name}.onnx"
    config = onnx.with_suffix(".onnx.json")
    if not onnx.exists() or md5(onnx) != voice.md5:
        print(f"downloading {onnx.name}", file=sys.stderr)
        urllib.request.urlretrieve(f"{VOICES_URL}/{voice.model}.onnx", onnx)
        if md5(onnx) != voice.md5:
            sys.exit(f"{onnx.name}: checksum mismatch")
    if not config.exists():
        urllib.request.urlretrieve(f"{VOICES_URL}/{voice.model}.onnx.json", config)
    return onnx


@dataclass(frozen=True)
class Clip:
    samples: np.ndarray
    sentence_ends: list[int]


class Synthesiser:
    def __init__(self, voice: Voice, voices_dir: Path, seed: int):
        # Imported here so that --check needs nothing but numpy.
        import onnxruntime
        from piper import PiperVoice, SynthesisConfig

        # Piper's noise comes from random ops inside the ONNX graph. They take their seed
        # from the runtime when the session is built, so seeding first makes output repeatable.
        onnxruntime.set_seed(seed)
        self.piper = PiperVoice.load(download_voice(voice, voices_dir))
        speaker_id = self.piper.config.speaker_id_map[voice.speaker] if voice.speaker else None
        self.config = SynthesisConfig(speaker_id=speaker_id, length_scale=voice.length_scale)

    def speak(self, text: str, level: float) -> Clip:
        """Returns the line at `level` dBFS RMS, trimmed to its speech and a whole number of ms long."""
        import soxr

        pause = np.zeros(round(SENTENCE_PAUSE * SAMPLE_RATE))
        parts, sentence_ends, length = [], [], 0
        for chunk in self.piper.synthesize(text, self.config):
            sentence = soxr.resample(chunk.audio_float_array, chunk.sample_rate, SAMPLE_RATE, quality="VHQ")
            sentence = sentence.astype(np.float64) * 32768
            start, end = speech_bounds(sentence, frame_dbfs(sentence).max() - 40)
            parts += [faded(sentence[start:end]), pause]
            sentence_ends.append(length + end - start)
            length += end - start + len(pause)
        audio = at_level(np.concatenate(parts[:-1]), level)

        start, end = speech_bounds(audio, SPEECH_DBFS)
        start = max(0, start - 2 * FRAME)
        end += 3 * FRAME
        end += -(end - start) % SAMPLES_PER_MS
        audio = faded(np.pad(audio, (0, max(0, end - len(audio))))[start:end])
        return Clip(at_level(audio, level), [offset - start for offset in sentence_ends])


def stable_seed(*parts: str) -> int:
    return int(hashlib.sha256("/".join(parts).encode()).hexdigest()[:8], 16)


def natural_gap(rng: random.Random, speaker: str, previous: str) -> float:
    if speaker == previous:
        return rng.uniform(0.3, 0.5)
    return rng.uniform(0.5, 0.9) if speaker == "Me" else rng.uniform(0.35, 0.7)


def whole_ms(seconds: float) -> int:
    return round(seconds * 1000) * SAMPLES_PER_MS


def lay_out(call: Call, clips: dict[int, Clip]) -> tuple[list[tuple[int, int]], int]:
    """Returns (start sample, line index) for every line, and where the last line ends."""
    rng = random.Random(call.name)
    placed = []
    cursor = whole_ms(LEAD_IN)
    turn = None
    for index, line in enumerate(call.lines):
        length = len(clips[index].samples)
        if line.after_sentence is not None:
            turn_start, turn_index = turn
            sentence_end = clips[turn_index].sentence_ends[line.after_sentence - 1]
            start = turn_start + whole_ms(sentence_end / SAMPLE_RATE + BACKCHANNEL_DELAY)
            if start + length > turn_start + len(clips[turn_index].samples):
                sys.exit(f"{call.name}: backchannel {line.text!r} runs past the line it interrupts")
        else:
            if turn is not None:
                previous = call.lines[turn[1]].speaker
                gap = line.gap if line.gap is not None else natural_gap(rng, line.speaker, previous)
                cursor += whole_ms(gap)
            start = cursor
            turn = (start, index)
        cursor = max(cursor, start + length)
        placed.append((start, index))
    return sorted(placed), cursor


def write_wav(path: Path, samples: np.ndarray) -> None:
    pcm = np.clip(np.round(samples), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(SAMPLE_RATE)
        file.writeframes(pcm.tobytes())


def render(call: Call, voices_dir: Path, out_dir: Path) -> None:
    clips = {}
    for speaker, voice_name in call.voices.items():
        synthesiser = Synthesiser(VOICES[voice_name], voices_dir, stable_seed(call.name, speaker))
        for index, line in enumerate(call.lines):
            if line.speaker == speaker:
                clips[index] = synthesiser.speak(line.say or line.text, LEVEL_DBFS[speaker])

    placed, end = lay_out(call, clips)
    length = end + round(TAIL * SAMPLE_RATE)
    noise_rms = 32768 * 10 ** (NOISE_DBFS / 20)
    out_dir.mkdir(parents=True, exist_ok=True)
    for speaker in ("Me", "Them"):
        channel = np.zeros(length)
        for start, index in placed:
            if call.lines[index].speaker == speaker:
                region = channel[start : start + len(clips[index].samples)]
                if region.any():
                    sys.exit(f"{call.name}: two {speaker} lines overlap at {start / SAMPLE_RATE:.3f}s")
                region += clips[index].samples
        channel += np.random.default_rng(stable_seed(call.name, speaker, "noise")).normal(0, noise_rms, length)
        write_wav(out_dir / f"{speaker.lower()}.wav", channel)

    lines = [
        {
            "speaker": call.lines[index].speaker,
            "start": start / SAMPLE_RATE,
            "end": (start + len(clips[index].samples)) / SAMPLE_RATE,
            "text": call.lines[index].text,
        }
        for start, index in placed
    ]
    script = json.dumps({"title": call.title, "lines": lines}, indent=2, ensure_ascii=False)
    (out_dir / "script.json").write_text(script + "\n")


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as file:
        layout = (file.getnchannels(), file.getsampwidth(), file.getframerate(), file.getcomptype())
        if layout != (1, 2, SAMPLE_RATE, "NONE"):
            raise ValueError(f"{path}: expected 16 kHz mono 16-bit PCM, got {layout}")
        return np.frombuffer(file.readframes(file.getnframes()), "<i2").astype(np.float64)


def check(call_dir: Path) -> list[str]:
    """Prints per-line measurements for one fixture and returns the problems found."""
    try:
        channels = {speaker: read_wav(call_dir / f"{speaker.lower()}.wav") for speaker in ("Me", "Them")}
    except (ValueError, wave.Error) as error:
        return [str(error)]
    problems = []
    script = json.loads((call_dir / "script.json").read_text())
    lines = script["lines"]
    length = len(channels["Me"])
    if len(channels["Them"]) != length:
        problems.append(f"channel lengths differ: {length} and {len(channels['Them'])} samples")
    duration = length / SAMPLE_RATE
    print(f"\n{call_dir.name}: {duration:.3f}s, {len(lines)} lines, {script['title']}")

    def frames(start: float, end: float) -> slice:
        return slice(int(start * 100), int(np.ceil(end * 100)))

    levels = {speaker: frame_dbfs(samples) for speaker, samples in channels.items()}
    inside = {speaker: np.zeros(len(levels[speaker]), bool) for speaker in channels}
    for line in lines:
        inside[line["speaker"]][frames(line["start"], line["end"])] = True
    for speaker, level in levels.items():
        outside = level[~inside[speaker]]
        floor = 10 * np.log10(np.mean(10 ** (outside / 10)))
        print(f"  {speaker:4} noise floor {floor:.1f} dBFS, loudest 10 ms outside its lines {outside.max():.1f} dBFS")
        if abs(floor - NOISE_DBFS) > 1:
            problems.append(f"{speaker} noise floor is {floor:.1f} dBFS")
        if outside.max() > NOISE_DBFS + 6:
            problems.append(f"{speaker} has sound outside its lines ({outside.max():.1f} dBFS)")

    if [line["start"] for line in lines] != sorted(line["start"] for line in lines):
        problems.append("lines are not in order of start time")
    latest_end = None
    for number, line in enumerate(lines, 1):
        speaker, start, end = line["speaker"], line["start"], line["end"]
        other = "Them" if speaker == "Me" else "Me"
        if speaker not in channels or not line["text"].strip():
            problems.append(f"line {number} has speaker {speaker!r} or no text")
            continue
        if not 0 <= start < end <= duration:
            problems.append(f"line {number} lies outside the recording")
            continue
        samples = channels[speaker][round(start * SAMPLE_RATE) : round(end * SAMPLE_RATE)]
        speech = np.flatnonzero(frame_dbfs(samples) > SPEECH_DBFS)
        lead = speech[0] / 100 if len(speech) else end - start
        trail = end - start - (speech[-1] + 1) / 100 if len(speech) else end - start
        level = dbfs(samples)
        peak = 20 * np.log10(np.abs(samples).max() / 32768)
        overlap = sum(max(0.0, min(end, o["end"]) - max(start, o["start"])) for o in lines if o["speaker"] == other)
        others = levels[other][frames(start, end)][~inside[other][frames(start, end)]]
        quiet = others.max() if len(others) else float("-inf")
        backchannel = any(o["start"] <= start and end <= o["end"] for o in lines if o["speaker"] == other)
        gap = None if latest_end is None or backchannel else round(start - latest_end, 3)
        if gap is not None and not -0.3 <= gap <= 1.2:
            problems.append(f"line {number} follows a gap of {gap:.2f}s")
        latest_end = end if latest_end is None else max(latest_end, end)
        shown = "" if gap is None else f"{gap:+.2f}s"
        print(
            f"  {number:2} {speaker:4} {start:7.3f} {end:7.3f}  gap {shown:>6}  rms {level:5.1f}  peak {peak:5.1f}  "
            f"speech {len(speech) / ((end - start) * 100):4.0%}  edges {lead:.2f}/{trail:.2f}s  "
            f"{other} {quiet:5.1f}" + (f"  overlap {overlap:.2f}s" if overlap else "")
        )
        if not -25 <= level <= -20:
            problems.append(f"line {number} level is {level:.1f} dBFS")
        if peak > -1:
            problems.append(f"line {number} peaks at {peak:.1f} dBFS")
        if lead > 0.06 or trail > 0.06:
            problems.append(f"line {number} span is loose: speech starts {lead:.2f}s in, ends {trail:.2f}s early")
        if quiet > NOISE_DBFS + 6:
            problems.append(f"line {number}: {other} is not quiet outside its own lines ({quiet:.1f} dBFS)")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("calls", nargs="*", help="names of the calls to build (default: all)")
    parser.add_argument("--check", action="store_true", help="only check the fixtures already on disk")
    parser.add_argument("--voices-dir", type=Path, default=Path.home() / ".cache/listener/piper-voices")
    parser.add_argument("--out", type=Path, default=ROOT / "Fixtures")
    args = parser.parse_args()

    calls = [call for call in CALLS if not args.calls or call.name in args.calls]
    problems = []
    for call in calls:
        if not args.check:
            print(f"rendering {call.name}", file=sys.stderr)
            render(call, args.voices_dir, args.out / call.name)
        problems += [f"{call.name}: {problem}" for problem in check(args.out / call.name)]

    size = sum(path.stat().st_size for call in calls for path in (args.out / call.name).iterdir())
    print(f"\n{len(calls)} calls, {size / 1e6:.2f} MB")
    if problems:
        sys.exit("\n".join(["", *problems]))


if __name__ == "__main__":
    main()
