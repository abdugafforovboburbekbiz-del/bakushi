#!/usr/bin/env python3
"""Bakushi benchmark harness.

Runs a fixed 30-second test clip through every (model x provider) combo
using the sidecar CLI and records per-chunk timings, total time, RTF and
peak RSS. Results are saved to tools/benchmark_results.json.

Usage:
  python tools/benchmark.py [--clip PATH] [--providers cpu,gpu,openvino]
                            [--models quality,fast,fp32-4s] [--timeout SEC]

Note: run this when the machine is NOT already hot - CPU separation is
thermal-throttle-sensitive and hot laptops report much slower numbers.
"""

import argparse
import datetime
import json
import os
import platform
import subprocess
import sys
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

DEFAULT_MODELS = {
    "quality": {
        "label": "6-stem fp32 (quality, baseline)",
        "path": os.environ.get(
            "BAKUSHI_QUALITY_MODEL",
            r"C:\path\to\USER\Downloads\htdemucs_6s.onnx"),
    },
    "fp32-4s": {
        "label": "4-stem fp32 (sliced, reference)",
        "path": os.path.join(ROOT, "assets", "models", "htdemucs_4s.onnx"),
    },
    "fp16-4s": {
        "label": "4-stem fp16 weights (app default)",
        "path": os.path.join(ROOT, "assets", "models",
                             "htdemucs_fp16weights.onnx"),
    },
    "fast": {
        "label": "4-stem int8 (fast mode)",
        "path": os.path.join(ROOT, "assets", "models", "htdemucs_4s_int8.onnx"),
    },
}


def make_clip(path, seconds=30.0, sr=44100):
    """Deterministic 30 s stereo test clip: kick, bass, melody, hats and a
    2-second silent gap (exercises the silent-chunk skip)."""
    rng = np.random.default_rng(42)
    n = int(seconds * sr)
    t = np.arange(n, dtype=np.float64) / float(sr)
    kick_t = (t % 0.5) < 0.08
    kick = np.sin(2 * np.pi * (60 + 40 * (t % 0.5) / 0.5) * t) * kick_t
    bass = 0.4 * np.sin(2 * np.pi * 82.4 * t) * ((t % 1.0) < 0.6)
    melody = 0.3 * np.sin(2 * np.pi * 440.0 * t) * ((t % 1.0) < 0.7) \
        + 0.2 * np.sin(2 * np.pi * 554.4 * t) * ((t % 2.0) < 0.9)
    hats = 0.15 * rng.standard_normal(n) * ((t % 0.25) < 0.03)
    vocalish = 0.25 * np.sign(np.sin(2 * np.pi * 220.0 * t)) \
        * np.sin(2 * np.pi * 330.0 * t) * ((t % 1.0) < 0.5)
    mix = kick + bass + melody + hats + vocalish
    # 2 s of silence in the middle.
    gap = slice(int(15.0 * sr), int(17.0 * sr))
    mix[gap] = 0.0
    mix = np.clip(mix, -1.0, 1.0)
    pcm = (mix * 32767.0).astype(np.int16)
    stereo = np.repeat(pcm, 2)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(stereo.tobytes())
    return path, seconds


