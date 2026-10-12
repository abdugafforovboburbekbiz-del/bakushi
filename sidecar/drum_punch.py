"""Drum punch DSP chain for the separated drums stem (numpy/scipy only).

Applied AFTER separation, BEFORE slicing, ONLY to the drums stem:

  1. DC-remove + high-pass @ 25 Hz (zero-phase, tightens the low end).
  2. Transient shaper: envelope-follower split of attack/sustain -
     boost attacks, trim sustain (restores the snap Demucs smears).
  3. Punch EQ: +low shelf @ 60-100 Hz (thump) and +bell @ 2-4 kHz
     (snap/crack).
  4. Soft-knee parallel (NY-style) compression: ~30% wet, 4:1,
     20 ms attack / 150 ms release, soft knee.
  5. Normalize to -1 dBFS peak (consistent drum-pad levels).

Every stage is either a zero-phase filter (sosfiltfilt) or a pure gain
curve, so the processing NEVER shifts timing - slices stay on the
beat grid.

Keep this module free of C-extension imports at module level beyond numpy
(it is imported from cmd_separate, which runs in a WORKER THREAD while the
server main thread is blocked in stdin.readline - scipy imports there
DEADLOCK on Windows; see the beat_analyze note in bakushi_sidecar.py).
"""
import os

import numpy as np

SAMPLE_RATE = 44100

# Chain defaults (tunable, midpoints of the spec ranges).
DEFAULTS = {
    "hp_hz": 25.0,          # DC-remove + high-pass
    "attack_db": 2.5,       # transient attack boost (1.5-3 dB)
    "sustain_db": -1.0,     # sustain trim
    "shelf_hz": 80.0,       # low shelf center (60-100 Hz)
    "shelf_db": 2.5,        # thump (2-3 dB)
    "presence_hz": 3000.0,  # snap/crack band center (2-4 kHz)
    "presence_db": 2.0,
    "comp_wet": 0.3,        # NY-style parallel mix (~30% compressed)
    "comp_ratio": 4.0,      # 3-4:1
    "comp_att_ms": 20.0,    # 10-30 ms
    "comp_rel_ms": 150.0,
    "comp_thr_db": -18.0,   # relative to full scale
    "comp_knee_db": 8.0,    # soft knee width
    "peak_db": -1.0,        # normalization target
}


def _db2lin(db):
    return np.power(10.0, np.asarray(db, dtype=np.float64) / 20.0)


def _rms(x):
    return float(np.sqrt(np.mean(x.astype(np.float64) ** 2)) + 1e-12) \
        if x.size else 0.0


def _peak(x):
    return float(np.max(np.abs(x))) if x.size else 0.0


def _envelope_follower(x, sr, att_ms, rel_ms):
    """One-pole envelope follower on |x| (vectorized): fast attack on
    rising edges, slower release on falling edges."""
    att = float(np.exp(-1.0 / (att_ms / 1000.0 * sr)))
    rel = float(np.exp(-1.0 / (rel_ms / 1000.0 * sr)))
    a = np.array([att, rel], dtype=np.float64)
    y = np.empty_like(x, dtype=np.float64)
    y[0] = x[0]
    rise = np.maximum(x[1:] - y[:-1], 0.0)
    fall = np.minimum(x[1:] - y[:-1], 0.0)
    y[1:] = y[:-1] + a[0] * rise + a[1] * fall
    return y


def _biquad_low_shelf(fs, f0, gain_db, q=0.707):
    """RBJ cookbook low shelf -> (b, a)."""
    a_db = float(gain_db)
    aa = _db2lin(a_db / 2.0)
    w0 = 2.0 * np.pi * f0 / fs
    cw = np.cos(w0)
    sw = np.sin(w0)
    alpha = sw / (2.0 * q)
    b0 = aa * ((aa + 1.0) - (aa - 1.0) * cw + 2.0 * np.sqrt(aa) * alpha)
    b1 = 2.0 * aa * ((aa - 1.0) - (aa + 1.0) * cw)
    b2 = aa * ((aa + 1.0) - (aa - 1.0) * cw - 2.0 * np.sqrt(aa) * alpha)
    a0 = (aa + 1.0) + (aa - 1.0) * cw + 2.0 * np.sqrt(aa) * alpha
    a1 = -2.0 * ((aa - 1.0) + (aa + 1.0) * cw)
    a2 = (aa + 1.0) + (aa - 1.0) * cw - 2.0 * np.sqrt(aa) * alpha
    return (np.array([b0, b1, b2]) / a0, np.array([a0, a1, a2]) / a0)


def _biquad_peaking(fs, f0, gain_db, q=0.9):
    """RBJ cookbook peaking EQ -> (b, a)."""
    aa = _db2lin(gain_db)
    w0 = 2.0 * np.pi * f0 / fs
    cw = np.cos(w0)
    sw = np.sin(w0)
    alpha = sw / (2.0 * q)
    b0 = 1.0 + alpha * aa
    b1 = -2.0 * cw
    b2 = 1.0 - alpha * aa
    a0 = 1.0 + alpha / aa
    a1 = -2.0 * cw
    a2 = 1.0 - alpha / aa
    return (np.array([b0, b1, b2]) / a0, np.array([a0, a1, a2]) / a0)


def _soft_knee_gain_db(x_db, thr_db, ratio, knee_db):
    """Gain reduction in dB (<= 0) for a soft-knee compressor."""
    x = np.asarray(x_db, dtype=np.float64)
    thr = float(thr_db)
    half = float(knee_db) / 2.0
    g = np.zeros_like(x)
    below = x <= thr - half
    above = x >= thr + half
    middle = ~(below | above)
    g[above] = (thr + (x[above] - thr) / ratio) - x[above]
    g[middle] = (1.0 / ratio - 1.0) * (x[middle] - thr + half) ** 2 \
        / (2.0 * knee_db)
    return g


