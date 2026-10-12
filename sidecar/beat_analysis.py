"""Beat + downbeat extraction for musical pad cutting (librosa).

Returns beat/downbeat timestamps in SAMPLES so the Dart pad planner can
anchor LOOP pads on real downbeats. Also provides onset one-shots for
HIT pads (chop mode).

Design notes:
- The analysis MUST run inline on the sidecar server main thread
  (librosa/scipy C-extension imports inside a worker thread deadlock on
  Windows while the main thread is blocked in sys.stdin.readline()).
- The tempo-halving disambiguation (tempogram ratio >= 0.9 -> re-track
  at bpm/2) is kept from the verified multi-song benchmark set.
- Downbeats = beats[argmax_p sum(onset_strength[beats[p::4]])::4].
"""
import numpy as np

SAMPLE_RATE = 44100
HOP = 512

# 50 ms local-RMS gate for onset one-shots (noise-floor rejection).
LOCAL_GATE_SEC = 0.050
# One-shot hits must have at least this RMS (silence rejection).
MIN_HIT_RMS = 0.01


def _load_mono(path_l, path_r):
    l = np.fromfile(path_l, dtype=np.float32)
    r = np.fromfile(path_r, dtype=np.float32) if path_r else l
    n = int(min(l.size, r.size))
    if n == 0:
        return np.zeros(0, dtype=np.float32)
    return ((l[:n] + r[:n]) * 0.5).astype(np.float32)


def _downbeat_frames(beat_frames, onset_env):
    """4/4 downbeats = the beat phase whose beats carry the most onset
    strength. beat_frames: hop units; returns hop units."""
    frames = np.asarray(beat_frames, dtype=np.int64)
    if frames.size < 4:
        return frames
    sums = [float(onset_env[frames[p::4]].sum()) for p in range(4)]
    phase = int(np.argmax(sums))
    return frames[phase::4]


def _onset_frames(onset_env, y, sr, sensitivity=0.6):
    """Onset one-shots on an onset envelope: backtracked onset_detect,
    30 ms wait, 50 ms local-RMS gate, whole-hit RMS >= 0.01."""
    import librosa

    delta = 0.16 * (1.0 - sensitivity) + 0.02
    wait = max(1, int(0.030 * sr / HOP))
    frames = librosa.onset.onset_detect(
        onset_envelope=onset_env,
        sr=sr,
        hop_length=HOP,
        backtrack=True,
        delta=delta,
        wait=wait,
    )
    gate = max(1, int(LOCAL_GATE_SEC * sr))
    out = []
    for f in np.asarray(frames, dtype=np.int64):
        s = int(f) * HOP
        if s + gate > len(y):
            continue
        local = float(np.sqrt(np.mean(y[s:s + gate] ** 2)))
        if local >= MIN_HIT_RMS:
            out.append(s)
    return out


def analyze(stems_paths, sr=SAMPLE_RATE, with_drums_onsets=True):
    """stems_paths: {name: (left_f32le_path, right_f32le_path)}.

    Returns {"bpm": float, "beats": [samples], "downbeats": [samples]}
    plus "onsets": [samples] (drums one-shots) when
    with_drums_onsets is true.
    """
    import librosa

    drums = stems_paths.get("drums")
    if drums is None:
        raise ValueError("drums stem is required for BPM detection")
    y = _load_mono(drums[0], drums[1])
    if len(y) < sr:
        raise ValueError("audio too short for BPM detection (< 1 s)")

    tempo, beat_frames = librosa.beat.beat_track(
        y=y, sr=sr, hop_length=HOP, tightness=100, units="frames")
    bpm = float(np.atleast_1d(tempo)[0])
    frames = np.asarray(beat_frames, dtype=np.int64)
    if frames.size < 4:
        raise ValueError("too few beats detected (got %d)" % frames.size)

    # Tempo halving disambiguation (tempogram ratio >= 0.9 -> re-track at
    # bpm/2). Verified on the multi-song benchmark set.
    if bpm > 100.0:
        cand = bpm / 2.0
        if cand >= 40.0:
            import librosa.feature.rhythm as _rhythm
            tgram = librosa.feature.tempogram(y=y, sr=sr, hop_length=HOP)
            bins = _rhythm.tempo_frequencies(tgram.shape[0],
                                             hop_length=HOP, sr=sr)
            tmean = tgram.mean(axis=1)

            def _ts(t):
                return float(tmean[int(np.argmin(np.abs(bins - t)))])

            if _ts(cand) >= 0.9 * _ts(bpm):
                t2, f2 = librosa.beat.beat_track(y=y, sr=sr, hop_length=HOP,
                                                 tightness=100,
                                                 start_bpm=cand,
                                                 units="frames")
                f2 = np.asarray(f2, dtype=np.int64)
                new_bpm = float(np.atleast_1d(t2)[0])
                if f2.size >= 4 and 0.85 * cand <= new_bpm <= 1.15 * cand:
                    bpm = cand
                    frames = f2

    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=HOP)
    down_frames = _downbeat_frames(frames, onset_env)

    res = {
        "bpm": round(bpm, 2),
        "beats": [int(f * HOP) for f in frames],
        "downbeats": [int(f * HOP) for f in down_frames],
    }
    if with_drums_onsets:
        res["onsets"] = _onset_frames(onset_env, y, sr)
    return res


def chop(stems_paths, stem, sensitivity=0.6, sr=SAMPLE_RATE):
    """Onset one-shots for ONE stem (chop mode / HIT pads).

    Returns {"onsets": [samples]}. The Dart planner computes each hit's
    end as min(next onset - 10 ms, start + 1.5 s).
    """
    import librosa

    pair = stems_paths.get(stem)
    if pair is None:
        raise ValueError("stem %r is required for onset detection" % stem)
    y = _load_mono(pair[0], pair[1])
    if len(y) < sr:
        raise ValueError("audio too short for onset detection (< 1 s)")
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=HOP)
    onsets = _onset_frames(onset_env, y, sr, sensitivity=sensitivity)
    return {"onsets": onsets}
