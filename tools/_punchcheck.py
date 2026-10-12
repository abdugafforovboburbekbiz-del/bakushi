"""Acceptance test for the drum punch DSP chain on the real hip-hop song.

- Copies the library drums stem to a temp dir, applies the punch chain,
- Reports RMS/peak/crest/LF-HF balance before and after,
- Verifies ZERO time shift (cross-correlation lag == 0),
- Writes A/B WAVs for listening: _punch_ab_before.wav / _punch_ab_after.wav.
"""
import os
import shutil
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "sidecar"))
import drum_punch  # noqa: E402


def read_stem(song_dir, name):
    l = np.fromfile(os.path.join(song_dir, "stems", "%s_l.f32le" % name),
                    dtype=np.float32)
    r = np.fromfile(os.path.join(song_dir, "stems", "%s_r.f32le" % name),
                    dtype=np.float32)
    return l, r


def stats(l, r):
    mono = ((l.astype(np.float64) + r.astype(np.float64)) * 0.5)
    rms = float(np.sqrt(np.mean(mono ** 2)))
    peak = float(np.max(np.abs(mono)))
    crest = 20.0 * np.log10(peak / rms + 1e-12)
    spec = np.abs(np.fft.rfft(mono)) ** 2
    freqs = np.fft.rfftfreq(mono.size, 1.0 / 44100.0)
    total = float(spec.sum()) + 1e-12
    lf = float(spec[(freqs >= 40) & (freqs <= 120)].sum()) / total
    snap = float(spec[(freqs >= 2000) & (freqs <= 4000)].sum()) / total
    return rms, peak, crest, lf, snap


def write_wav(path, l, r):
    data = np.empty(l.size * 2, dtype=np.int16)
    data[0::2] = np.clip(l * 32767, -32768, 32767)
    data[1::2] = np.clip(r * 32767, -32768, 32767)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(data.tobytes())



def main():
    base = os.path.expandvars(r"%APPDATA%\com.bakushi\bakushi\library")
    song = sorted(d for d in os.listdir(base)
                  if d.startswith("drop-it-like-it-s-hot-mp3")
                  and os.path.isdir(os.path.join(base, d)))[-1]
    song_dir = os.path.join(base, song)
    print("song:", song_dir)

    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "_punchtmp")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    dl = os.path.join(tmp, "drums_l.f32le")
    dr = os.path.join(tmp, "drums_r.f32le")
    for name in ("drums", "bass", "other", "vocals"):
        l, r = read_stem(song_dir, name)
        l.tofile(os.path.join(tmp, "%s_l.f32le" % name))
        r.tofile(os.path.join(tmp, "%s_r.f32le" % name))

    orig_l, orig_r = read_stem(song_dir, "drums")
    b_rms, b_peak, b_crest, b_lf, b_snap = stats(orig_l, orig_r)
    print("\n=== BEFORE punch ===")
    print("RMS %.4f  peak %.3f  crest %.1f dB  LF(40-120Hz) %.1f%%  "
          "snap(2-4kHz) %.1f%%" % (b_rms, b_peak, b_crest,
                                   b_lf * 100, b_snap * 100))

    res = drum_punch.apply_to_files(dl, dr)
    print("sidecar-style result:", res)

    pl, pr = np.fromfile(dl, dtype=np.float32), np.fromfile(dr,
                                                            dtype=np.float32)
    a_rms, a_peak, a_crest, a_lf, a_snap = stats(pl, pr)
    chan_peak = float(max(np.max(np.abs(pl)), np.max(np.abs(pr))))
    print("\n=== AFTER punch ===")
    print("RMS %.4f  peak %.3f (mono) / %.3f (channel)  crest %.1f dB  "
          "LF(40-120Hz) %.1f%%  snap(2-4kHz) %.1f%%"
          % (a_rms, a_peak, chan_peak, a_crest,
             a_lf * 100, a_snap * 100))
    print("deltas: RMS %+.2f dB  peak %+.2f dB  crest %+.1f dB  "
          "LF %+.1f%%  snap %+.1f%%"
          % (20 * np.log10(a_rms / b_rms + 1e-12),
             20 * np.log10(a_peak / b_peak + 1e-12),
             a_crest - b_crest,
             (a_lf - b_lf) * 100, (a_snap - b_snap) * 100))
    ok_norm = abs(chan_peak - 10 ** (-1.0 / 20.0)) < 0.001
    print("channel peak normalized to -1 dBFS:",
          "PASS" if ok_norm else "FAIL")

    # ---- zero time shift: cross-correlation lag on downsampled mono ----
    ol = (orig_l.astype(np.float64)[::8]).copy()
    nl = (pl.astype(np.float64)[::8]).copy()
    c = np.correlate(nl - nl.mean(), ol - ol.mean(), mode="same")
    lag = int(np.argmax(c)) - (ol.size // 2)
    print("cross-correlation lag: %d samples @ 44.1k/8 = %.3f ms"
          % (lag, lag * 8 / 44.1))
    print("no time shift:", "PASS" if lag == 0 else "FAIL")

    # ---- restore check ----
    rest = drum_punch.restore_files(dl, dr)
    rl, rr = np.fromfile(dl, dtype=np.float32), np.fromfile(dr,
                                                            dtype=np.float32)
    print("\nrestore:", rest)
    print("restored identical to original:",
          "PASS" if np.array_equal(rl, orig_l) and np.array_equal(rr, orig_r)
          else "FAIL")

    # ---- A/B listening files ----
    write_wav(os.path.join(tmp, "_punch_ab_before.wav"), orig_l, orig_r)
    write_wav(os.path.join(tmp, "_punch_ab_after.wav"), pl, pr)
    # Level-matched "before" for a fair A/B: the original Demucs drums peak
    # ABOVE 0 dBFS (inter-sample overshoot), so match its channel peak to
    # the same -1 dBFS the punch normalizes to.
    b_chan = float(max(np.max(np.abs(orig_l)), np.max(np.abs(orig_r))))
    lm = (10 ** (-1.0 / 20.0) / b_chan)
    write_wav(os.path.join(tmp, "_punch_ab_before_levelmatched.wav"),
              (orig_l * lm).astype(np.float32),
              (orig_r * lm).astype(np.float32))
    print("\nA/B files:",
          os.path.join(tmp, "_punch_ab_before_levelmatched.wav"),
          "(level-matched) |",
          os.path.join(tmp, "_punch_ab_after.wav"), "(punched)")


if __name__ == "__main__":
    main()
