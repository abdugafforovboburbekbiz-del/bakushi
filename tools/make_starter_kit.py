"""Synthesize the Bakushi starter kit (ORIGINAL sounds, made for this app).

Generates 8 one-shot drums + 3 tempo-matched loops (90/100/120 BPM) as
16-bit stereo 44.1 kHz WAVs into assets/starter_kit/. Everything is
synthesized with numpy - no samples, no downloads, no licensing risk.
All sounds share one tuning/feel so any combination sounds musical
(the Incredibox lesson).

Usage: python tools/make_starter_kit.py
"""
import os
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "starter_kit")
RNG = np.random.default_rng(7)


def _t(dur):
    n = int(dur * SR)
    return np.arange(n) / SR, n


def _decay(n, tau):
    return np.exp(-np.arange(n) / (tau * SR))


def _soft(x):
    return np.tanh(x * 1.4) / np.tanh(1.4)


def _norm(x, peak=0.85):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 1e-9 else x


def _noise(n):
    return RNG.standard_normal(n)


def kick():
    """55 Hz tuned kick: 150->42 Hz sweep, punchy exp decay, soft click."""
    t, n = _t(0.42)
    freq = 150.0 * np.exp(-t * 13.0) + 42.0
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    x = np.sin(phase) * np.exp(-t * 9.0)
    click_n = int(0.002 * SR)
    click = _noise(click_n) * np.exp(-np.arange(click_n) / (0.00045 * SR))
    x[:click_n] += 0.35 * click
    return _norm(_soft(x))


def snare():
    """Snare: 190 Hz tone + bright noise, snappy 0.18 s decay."""
    t, n = _t(0.22)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 22)
    noise = _noise(n) * np.exp(-t * 18)
    # crude highpass via differencing -> brighter noise
    noise = np.diff(noise, prepend=noise[0])
    x = 0.7 * tone + 0.9 * noise
    return _norm(_soft(x))


def closed_hat():
    """Closed hat: very bright short noise, 0.06 s."""
    t, n = _t(0.07)
    x = _noise(n) * np.exp(-t * 55)
    x = np.diff(x, prepend=x[0])
    return _norm(x * 0.5)


def open_hat():
    """Open hat: bright noise with a 0.35 s tail."""
    t, n = _t(0.40)
    x = _noise(n) * np.exp(-t * 8.5)
    x = np.diff(x, prepend=x[0])
    return _norm(x * 0.5)


def clap():
    """Clap: three staggered noise bursts (8 ms apart), 0.25 s body."""
    t, n = _t(0.28)
    x = _noise(n) * np.exp(-t * 13)
    x = np.diff(x, prepend=x[0])
    for gap in (0.008, 0.016):
        off = int(gap * SR)
        x[off:] += 0.6 * x[: n - off] * 0.8
    return _norm(x * 0.55)


def rimshot():
    """Rimshot: short 1.8 kHz ping + click."""
    t, n = _t(0.09)
    ping = np.sin(2 * np.pi * 1800 * t) * np.exp(-t * 40)
    click = _noise(n) * np.exp(-t * 300)
    return _norm(ping * 0.8 + click * 0.35)


def perc():
    """Tuned tom: 220 -> 150 Hz sweep, 0.28 s."""
    t, n = _t(0.30)
    freq = 220.0 - 70.0 * (1.0 - np.exp(-t * 16.0))
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    x = np.sin(phase) * np.exp(-t * 10.0)
    return _norm(_soft(x))


def shaker():
    """Shaker: modulated bright noise (8 Hz pulse train), 0.5 s."""
    t, n = _t(0.5)
    carrier = _noise(n)
    carrier = np.diff(carrier, prepend=carrier[0])
    # 8th-note-ish pulses at 120 BPM = 4 Hz envelope
    pulse = 0.55 + 0.45 * np.sin(2 * np.pi * 4.0 * t)
    x = carrier * pulse * np.exp(-t * 5)
    return _norm(x * 0.5)


def _bar(bpm):
    return 4.0 * 60.0 / bpm


def loop(bpm):
    """2-bar boom-bap loop: kick on 1/3, snare on 2/4, 8th hats."""
    beat = 60.0 / bpm
    total = 2 * _bar(bpm)
    n = int(total * SR)
    l = np.zeros(n)
    r = np.zeros(n)

    def add(snd, at, pan=0.0):
        off = int(at * SR)
        k = min(len(snd), n - off)
        if k <= 0:
            return
        gl = np.cos((pan + 1) * np.pi / 4)
        gr = np.sin((pan + 1) * np.pi / 4)
        l[off:off + k] += snd[:k] * gl
        r[off:off + k] += snd[:k] * gr

    k = kick()
    s = snare()
    ch = closed_hat()
    oh = open_hat()
    sh = shaker()
    for bar in range(2):
        base = bar * _bar(bpm)
        add(k, base + 0 * beat, 0.0)          # kick on 1
        add(s, base + 1 * beat, -0.25)        # snare on 2
        add(k, base + 2 * beat, 0.0)          # kick on 3
        add(s, base + 3 * beat, -0.25)        # snare on 4
        for i in range(8):                    # 8th hats
            at = base + i * beat / 2
            add(ch if i % 2 == 0 else oh, at, 0.35)
        add(sh, base + 0.5 * beat, 0.15)
        add(sh, base + 2.5 * beat, 0.15)
    return _norm(_soft(l), 0.75), _norm(_soft(r), 0.75)


def _write(path, left, right):
    n = min(len(left), len(right))
    pcm = np.empty(2 * n, dtype=np.int16)
    pcm[0::2] = np.clip(left[:n] * 32767, -32768, 32767).astype(np.int16)
    pcm[1::2] = np.clip(right[:n] * 32767, -32768, 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print("wrote %s (%d frames, %.2f s)" % (path, n, n / SR))


def _mono_pair(x):
    return _norm(x), _norm(x)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in [
        ("kick", kick), ("snare", snare), ("closed_hat", closed_hat),
        ("open_hat", open_hat), ("clap", clap), ("rimshot", rimshot),
        ("perc", perc), ("shaker", shaker),
    ]:
        l, r = _mono_pair(fn())
        _write(os.path.join(OUT, name + ".wav"), l, r)
    for bpm in (90, 100, 120):
        l, r = loop(bpm)
        _write(os.path.join(OUT, "loop_%d.wav" % bpm), l, r)
    print("done")


if __name__ == "__main__":
    main()
