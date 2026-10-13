"""Verify that a server-mode GPU separation releases the compiled
OpenVINO GPU model afterwards (the thing that pinned ~11 GB in the
sidecar and froze the app after separation finished)."""
import ctypes
import os
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "sidecar"))
import bakushi_sidecar as bs  # noqa: E402


def ws_mb():
    ws = ctypes.c_size_t()
    mn = ctypes.c_size_t()
    h = ctypes.windll.kernel32.GetCurrentProcess()
    ctypes.windll.kernel32.GetProcessWorkingSetSize(
        ctypes.c_void_p(h), ctypes.byref(mn), ctypes.byref(ws))
    return ws.value / 1048576.0


def main():
    import av
    cont = av.open("test_song.wav")
    astream = next(s for s in cont.streams if s.type == "audio")
    resampler = av.AudioResampler(format="fltp", layout="stereo", rate=44100)
    parts = []
    for frame in cont.decode(astream):
        rfs = resampler.resample(frame)
        if rfs is None:
            continue
        for rf in (rfs if isinstance(rfs, list) else [rfs]):
            if rf is not None:
                parts.append(rf.to_ndarray())
    rfs = resampler.resample(None)
    if rfs:
        for rf in (rfs if isinstance(rfs, list) else [rfs]):
            if rf is not None:
                parts.append(rf.to_ndarray())
    cont.close()
    arr = np.concatenate(parts, axis=1).astype(np.float32)
    left = arr[0]
    right = arr[1]
    tmp = tempfile.mkdtemp(prefix="bakushi_rel_")
    lp = os.path.join(tmp, "input_l.f32le")
    rp = os.path.join(tmp, "input_r.f32le")
    left.tofile(lp)
    right.tofile(rp)

    print("WS before: %.0f MB  cache keys: %s"
          % (ws_mb(), [k[1] or "auto" for k in bs._model_cache]))

    req = {
        "id": 1,
        "model_path": os.environ.get(
            "BAKUSHI_MODEL",
            os.path.normpath(os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "..", "assets", "models", "htdemucs_fp16weights.onnx"))),
        "left_path": lp,
        "right_path": rp,
        "out_dir": tmp,
        "hop_samples": 88200,
        "provider": "gpu",
    }
    res = bs.cmd_separate(req)
    print("separation done: %d chunks, provider in result stems ok=%s"
          % (res["chunks"], len(res["stems"]) == 6))

    print("WS after release: %.0f MB  cache keys: %s"
          % (ws_mb(), [k[1] or "auto" for k in bs._model_cache]))
    dropped = all(k[1] != "gpu" for k in bs._model_cache)
    print("GPU model released from cache: %s" % dropped)


if __name__ == "__main__":
    main()