def run_one(sidecar, clip, model, provider, timeout, hop=88200,
            machine=None):
    label = model["label"]
    mpath = model["path"]
    if not os.path.isfile(mpath):
        return {"model": label, "provider_requested": provider, "ok": False,
                "error": "model file missing: %s" % mpath}
    env = os.environ.copy()
    if provider == "dml":
        avail = (machine or {}).get("available_providers", [])
        if "DmlExecutionProvider" not in avail:
            return {"model": label, "provider_requested": provider,
                    "ok": False,
                    "error": "DirectML not installed on this machine "
                             "(removed after it returned all-zeros on "
                             "Iris Xe)"}
    if provider == "ortcpu":
        # Plain onnxruntime CPU EP: BAKUSHI_OV=0 makes the sidecar skip
        # the native OpenVINO path and use the ORT CPU session.
        env["BAKUSHI_OV"] = "0"
        cli_provider = "cpu"
    else:
        cli_provider = provider
    print("RUN %-40s provider=%-8s" % (label, provider), flush=True)
    t0 = time.time()
    cmd = [sys.executable, sidecar, "--separate", clip, "--model", mpath,
           "--provider", cli_provider, "--bench", "--hop", str(hop)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, cwd=ROOT, env=env,
                              encoding="utf-8", errors="replace")
        out = proc.stdout or ""
        err = proc.stderr or ""
        bench = None
        for line in out.splitlines():
            if line.startswith("BENCH "):
                bench = json.loads(line[len("BENCH "):])
        entry = {
            "model": label,
            "model_path": mpath,
            "model_size": os.path.getsize(mpath),
            "provider_requested": provider,
            "wall_seconds": round(time.time() - t0, 2),
            "ok": bench is not None and proc.returncode == 0,
        }
        if bench is not None:
            entry.update(bench)
        else:
            tail = "\n".join((out + err).splitlines()[-6:])
            entry["error"] = tail[:800]
        return entry
    except subprocess.TimeoutExpired:
        return {"model": label, "provider_requested": provider, "ok": False,
                "error": "timeout after %ds" % timeout,
                "wall_seconds": timeout}
    except Exception as exc:  # noqa: BLE001
        return {"model": label, "provider_requested": provider, "ok": False,
                "error": str(exc)}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--clip", default=os.path.join(HERE, "bench_clip.wav"))
    ap.add_argument("--providers", default="cpu,ortcpu,gpu,dml")
    ap.add_argument("--models", default="quality,fp16-4s,fast")
    ap.add_argument("--hop", type=int, default=88200)
    ap.add_argument("--timeout", type=int, default=2700)
    ap.add_argument("--cooldown", type=int, default=30,
                    help="seconds to let the CPU cool between runs")
    args = ap.parse_args()

    import onnxruntime as ort

    clip, clip_seconds = make_clip(args.clip)
    sidecar = os.path.join(ROOT, "sidecar", "bakushi_sidecar.py")
    machine = {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "onnxruntime": getattr(ort, "__version__", "?"),
        "available_providers": ort.get_available_providers(),
    }
    print("machine:", machine, flush=True)
    print("clip: %s (%.1f s)" % (clip, clip_seconds), flush=True)

    runs = []
    for model_name in args.models.split(","):
        model = DEFAULT_MODELS.get(model_name.strip())
        if model is None:
            print("unknown model %r - skipping" % model_name)
            continue
        for provider in args.providers.split(","):
            provider = provider.strip()
            runs.append(run_one(sidecar, clip, model, provider,
                                args.timeout, args.hop, machine))
            ok = runs[-1].get("ok")
            print("  -> %s %s" %
                  ("OK" if ok else "FAILED", runs[-1].get("error", "")),
                  flush=True)
            if args.cooldown:
                time.sleep(args.cooldown)

    for r in runs:
        total = r.get("total_seconds")
        if r.get("ok") and total:
            r["rtf"] = round(total / clip_seconds, 3)
            times = [t for t in r.get("chunk_seconds", []) if t > 0]
            r["avg_chunk_s"] = round(sum(times) / len(times), 3) if times else 0
            r["infer_only_s"] = round(sum(r.get("chunk_seconds", [])), 3)

    report = {
        "timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
        "machine": machine,
        "clip": {"path": clip, "duration_s": clip_seconds},
        "hop_samples": args.hop,
        "runs": runs,
    }
    out_path = os.path.join(HERE, "benchmark_results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print("\nsaved results -> %s" % out_path)

    print("\n%-34s %-8s %-9s %-8s %-7s %-9s %s" %
          ("MODEL", "PROV", "avg/chunk", "chunks", "total", "RTF", "peak RSS"))
    for r in runs:
        if not r.get("ok"):
            print("%-34s %-8s FAILED (%s)" %
                  (r["model"], r["provider_requested"],
                   (r.get("error") or "")[:60]))
        else:
            print("%-34s %-8s %8ss %7d %7.0fs %6sx %8.0f MB" %
                  (r["model"], r.get("provider", "?"),
                   r.get("avg_chunk_s", 0), r.get("chunks", 0),
                   r.get("total_seconds", 0), r.get("rtf", 0),
                   r.get("peak_rss_mb", 0)))


if __name__ == "__main__":
    main()