def punch_channel(x, sr=SAMPLE_RATE, params=None):
    """Apply the full drum-punch chain to one channel (float64 in/out)."""
    from scipy import signal  # lazy: only the main-thread callers reach here
    p = dict(DEFAULTS)
    if params:
        p.update(params)
    y = np.asarray(x, dtype=np.float64)

    # 1. DC-remove + high-pass at 25 Hz (zero-phase -> no time shift).
    sos = signal.butter(2, p["hp_hz"], btype="highpass", fs=sr,
                        output="sos")
    y = signal.sosfiltfilt(sos, y)

    # 2. Transient shaper (pure gain curve -> no time shift).
    env_fast = _envelope_follower(np.abs(y), sr, 2.0, 40.0)
    env_slow = _envelope_follower(np.abs(y), sr, 12.0, 120.0)
    w = np.clip((env_fast - env_slow) / (env_slow + 1e-9), 0.0, 1.0)
    n = max(8, int(0.004 * sr))          # ~4 ms smoothing kernel
    kernel = np.ones(n, dtype=np.float64) / n
    w = np.convolve(w, kernel, mode="same")
    w = np.clip(w, 0.0, 1.0)
    g_att = _db2lin(p["attack_db"])
    g_sus = _db2lin(p["sustain_db"])
    y *= g_sus + (g_att - g_sus) * w

    # 3. Punch EQ (zero-phase biquads).
    b, a = _biquad_low_shelf(sr, p["shelf_hz"], p["shelf_db"])
    sos = signal.tf2sos(b, a)
    y = signal.sosfiltfilt(sos, y)
    b, a = _biquad_peaking(sr, p["presence_hz"], p["presence_db"])
    sos = signal.tf2sos(b, a)
    y = signal.sosfiltfilt(sos, y)

    # 4. Soft-knee parallel compression (gain curve -> no time shift).
    env = _envelope_follower(np.abs(y), sr, p["comp_att_ms"],
                             p["comp_rel_ms"])
    env_db = 20.0 * np.log10(env + 1e-9)
    g_db = _soft_knee_gain_db(env_db, p["comp_thr_db"], p["comp_ratio"],
                              p["comp_knee_db"])
    g_db = np.clip(g_db, -24.0, 0.0)
    wet = y * _db2lin(g_db)
    y = (1.0 - p["comp_wet"]) * y + p["comp_wet"] * wet

    return y


def punch_drums(left, right, sr=SAMPLE_RATE, params=None):
    """Full chain on a stereo pair, then normalize to -1 dBFS peak."""
    l = punch_channel(np.asarray(left, dtype=np.float64), sr, params)
    r = punch_channel(np.asarray(right, dtype=np.float64), sr, params)
    peak = max(_peak(l), _peak(r))
    if peak > 1e-9:
        scale = _db2lin(DEFAULTS["peak_db"] if not params
                        else params.get("peak_db", DEFAULTS["peak_db"])) / peak
        l *= scale
        r *= scale
    return l.astype(np.float32), r.astype(np.float32)


def _backup_paths(left_path, right_path):
    return left_path + ".prepunch", right_path + ".prepunch"


def apply_to_files(left_path, right_path, params=None):
    """Punch the drums PCM files in place (backup preserved for restore)."""
    if not os.path.isfile(left_path) or not os.path.isfile(right_path):
        raise ValueError("drums PCM files not found: %s / %s"
                         % (left_path, right_path))
    l = np.fromfile(left_path, dtype=np.float32)
    r = np.fromfile(right_path, dtype=np.float32)
    if l.size == 0 or r.size == 0:
        raise ValueError("drums PCM is empty")
    n = int(min(l.size, r.size))
    l, r = l[:n], r[:n]
    mono = ((l.astype(np.float64) + r.astype(np.float64)) * 0.5)
    rms_before = _rms(mono)
    peak_before = _peak(mono)

    bl, br = _backup_paths(left_path, right_path)
    if not os.path.isfile(bl):
        l.tofile(bl)
    if not os.path.isfile(br):
        r.tofile(br)

    pl, pr = punch_drums(l, r, params=params)
    pl.tofile(left_path)
    pr.tofile(right_path)
    mono_a = ((pl.astype(np.float64) + pr.astype(np.float64)) * 0.5)
    return {
        "applied": True,
        "rms_before": round(rms_before, 6),
        "peak_before": round(peak_before, 6),
        "rms_after": round(_rms(mono_a), 6),
        "peak_after": round(_peak(mono_a), 6),
    }


def restore_files(left_path, right_path):
    """Restore the unpunched drums from the .prepunch backups."""
    bl, br = _backup_paths(left_path, right_path)
    if not os.path.isfile(bl) or not os.path.isfile(br):
        return {"applied": False, "restored": False,
                "rms_after": None, "peak_after": None}
    import shutil
    shutil.copyfile(bl, left_path)
    shutil.copyfile(br, right_path)
    l = np.fromfile(left_path, dtype=np.float32)
    r = np.fromfile(right_path, dtype=np.float32)
    mono = ((l.astype(np.float64) + r.astype(np.float64)) * 0.5)
    return {"applied": False, "restored": True,
            "rms_after": round(_rms(mono), 6),
            "peak_after": round(_peak(mono), 6)}


def clear_backups(left_path, right_path):
    """Remove stale .prepunch backups (call before a fresh separation)."""
    for pth in _backup_paths(left_path, right_path):
        if os.path.isfile(pth):
            os.remove(pth)
