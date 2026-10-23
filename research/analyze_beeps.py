"""Offline tone candidates, not shot detection or verified timer synchronization.

Requires ffmpeg on PATH; uses only Python's standard library. Never plays audio.
Usage: python3 analyze_beeps.py VIDEO [VIDEO ...] > candidates.json
"""
import array
import json
import math
import subprocess
import sys

RATE = 16000
WINDOW = 320  # 20 ms
FREQUENCIES = range(1500, 5001, 100)


def tone_score(samples):
    energy = sum(x * x for x in samples)
    if not energy:
        return 0, 0, 0
    scores = []
    for frequency in FREQUENCIES:
        coefficient = 2 * math.cos(2 * math.pi * frequency / RATE)
        previous = older = 0.0
        for sample in samples:
            current = sample + coefficient * previous - older
            older, previous = previous, current
        power = previous * previous + older * older - coefficient * previous * older
        scores.append((2 * power / (len(samples) * energy), frequency))
    concentration, frequency = max(scores)
    return concentration, frequency, math.sqrt(energy / len(samples)) / 32768


def candidates(samples):
    groups = []
    active = []
    for offset in range(0, len(samples) - WINDOW + 1, WINDOW):
        concentration, frequency, rms = tone_score(samples[offset:offset + WINDOW])
        # shortcut: coarse single-tone filter, qualify on labelled range videos before production use.
        if concentration >= 0.32 and rms >= 0.004:
            if active and abs(active[-1][2] - frequency) > 200:
                groups.append(active)
                active = []
            active.append((offset / RATE, concentration, frequency, rms))
        elif active:
            groups.append(active)
            active = []
    if active:
        groups.append(active)
    return [dict(onset_seconds=round(g[0][0], 3), end_seconds=round(g[-1][0] + WINDOW / RATE, 3),
                 frequency_hz=sorted(x[2] for x in g)[len(g) // 2],
                 mean_tone_concentration=round(sum(x[1] for x in g) / len(g), 3),
                 confidence="unverified tonal candidate") for g in groups if len(g) >= 3]


def analyze(path):
    metadata = json.loads(subprocess.run([
        "ffprobe", "-v", "error", "-show_entries", "format=duration:stream=index,codec_type,start_time",
        "-of", "json", path], check=True, capture_output=True).stdout)
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(RATE),
                          "-f", "s16le", "-"], check=True, capture_output=True).stdout
    samples = array.array("h")
    samples.frombytes(pcm)
    if sys.byteorder != "little":
        samples.byteswap()
    return dict(file=path, metadata=metadata, candidates=candidates(samples),
                limitation="Times relative to decoded audio start; account for track start offset before mapping to video. No labelled ground truth.")


def self_check():
    tone = [int(12000 * math.sin(2 * math.pi * 3000 * n / RATE)) for n in range(1600)]
    result = candidates([0] * 1600 + tone + [0] * 1600)
    assert len(result) == 1 and result[0]["onset_seconds"] == 0.1
    assert result[0]["frequency_hz"] == 3000
    assert candidates([0] * 3200) == []


if __name__ == "__main__":
    self_check()
    if len(sys.argv) == 1:
        raise SystemExit("Usage: analyze_beeps.py VIDEO [VIDEO ...]")
    print(json.dumps([analyze(path) for path in sys.argv[1:]], ensure_ascii=False, indent=2))
