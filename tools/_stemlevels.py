"""Per-stem level analysis for a saved library song: RMS dB and peak,
to verify the slice-detection silence thresholds against the real song."""
import glob
import math
import os
import sys

import numpy as np


def main():
    base = os.path.expandvars(
        r"%APPDATA%\com.bakushi\bakushi\library\drop-it-like-i")
    dirs = [d for d in glob.glob(base + "*") if os.path.isdir(d)]
    if not dirs:
        print("song dir not found near", base)
        sys.exit(1)
    song = sorted(dirs)[-1]
    print("song:", song)
    for name in ("drums", "bass", "other", "vocals", "guitar", "piano"):
        lp = os.path.join(song, "stems", "%s_l.f32le" % name)
        if not os.path.isfile(lp):
            print("%-8s MISSING" % name)
            continue
        l = np.fromfile(lp, dtype=np.float32)
        mono = l  # left only is enough for levels
        rms = float(np.sqrt(np.mean(mono * mono))) if mono.size else 0.0
        peak = float(np.max(np.abs(mono))) if mono.size else 0.0
        db = 20 * math.log10(rms) if rms > 0 else -999
        peak_db = 20 * math.log10(peak) if peak > 0 else -999
        print("%-8s rms=%7.2f dB (%8.5f) peak=%7.2f dB frames=%d"
              % (name, db, rms, peak_db, mono.size))


if __name__ == "__main__":
    main()
