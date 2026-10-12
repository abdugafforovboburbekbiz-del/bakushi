#!/usr/bin/env python3
"""
Bakushi AI sidecar.

Decodes uploaded audio (WAV/MP3/OGG/M4A) into stereo 44.1 kHz float32 PCM and
runs real HTDemucs ONNX stem separation on the user's machine. Nothing is
uploaded anywhere.

Communication: newline-delimited JSON over stdin/stdout.
  Request : {"id": int, "type": "hello|decode|separate|stop", ...payload}
  Response: {"id": int, "ok": true, "result": {...}}
            {"id": int, "ok": false, "error": {"message": ..., "hint": ...}}
  Event   : {"id": int, "type": "event", "event": "progress", "data": {...}}

Execution providers are tried in this order:
  OpenVINO (primary; ~1.6x faster than the ORT CPU EP on this machine)
  -> CPU (ORT fallback). DirectML is REMOVED: it returned all-zeros on
  Intel Iris Xe and was uninstalled (see docs/BENCHMARKS.md).

Usage:
  python bakushi_sidecar.py                 # stdin/stdout server
  python bakushi_sidecar.py --selftest      # report providers, no server
"""

import argparse
import json
import os
import sys
import tempfile
import threading
import time
import traceback

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace", newline="\n")
if hasattr(sys.stdin, "reconfigure"):
    sys.stdin.reconfigure(encoding="utf-8")

import numpy as np  # noqa: E402

SAMPLE_RATE = 44100
DEFAULT_SEGMENT = 343980   # ~7.8 s at 44.1 kHz (derived from the model when possible)
DEFAULT_HOP = 88200        # 2.0 s overlap step at 44.1 kHz
STEM_ORDER_6 = ("drums", "bass", "other", "vocals", "guitar", "piano")

_print_lock = threading.Lock()
_cancel_event = threading.Event()
_model_cache = {}


def send(obj):
    with _print_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def send_ok(req_id, result):
    send({"id": req_id, "ok": True, "result": result})


def send_error(req_id, message, hint=""):
    send({"id": req_id, "ok": False, "error": {"message": str(message), "hint": hint}})


def send_progress(req_id, stage, done, total, percent):
    send({"id": req_id, "type": "event", "event": "progress",
          "data": {"stage": stage, "done": done, "total": total,
                   "percent": round(float(percent), 1)}})


class Cancelled(Exception):
    pass


# --------------------------------------------------------------------------- #
# Decoding (PyAV bundles FFmpeg: WAV/MP3/OGG/M4A + resample)
# --------------------------------------------------------------------------- #

def cmd_decode(req):
    _cancel_event.clear()
    path = req.get("path")
    out_dir = req.get("out_dir")
    if not path or not os.path.isfile(path):
        raise FileNotFoundError("Uploaded file not found: %s" % path)
    os.makedirs(out_dir, exist_ok=True)

    import av
    container = av.open(path)
    try:
        astream = next((s for s in container.streams if s.type == "audio"), None)
        if astream is None:
            raise ValueError("The file contains no audio stream (corrupted or "
                             "unsupported container).")
        resampler = av.AudioResampler(format="fltp", layout="stereo",
                                      rate=SAMPLE_RATE)
        chunks = []
        for frame in container.decode(astream):
            if _cancel_event.is_set():
                raise Cancelled("Decode cancelled by user.")
            rfs = resampler.resample(frame)  # PyAV 12+ returns a list
            if rfs is None:
                continue
            for rf in (rfs if isinstance(rfs, list) else [rfs]):
                if rf is not None:
                    chunks.append(rf.to_ndarray())  # (channels, samples)
        # Flush any samples still buffered in the resampler.
        rfs = resampler.resample(None)
        if rfs:
            for rf in (rfs if isinstance(rfs, list) else [rfs]):
                if rf is not None:
                    chunks.append(rf.to_ndarray())
        if not chunks:
            arr = np.zeros((2, 0), dtype=np.float32)
        else:
            arr = np.concatenate(chunks, axis=1)
        if arr.ndim == 1:
            arr = arr[np.newaxis, :]
        if arr.shape[0] == 1:
            arr = np.repeat(arr, 2, axis=0)
        arr = arr[:2].astype(np.float32, copy=False)
        if arr.shape[1] == 0:
            raise ValueError("Decoded audio is empty (0 samples).")
    finally:
        container.close()

    left_path = os.path.join(out_dir, "decoded_l.f32le")
    right_path = os.path.join(out_dir, "decoded_r.f32le")
    arr[0].tofile(left_path)
    arr[1].tofile(right_path)
    _release_memory()
    peak = float(np.max(np.abs(arr))) if arr.size else 0.0
    return {"left_path": left_path, "right_path": right_path,
            "frames": int(arr.shape[1]), "sample_rate": SAMPLE_RATE,
            "channels": 2, "peak": peak,
            "duration": arr.shape[1] / float(SAMPLE_RATE)}


# --------------------------------------------------------------------------- #
# ONNX model loading / inference
# --------------------------------------------------------------------------- #

def _stem_count_from_shape(shape):
    """Return the demucs stem count (4 or 6) implied by a concatenated
    output shape like (1, 4|6, 2, N) or (1, 8|12, N), else None."""
    for dim in shape:
        if dim in (8, 12):      # (1, 2*stems, N) channel-pair layout
            return dim // 2
    for dim in shape:
        if dim in (4, 6):       # (1, stems, 2, N) stem-major layout
            return dim
    return None


def _provider_sane(session):
    """Run one probe inference and verify the provider actually produces
    audio (some GPU providers silently return zeros on unsupported
    machines/models). Uses a deterministic 440/110/220 Hz sine mixture."""
    try:
        inp = session.get_inputs()[0]
        ishape = list(inp.shape)
        seg = DEFAULT_SEGMENT
        if len(ishape) >= 3 and isinstance(ishape[2], int) and ishape[2] > 0:
            seg = int(ishape[2])
        fp16 = "float16" in str(inp.type)
        t_ = np.arange(seg, dtype=np.float32) / float(SAMPLE_RATE)
        ch = (0.3 * np.sin(2 * np.pi * 440.0 * t_)
              + 0.2 * np.sin(2 * np.pi * 110.0 * t_)
              + 0.1 * np.sin(2 * np.pi * 220.0 * t_)).astype(np.float32)
        x = np.stack([ch, ch * 0.9])[None, :, :]
        if fp16:
            x = x.astype(np.float16)
        t = np.asarray(session.run(None, {inp.name: x})[0])
        if t.dtype != np.float32:
            t = t.astype(np.float32)
        return bool(np.abs(t).max() > 1e-6)
    except Exception:  # noqa: BLE001
        return False


def _apply_process_priority():
    """Run slightly below normal priority so the Flutter UI stays
    responsive during multi-minute CPU separations."""
    if os.name == "nt":
        try:
            import ctypes
            BELOW_NORMAL = 0x00004000
            handle = ctypes.windll.kernel32.GetCurrentProcess()
            ctypes.windll.kernel32.SetPriorityClass(handle, BELOW_NORMAL)
        except Exception:  # noqa: BLE001
            pass


def _release_memory():
    """Free inference buffers and trim the sidecar's working set so the
    system (and the Flutter UI) gets its physical RAM back after a long
    separation run. On Windows a working-set trim pages unused memory out
    without unloading the cached model session."""
    import gc as _gc
    _gc.collect()
    if os.name == "nt":
        try:
            import ctypes
            handle = ctypes.windll.kernel32.GetCurrentProcess()
            ctypes.windll.kernel32.SetProcessWorkingSetSize(
                handle, -1, -1)
        except Exception:  # noqa: BLE001
            pass


def _release_compiled_gpu(meta, cache_key):
    """Drop a compiled OpenVINO GPU model after a separation. The compiled
    graph + OpenCL kernels pin several GB of device memory that stays live
    as long as the sidecar process runs (server mode), which slows the app
    down and can stall the UI after big runs. The next GPU separation pays
    the ~90 s compile again (progress is shown). Set
    BAKUSHI_KEEP_GPU_MODEL=1 to keep it cached across separations."""
    if meta.get("ov_engine") is None:
        return
    # Only free REAL GPU compiles. The CPU-fallback label contains "GPU"
    # too, and the CPU model is worth keeping cached.
    if not str(meta.get("provider", "")).startswith("OpenVINO:GPU"):
        return
    if os.environ.get("BAKUSHI_KEEP_GPU_MODEL", "") in ("1", "true", "yes"):
        return
    _model_cache.pop(cache_key, None)
    meta["ov_engine"] = None
    meta["ov_model"] = None
    import gc as _gc
    _gc.collect()


def _peak_rss_mb():
    """Peak working set of THIS process in MB (Windows via psapi,
    dependency-free)."""
    if os.name == "nt":
        try:
            import ctypes

            class _PROCESS_MEMORY_COUNTERS(ctypes.Structure):
                _fields_ = [
                    ("cb", ctypes.c_uint32),
                    ("PageFaultCount", ctypes.c_uint32),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t),
                ]

            pc = _PROCESS_MEMORY_COUNTERS()
            pc.cb = ctypes.sizeof(pc)
            h = ctypes.windll.kernel32.GetCurrentProcess()
            fn = ctypes.windll.psapi.GetProcessMemoryInfo
            fn.argtypes = [ctypes.c_void_p,
                           ctypes.POINTER(_PROCESS_MEMORY_COUNTERS),
                           ctypes.c_uint32]
            fn.restype = ctypes.c_int
            if fn(ctypes.c_void_p(h), ctypes.byref(pc), pc.cb):
                return float(pc.PeakWorkingSetSize) / 1048576.0
            # Fallback: current working set via kernel32.
            try:
                ws = ctypes.c_size_t()
                ctypes.windll.kernel32.GetProcessWorkingSetSize(
                    ctypes.c_void_p(h), ctypes.byref(ws), ctypes.byref(ws))
                return float(ws.value) / 1048576.0
            except Exception:  # noqa: BLE001
                return 0.0
        except Exception:  # noqa: BLE001
            return 0.0
    return 0.0


_PROVIDER_ALIASES = {
    "cpu": "CPUExecutionProvider",
    "openvino": "OpenVINOExecutionProvider",
    "gpu": "OpenVINOExecutionProvider",
}

# --------------------------------------------------------------------------- #
# Native OpenVINO engine (used for 'cpu'/'gpu'/'openvino' overrides).
# The ORT->OpenVINO EP bridge rejects this model's dynamic-shape graph
# ("Output names mismatch"), but OpenVINO's own runtime handles it fine.
# Measured on this machine: OV-CPU ~1.4 s/chunk, GPU.1 ~1.1 s/chunk vs
# ~2-3 s/chunk on the ORT CPU EP. IMPORTANT: the iGPU exposes TWO devices -
# GPU.0 produces 100% NaN on this model while GPU.1 is clean, so every GPU
# device is probe-validated and the first clean one is remembered.
# --------------------------------------------------------------------------- #

_OV = None


def _ov_bootstrap():
    """Import openvino and put its runtime DLL directory on the search path
    (the pip wheel keeps openvino.dll under openvino/libs, which nothing
    else finds on its own - equivalent to the full installer's
    setupvars.bat)."""
    global _OV
    if _OV is not None:
        return _OV
    try:
        import openvino as ov
        libs = os.path.join(os.path.dirname(ov.__file__), "libs")
        if os.path.isdir(libs):
            if hasattr(os, "add_dll_directory"):
                os.add_dll_directory(libs)
            os.environ["PATH"] = libs + os.pathsep + os.environ.get("PATH", "")
        _OV = ov
    except Exception:  # noqa: BLE001
        _OV = False
    return _OV


def _partial_dims(pshape):
    dims = []
    for d in pshape:
        if d.is_dynamic:
            dims.append(-1)
        else:
            dims.append(int(d.get_length()))
    return dims


def _ov_probe_input(seg):
    t_ = np.arange(seg, dtype=np.float32) / float(SAMPLE_RATE)
    ch = (0.3 * np.sin(2 * np.pi * 440.0 * t_)
          + 0.2 * np.sin(2 * np.pi * 110.0 * t_)
          + 0.1 * np.sin(2 * np.pi * 220.0 * t_)).astype(np.float32)
    return np.stack([ch, ch * 0.9])[None, :, :]


class _OvEngine:
    def __init__(self, compiled, input_any, output_any):
        self.req = compiled.create_infer_request()
        self.input_any = input_any
        self.output_any = output_any

    def infer(self, x):
        self.req.set_tensor(self.input_any, _OV.Tensor(x))
        self.req.infer()
        return np.asarray(
            self.req.get_tensor(self.output_any).data, dtype=np.float32)


def _pick_ov_gpu(core, model, probe_x, probe_hook):
    """Compile the model on each OpenVINO GPU device, probe-validate the
    output (NaN/silence rejection), and return the first clean one. The
    winning device is remembered in provider_state so later loads skip the
    other (broken) devices."""
    st = _load_provider_state()
    last = st.get("last_gpu_device")
    gpus = [d for d in core.available_devices if d.startswith("GPU")]
    if not gpus:
        raise RuntimeError(
            "No OpenVINO GPU device found. Devices: %s"
            % ", ".join(core.available_devices))
    order = ([last] if last in gpus else []) + [d for d in gpus if d != last]
    errors = []
    for dev in order:
        if probe_hook is not None:
            probe_hook("OpenVINO GPU %s" % dev)
        try:
            compiled = core.compile_model(model, dev)
            engine = _OvEngine(compiled, compiled.input(0), compiled.output(0))
            y = engine.infer(probe_x)
            if np.isfinite(y).all() and float(np.abs(y).max()) > 1e-6:
                st["last_gpu_device"] = dev
                _save_provider_state()
                return engine, "OpenVINO:" + dev
            errors.append("%s: probe NaN or silent output" % dev)
        except Exception as exc:  # noqa: BLE001
            errors.append("%s: %s" % (dev, str(exc)[:120]))
    raise RuntimeError(
        "No OpenVINO GPU device produced valid output on this model. "
        "%s" % " | ".join(errors))


def _load_ov_meta(model_path, mode, cache_key, probe_hook):
    """Native-OpenVINO model load; returns the same meta dict shape the ORT
    path produces (session replaced by ov_engine)."""
    ov = _ov_bootstrap()
    if not ov:
        raise RuntimeError(
            "OpenVINO is not installed (pip install openvino "
            "onnxruntime-openvino).")
    core = ov.Core()
    model = core.read_model(model_path)
    inp_shape = _partial_dims(model.input(0).get_partial_shape())
    segment = DEFAULT_SEGMENT
    if len(inp_shape) >= 3 and isinstance(inp_shape[2], int) and inp_shape[2] > 0:
        segment = int(inp_shape[2])
    out_shape = _partial_dims(model.output(0).get_partial_shape())
    n_stems = None
    for d in out_shape:
        if isinstance(d, int) and d in (4, 6, 8, 12):
            n_stems = d // 2 if d in (8, 12) else d
            break
    if n_stems is None:
        n_stems = 6
    stem_names = list(STEM_ORDER_6[:n_stems])
    probe_x = _ov_probe_input(segment)
    if mode == "gpu":
        engine, label = _pick_ov_gpu(core, model, probe_x, probe_hook)
    else:
        if probe_hook is not None:
            probe_hook("OpenVINO CPU")
        compiled = core.compile_model(model, "CPU")
        engine = _OvEngine(compiled, compiled.input(0), compiled.output(0))
        label = "OpenVINO:CPU"
    meta = {
        "session": None,
        "ov_engine": engine,
        "ov_model": model,
        "input_name": "<openvino>",
        "input_shape": inp_shape,
        "input_fp16": False,
        "output_names": ["<openvino>"],
        "segment": segment,
        "stem_names": stem_names,
        "n_stems": n_stems,
        "ordered": None,
        "provider": label,
        "providers_available": core.available_devices,
        "model_size": os.path.getsize(model_path),
    }
    _model_cache[cache_key] = meta
    st = _load_provider_state()
    if st.get("last_good") != "CPUExecutionProvider":
        st["last_good"] = "CPUExecutionProvider"
        _save_provider_state()
    return meta

# Persisted provider probe results so the FIRST model load of every app
# session does not re-pay the (minutes-long on this machine) GPU probes.
# Lives in %LOCALAPPDATA%/Bakushi/provider_state.json.
_provider_state = None
_provider_state_path = None


def _provider_state_file():
    global _provider_state_path
    if _provider_state_path is None:
        base = os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()
        _provider_state_path = os.path.join(
            base, "Bakushi", "provider_state.json")
    return _provider_state_path


def _load_provider_state():
    global _provider_state
    if _provider_state is not None:
        return _provider_state
    st = {"last_good": None, "failed": [], "last_gpu_device": None,
          "gpu_broken_models": []}
    try:
        path = _provider_state_file()
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, dict):
                if d.get("last_good") in _PROVIDER_ALIASES.values():
                    st["last_good"] = d["last_good"]
                if isinstance(d.get("failed"), list):
                    st["failed"] = [
                        p for p in d["failed"]
                        if p in _PROVIDER_ALIASES.values()]
                # Keep the probe-validated GPU device so the next process
                # compiles the winning device FIRST (GPU.0 is broken here
                # and costs ~80 s to compile + probe).
                if isinstance(d.get("last_gpu_device"), str) \
                        and d["last_gpu_device"].startswith("GPU"):
                    st["last_gpu_device"] = d["last_gpu_device"]
                # Models the GPU plugin provably cannot run (skips the
                # multi-minute device probes next time).
                if isinstance(d.get("gpu_broken_models"), list):
                    st["gpu_broken_models"] = [
                        b for b in d["gpu_broken_models"]
                        if isinstance(b, str)]
    except Exception:  # noqa: BLE001
        pass
    _provider_state = st
    return st


def _save_provider_state():
    st = _provider_state
    if st is None:
        return
    try:
        path = _provider_state_file()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(st, f)
        os.replace(tmp, path)
    except Exception:  # noqa: BLE001
        pass


_PROVIDER_SHORT = {
    "CPUExecutionProvider": "CPU",
    "OpenVINOExecutionProvider": "OpenVINO",
}


def load_model(model_path, provider_override=None, probe_hook=None):
    """Load (and cache) the model session; return metadata describing the
    model's real input/output names, shapes and dtypes.

    provider_override ('cpu'|'gpu'|'openvino') routes through the native
    OpenVINO engine (the ORT OpenVINO EP bridge rejects this model's graph):
      - 'gpu':       OpenVINO GPU - every GPU device is probe-validated and
                     the first clean one is used (GPU.0 is broken here).
                     If NO GPU device can run the model, falls back to
                     OpenVINO CPU with a warning instead of failing.
      - 'cpu':       OpenVINO CPU (roughly 2x the ORT CPU EP); falls back to
                     the ORT CPU EP if OpenVINO is missing or fails.
      - 'openvino':  OpenVINO CPU, no fallback (benchmark honesty).
    'dml' is gone - DirectML was uninstalled to install OpenVINO."""
    cache_key = (model_path, provider_override or "")
    if cache_key in _model_cache:
        return _model_cache[cache_key]
    if not os.path.isfile(model_path):
        raise FileNotFoundError(
            "Model file not found: %s" % model_path)

    want_ov = None
    if provider_override:
        ov_mode = str(provider_override).lower()
        if ov_mode not in ("cpu", "gpu", "openvino"):
            raise RuntimeError(
                "Unknown provider %r (use cpu|gpu|openvino)"
                % provider_override)
        if ov_mode in ("gpu", "openvino"):
            want_ov = "gpu" if ov_mode == "gpu" else "cpu"
        elif os.environ.get("BAKUSHI_OV", "1") not in ("0", "false", "no"):
            # 'cpu': prefer native OpenVINO CPU, keep ORT CPU as fallback.
            want_ov = "cpu"
    if want_ov == "gpu":
        # Known-broken model? (persisted from a previous GPU attempt - the
        # Intel GPU plugin cannot build the fp16-weights graph and GPU.0
        # produces NaN.) Skip the multi-minute device probes and fall back
        # to CPU straight away.
        st = _load_provider_state()
        base = os.path.basename(model_path)
        if base in st.setdefault("gpu_broken_models", []):
            sys.stderr.write(
                "[BAKUSHI] GPU is known-broken for %s - using OpenVINO CPU."
                "\n" % base)
            sys.stderr.flush()
            want_ov = "cpu"
            provider_override = "cpu"
    if want_ov is not None:
        try:
            return _load_ov_meta(model_path, want_ov, cache_key, probe_hook)
        except Exception as exc:  # noqa: BLE001
            if provider_override == "gpu":
                # GPU was requested but no device could run this model
                # (e.g. the fp16-weights graph is unsupported by the Intel
                # GPU plugin). Fall back to OpenVINO CPU so separation still
                # completes; the warning lands in the app diagnostics.
                gpu_error = str(exc)[:300].replace("\n", " ")
                sys.stderr.write(
                    "[BAKUSHI] GPU failed on every device (%s) - falling "
                    "back to OpenVINO CPU.\n" % gpu_error)
                sys.stderr.flush()
                st = _load_provider_state()
                broken = st.setdefault("gpu_broken_models", [])
                if base not in broken:
                    broken.append(base)
                    _save_provider_state()
                try:
                    meta = _load_ov_meta(model_path, "cpu", cache_key,
                                         probe_hook)
                    meta["provider"] = "OpenVINO:CPU (GPU fallback)"
                    meta["gpu_error"] = gpu_error
                    return meta
                except Exception as exc2:  # noqa: BLE001
                    raise RuntimeError(
                        "GPU failed (%s) and CPU fallback failed too: %s"
                        % (gpu_error, exc2)) from exc
            if provider_override == "openvino":
                raise  # honest failure - the requested backend is broken
            # cpu: fall through to the ORT CPU EP below

    import onnxruntime as ort
    available = ort.get_available_providers()
    forced = None
    if provider_override:
        forced = _PROVIDER_ALIASES.get(str(provider_override).lower())
        if forced is None:
            raise RuntimeError(
                "Unknown provider %r (use cpu|gpu|openvino)"
                % provider_override)
        if forced not in available:
            raise RuntimeError(
                "Provider %s is not available. Available: %s"
                % (forced, ", ".join(available)))
    session = None
    used_provider = None
    failures = []
    tried = set()
    while session is None:
        candidate = None
        if forced is not None:
            candidate = forced if forced not in tried else None
        else:
            # Auto path: try the last-known-good provider FIRST, then the
            # remaining non-failed ones in preference order: OpenVINO is
            # the primary backend, the ORT CPU EP is the fallback.
            st = _load_provider_state()
            order = []
            last = st.get("last_good")
            if last and last in available and last not in st["failed"]:
                order.append(last)
            for prov in ("OpenVINOExecutionProvider", "CPUExecutionProvider"):
                if prov in available and prov not in st["failed"] \
                        and prov not in order:
                    order.append(prov)
            candidate = next((p for p in order if p not in tried), None)
        if candidate is None:
            raise RuntimeError(
                "No usable ONNX execution provider. Available: %s. Details: %s"
                % (", ".join(available), " | ".join(failures)))
        if probe_hook is not None:
            try:
                probe_hook(_PROVIDER_SHORT.get(candidate, candidate))
            except Exception:  # noqa: BLE001
                pass
        try:
            so = ort.SessionOptions()
            if candidate == "CPUExecutionProvider":
                # Leave cores for the Flutter UI + system so the app does
                # not freeze while a long song separates on CPU. On
                # throttling-prone laptops set BAKUSHI_ORT_THREADS (e.g. 2)
                # to trade speed for steadier sustained performance.
                # clamp(1, 4, cpus) matches INTERSECT's Windows config
                # (docs/RESEARCH.md).
                cores = os.cpu_count() or 2
                env_threads = int(os.environ.get(
                    "BAKUSHI_ORT_THREADS", "0") or 0)
                so.intra_op_num_threads = env_threads or max(1, min(cores, 4))
            if os.name == "nt":
                # INTERSECT's Windows ONNX Runtime configuration
                # (src/audio/StemSeparationJob.cpp, documented in
                # docs/RESEARCH.md): sequential execution, no memory-pattern
                # pre-planning, no CPU arena, and basic graph optimizations.
                # Makes long CPU sessions predictable with less memory churn
                # and no optimizer rewrites mid-run.
                so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
                so.enable_mem_pattern = False
                so.enable_cpu_mem_arena = False
                so.graph_optimization_level = \
                    ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
            session = ort.InferenceSession(model_path, so,
                                           providers=[candidate])
            # Probe-validate non-CPU providers (GPU backends can silently
            # produce zeros on unsupported models/machines). CPU is trusted.
            if candidate != "CPUExecutionProvider" and \
                    not _provider_sane(session):
                failures.append(
                    "%s: probe inference returned silence/error" % candidate)
                tried.add(candidate)
                session = None
                # Recorded even for forced runs: the probe result is real,
                # and the UI uses it to warn before the next GPU attempt.
                st = _load_provider_state()
                if candidate not in st["failed"]:
                    st["failed"].append(candidate)
                    _save_provider_state()
                continue
            # Report what the session ACTUALLY uses (a provider that fails
            # to load may silently fall back to CPU).
            used_provider = session.get_providers()[0]
            if forced is None:
                st = _load_provider_state()
                if st.get("last_good") != used_provider:
                    st["last_good"] = used_provider
                    _save_provider_state()
            if forced is not None and used_provider != forced:
                raise RuntimeError(
                    "Requested %s but session actually uses %s"
                    % (forced, used_provider))
        except Exception as exc:  # noqa: BLE001
            failures.append("%s: %s" % (candidate, exc))
            tried.add(candidate)
            session = None
            if forced is not None:
                raise RuntimeError(
                    "Forced provider %s failed: %s. Available: %s"
                    % (forced, exc, ", ".join(available)))
            continue

    inputs = session.get_inputs()
    if not inputs:
        raise RuntimeError("Model exposes no input tensor.")
    inp = inputs[0]
    inp_shape = list(inp.shape)
    segment = DEFAULT_SEGMENT
    if len(inp_shape) >= 3 and isinstance(inp_shape[2], int) and inp_shape[2] > 0:
        segment = int(inp_shape[2])
    input_fp16 = ("float16" in str(inp.type))

    outputs = session.get_outputs()
    out_names = [o.name for o in outputs]
    out_by_stem = {}
    for o in outputs:
        low = o.name.lower()
        for stem in STEM_ORDER_6:
            if stem in low and stem not in out_by_stem:
                out_by_stem[stem] = o.name

    # Resolve the stem list for this model (4- or 6-stem exports).
    ordered = None  # None => single concatenated output split in infer_chunk
    stem_names = None
    matched = len(out_by_stem)
    if matched == 6:
        stem_names = list(STEM_ORDER_6)
        ordered = [(s, out_by_stem[s]) for s in stem_names]
    elif matched == 4 and set(out_by_stem) == set(STEM_ORDER_6[:4]):
        stem_names = list(STEM_ORDER_6[:4])
        ordered = [(s, out_by_stem[s]) for s in stem_names]
    elif len(outputs) in (4, 6):
        # Positional fallback: unlabeled outputs in demucs order.
        stem_names = list(STEM_ORDER_6[: len(outputs)])
        ordered = [(s, outputs[i].name) for i, s in enumerate(stem_names)]
    elif len(outputs) == 1:
        oshape = [int(d) if isinstance(d, int) and d > 0 else -1
                  for d in outputs[0].shape]
        n = _stem_count_from_shape(oshape)
        if n is None:
            raise RuntimeError(
                "Cannot determine stem count from output shape %s. "
                "Expected (1, 4|6, 2, N) or (1, 8|12, N)." % (oshape,))
        stem_names = list(STEM_ORDER_6[:n])
    else:
        raise RuntimeError(
            "Unsupported model output layout: %d outputs named %s."
            % (len(outputs), ", ".join(out_names)))

    meta = {
        "session": session,
        "input_name": inp.name,
        "input_shape": inp_shape,
        "input_fp16": input_fp16,
        "output_names": out_names,
        "segment": segment,
        "stem_names": list(stem_names),
        "n_stems": len(stem_names),
        "ordered": ordered,
        "provider": used_provider,
        "providers_available": available,
        "model_size": os.path.getsize(model_path),
    }
    _model_cache[cache_key] = meta
    return meta


def infer_chunk(meta, chunk):
    """Run one (2, segment) chunk; return (n_stems, 2, segment) float32."""
    seg = meta["segment"]
    n_stems = meta["n_stems"]
    x = chunk[None, :, :]  # (1, 2, seg)

    result = np.zeros((n_stems, 2, seg), dtype=np.float32)

    # Native OpenVINO path (single concatenated output; the ORT OpenVINO EP
    # bridge is unusable for this model). Probe-validated at load time, and
    # a NaN guard here catches mid-run device flakiness.
    ov_engine = meta.get("ov_engine")
    if ov_engine is not None:
        t = ov_engine.infer(x.astype(np.float32))
        while t.ndim > 2 and t.shape[0] == 1:
            t = t[0]
        if t.ndim == 3 and t.shape[0] >= n_stems and t.shape[1] >= 2:
            n = min(seg, t.shape[2])
            for i in range(n_stems):
                result[i, :, :n] = t[i, :2, :n]
        elif t.ndim == 2 and t.shape[0] >= 2 * n_stems:
            n = min(seg, t.shape[1])
            for i in range(n_stems):
                result[i, :, :n] = t[i * 2:i * 2 + 2, :n]
        else:
            raise RuntimeError(
                "Unexpected OpenVINO output shape %s (need %d stems)."
                % (t.shape, n_stems))
        if not np.isfinite(result).all():
            raise RuntimeError(
                "OpenVINO produced NaN output on this device mid-run.")
        return result

    session = meta["session"]
    if meta["input_fp16"]:
        x = x.astype(np.float16)

    ordered = meta["ordered"]
    if ordered is not None:
        names = [n for _, n in ordered]
        outs = session.run(names, {meta["input_name"]: x})
        for i in range(len(ordered)):
            t = np.asarray(outs[i])
            if t.dtype != np.float32:
                t = t.astype(np.float32)
            while t.ndim > 2 and t.shape[0] == 1:
                t = t[0]  # drop batch dims
            if t.ndim != 2 or t.shape[0] < 2:
                raise RuntimeError(
                    "Unexpected per-stem output shape %s for stem %d."
                    % (t.shape, i))
            n = min(seg, t.shape[1])
            result[i, :, :n] = t[:2, :n]
    else:
        # Single concatenated output, e.g. (1, 6, 2, N) or (1, 12, N).
        t = np.asarray(session.run(None, {meta["input_name"]: x})[0])
        if t.dtype != np.float32:
            t = t.astype(np.float32)
        while t.ndim > 2 and t.shape[0] == 1:
            t = t[0]  # drop batch dims
        if t.ndim == 3 and t.shape[0] >= n_stems and t.shape[1] >= 2:
            # (stems, 2, samples) stem-major layout.
            n = min(seg, t.shape[2])
            for i in range(n_stems):
                result[i, :, :n] = t[i, :2, :n]
        elif t.ndim == 2 and t.shape[0] >= 2 * n_stems:
            # (2 * stems, samples) channel-pair layout.
            n = min(seg, t.shape[1])
            for i in range(n_stems):
                result[i, :, :n] = t[i * 2:i * 2 + 2, :n]
        else:
            raise RuntimeError(
                "Unexpected concatenated output shape %s (need %d stems)."
                % (t.shape, n_stems))
    return result


# --------------------------------------------------------------------------- #
# Separation (chunked, overlap-add)
# --------------------------------------------------------------------------- #

def cmd_separate(req):
    _cancel_event.clear()
    model_path = req.get("model_path")
    left = np.fromfile(req["left_path"], dtype=np.float32)
    right = np.fromfile(req["right_path"], dtype=np.float32)
    if left.size == 0 or right.size == 0:
        raise ValueError("Decoded PCM is empty. Re-upload the audio file.")
    frames = int(min(left.size, right.size))
    left = left[:frames]
    right = right[:frames]

    send_progress(req["id"], "loading", 0, 1, 0.0)
    meta = load_model(model_path, provider_override=req.get("provider"),
                      probe_hook=lambda p: send_progress(
                          req["id"], "probing-%s" % p, 0, 1, 0.0))
    seg = int(meta["segment"])
    n_stems = int(meta["n_stems"])
    stem_names = list(meta["stem_names"])
    hop = int(req.get("hop_samples", DEFAULT_HOP))
    out_dir = req.get("out_dir")
    os.makedirs(out_dir, exist_ok=True)
    # Fresh separation = fresh drums: drop any .prepunch backups from a
    # previous song so the punch toggle can never restore stale audio.
    try:
        import drum_punch
        drum_punch.clear_backups(
            os.path.join(out_dir, "drums_l.f32le"),
            os.path.join(out_dir, "drums_r.f32le"))
    except Exception:  # noqa: BLE001
        pass
    bench = bool(req.get("bench"))
    bench_times = []
    bench_skipped = 0
    t_run_start = time.time()

    send({"id": req["id"], "type": "event", "event": "model_meta",
          "data": {"provider": meta["provider"],
                   "input_name": meta["input_name"],
                   "input_shape": meta["input_shape"],
                   "output_names": meta["output_names"],
                   "input_fp16": meta["input_fp16"],
                   "segment": seg,
                   "stem_order": stem_names,
                   "model_size": meta["model_size"],
                   "providers_available": meta["providers_available"]}})

    # Mirror-pad so chunk edges line up with the Hann window lobes.
    pad = seg // 2
    total = frames + 2 * pad
    mix = np.zeros((2, total), dtype=np.float32)
    mix[0, pad:pad + frames] = left
    mix[1, pad:pad + frames] = right

    n_chunks = 1 if total <= seg else int(np.ceil((total - seg) / hop)) + 1
    out = np.zeros((n_stems, 2, total), dtype=np.float32)
    wsum = np.zeros(total, dtype=np.float32)
    window = np.hanning(seg).astype(np.float32)

    for k in range(n_chunks):
        if _cancel_event.is_set():
            raise Cancelled("Separation cancelled by user.")
        start = k * hop
        if start + seg > total:
            start = total - seg
            if start < 0:
                start = 0
        chunk = mix[:, start:start + seg]
        if chunk.shape[1] < seg:
            tmp = np.zeros((2, seg), dtype=np.float32)
            tmp[:, : chunk.shape[1]] = chunk
            chunk = tmp
        # Skip fully-silent chunks: their separated output is silence too,
        # and skipping them cuts minutes off songs with quiet sections
        # (intros, breaks, outros).
        if float(np.max(np.abs(chunk))) < 0.002:
            bench_times.append(0.0)
            bench_skipped += 1
            send_progress(req["id"], "separating", k + 1, n_chunks,
                          (k + 1) * 100.0 / n_chunks)
            continue
        t0 = time.time()
        stems = infer_chunk(meta, chunk)
        bench_times.append(time.time() - t0)
        out[:, :, start:start + seg] += stems * window
        wsum[start:start + seg] += window
        send_progress(req["id"], "separating", k + 1, n_chunks,
                      (k + 1) * 100.0 / n_chunks)

    eps = 1e-8
    out /= np.maximum(wsum, eps)[None, None, :]
    out = out[:, :, pad:pad + frames]

    results = {}
    for i, name in enumerate(stem_names):
        ch_l = np.ascontiguousarray(out[i, 0])
        ch_r = np.ascontiguousarray(out[i, 1])
        l_path = os.path.join(out_dir, "%s_l.f32le" % name)
        r_path = os.path.join(out_dir, "%s_r.f32le" % name)
        ch_l.tofile(l_path)
        ch_r.tofile(r_path)
        mono = (ch_l + ch_r) * 0.5
        mean_sq = float(np.mean(mono * mono)) if mono.size else 0.0
        rms = float(np.sqrt(mean_sq))
        peak = float(np.max(np.abs(mono))) if mono.size else 0.0
        results[name] = {
            "left_path": l_path, "right_path": r_path, "frames": frames,
            "rms": rms, "peak": peak,
            "silent": bool(rms < 1e-6),
            "has_nan": bool(np.isnan(mono).any()),
            "has_inf": bool(np.isinf(mono).any()),
        }
    send_progress(req["id"], "done", n_chunks, n_chunks, 100.0)
    result = {"stems": results, "chunks": n_chunks, "segment": seg,
              "hop": hop, "frames": frames, "stem_order": stem_names}
    if bench:
        result["bench"] = {
            "chunk_seconds": [round(t, 3) for t in bench_times],
            "skipped_chunks": bench_skipped,
            "chunks": n_chunks,
            "total_seconds": round(time.time() - t_run_start, 3),
            "peak_rss_mb": round(_peak_rss_mb(), 1),
            "provider": meta["provider"],
            "stem_count": n_stems,
            "model_size": meta["model_size"],
            "hop": hop,
            "segment": seg,
            "frames": frames,
        }
        send({"id": req["id"], "type": "event", "event": "bench",
              "data": result["bench"]})
    # Free the chunk buffers (~1 GB for a 5-minute song) before returning.
    try:
        del out, wsum, mix, window, left, right
    except NameError:
        pass
    # A compiled GPU model pins gigabytes of OpenCL memory - free it so
    # the system and the Flutter UI get that RAM back.
    _release_compiled_gpu(meta, (model_path, req.get("provider") or ""))
    _release_memory()
    return result


# --------------------------------------------------------------------------- #
# Selftest / server
# --------------------------------------------------------------------------- #

def cmd_hello(req):
    version = "%d.%d.%d" % sys.version_info[:3]
    try:
        import onnxruntime as ort
        providers = ort.get_available_providers()
    except Exception as exc:  # noqa: BLE001
        providers = []
        version += " (onnxruntime unavailable: %s)" % exc
    return {"python": version, "providers": providers,
            "sample_rate": SAMPLE_RATE,
            "provider_state": _load_provider_state()}


def selftest(model_path=None, infer_test=False):
    try:
        import av  # noqa: F401
        av_ok = True
    except Exception as exc:  # noqa: BLE001
        av_ok = False
        print("PyAV missing: %s" % exc)
    try:
        import onnxruntime as ort
        providers = ort.get_available_providers()
        print("onnxruntime: %s" % ort.__version__)
        print("available providers: %s" % ", ".join(providers))
    except Exception as exc:  # noqa: BLE001
        print("onnxruntime unavailable: %s" % exc)
        providers = []
    print("PyAV decode: %s" % ("OK" if av_ok else "MISSING"))
    if model_path:
        try:
            meta = load_model(model_path)
            print("model OK: provider=%s segment=%d input=%s fp16=%s"
                  % (meta["provider"], meta["segment"], meta["input_name"],
                     meta["input_fp16"]))
            print("output names: %s" % ", ".join(meta["output_names"]))
            print("stems detected: %d (%s)"
                  % (meta["n_stems"], ", ".join(meta["stem_names"])))
            if infer_test:
                # Deterministic sine mixture: also exercises the stem
                # mapping (expect at least one stem clearly non-silent).
                t_ = np.arange(meta["segment"], dtype=np.float32) \
                    / float(SAMPLE_RATE)
                ch = (0.3 * np.sin(2 * np.pi * 440.0 * t_)
                      + 0.2 * np.sin(2 * np.pi * 110.0 * t_)
                      + 0.1 * np.sin(2 * np.pi * 220.0 * t_)) \
                    .astype(np.float32)
                chunk = np.stack([ch, ch * 0.9])
                stems = infer_chunk(meta, chunk)
                parts = []
                for i, name in enumerate(meta["stem_names"]):
                    m = stems[i].reshape(2, -1)
                    rms = float(np.sqrt(np.mean(m * m)))
                    parts.append("%s=%.4f" % (name, rms))
                print("infer test (sine mix): " + ", ".join(parts))
        except Exception as exc:  # noqa: BLE001
            print("model load FAILED: %s" % exc)
    print("SELFTEST-DONE")


def server():
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        req_id = int(req.get("id", 0))
        req_type = req.get("type")
        if req_type == "stop":
            _cancel_event.set()
            continue
        try:
            if req_type == "hello":
                send_ok(req_id, cmd_hello(req))
            elif req_type == "decode":
                def _job():
                    try:
                        send_ok(req_id, cmd_decode(req))
                    except Cancelled:
                        send_error(req_id, "Decode cancelled by user.",
                                   "Run it again when you are ready.")
                    except Exception as exc:  # noqa: BLE001
                        traceback.print_exc(file=sys.stderr)
                        send_error(req_id, "Decode failed: %s" % exc,
                                   "The file may be corrupted or unsupported.")
                threading.Thread(target=_job, daemon=True).start()
            elif req_type == "separate":
                def _job():
                    try:
                        send_ok(req_id, cmd_separate(req))
                    except Cancelled:
                        send_error(req_id, "Separation cancelled by user.",
                                   "Run it again when you are ready.")
                    except Exception as exc:  # noqa: BLE001
                        traceback.print_exc(file=sys.stderr)
                        send_error(req_id, "Stem separation failed: %s" % exc,
                                   "Check the ONNX model path, input shape "
                                   "and backend.")
                threading.Thread(target=_job, daemon=True).start()
            elif req_type == "beat_analyze":
                # Runs INLINE on the server's main thread. librosa/scipy
                # imports inside a worker thread deadlock on Windows while
                # the main thread is blocked in sys.stdin.readline() (the
                # CRT stdin lock vs. C-extension DLL init) - verified with
                # faulthandler stack dumps.
                try:
                    import beat_analysis
                    stems_raw = req.get("stems") or {}
                    stems = {}
                    for name, pair in stems_raw.items():
                        if isinstance(pair, dict):
                            stems[name] = (pair.get("left"),
                                           pair.get("right"))
                        else:
                            stems[name] = pair
                    if req.get("mode") == "chop":
                        stem = req.get("stem") or "drums"
                        sensitivity = float(req.get("sensitivity", 0.6))
                        res = beat_analysis.chop(
                            stems, stem, sensitivity=sensitivity)
                    else:
                        res = beat_analysis.analyze(
                            stems,
                            with_drums_onsets=bool(
                                req.get("with_drums_onsets", True)))
                    send_ok(req_id, res)
                except Exception as exc:  # noqa: BLE001
                    traceback.print_exc(file=sys.stderr)
                    send_error(
                        req_id,
                        "Beat analysis failed: %s" % exc,
                        "librosa must be installed: "
                        "pip install -r sidecar/requirements.txt")
            elif req_type == "drum_punch":
                # Inline on the main thread for the same reason as
                # beat_analyze: scipy imports in a worker thread deadlock
                # while the main thread is blocked in stdin.readline().
                try:
                    import drum_punch
                    l_path = req.get("left_path")
                    r_path = req.get("right_path")
                    if not l_path or not r_path:
                        raise ValueError(
                            "drum_punch needs left_path and right_path")
                    if bool(req.get("enabled", True)):
                        res = drum_punch.apply_to_files(l_path, r_path)
                    else:
                        res = drum_punch.restore_files(l_path, r_path)
                    send_ok(req_id, res)
                except Exception as exc:  # noqa: BLE001
                    traceback.print_exc(file=sys.stderr)
                    send_error(req_id, "Drum punch failed: %s" % exc,
                               "scipy must be installed: pip install -r "
                               "sidecar/requirements.txt")
            else:
                send_error(req_id, "Unknown command: %s" % req_type)
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc(file=sys.stderr)
            send_error(req_id, "Sidecar command '%s' failed: %s" % (req_type, exc))


def _write_wav(path, left, right, sr):
    import wave
    pcm = np.empty(left.size * 2, dtype=np.int16)
    pcm[0::2] = np.clip(left * 32767.0, -32768, 32767).astype(np.int16)
    pcm[1::2] = np.clip(right * 32767.0, -32768, 32767).astype(np.int16)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(pcm.tobytes())


def run_cli_separate(audio_path, model_path, out_dir, hop, provider=None,
                     bench=False):
    """Command-line E2E: decode -> separate -> report per-stem RMS."""
    import tempfile
    if not model_path:
        print("ERROR: --model is required with --separate")
        sys.exit(2)
    with tempfile.TemporaryDirectory(prefix="bakushi_cli_") as work:
        try:
            dec = cmd_decode({"path": audio_path, "out_dir": work})
        except Exception as exc:  # noqa: BLE001
            print("decode FAILED: %s" % exc)
            sys.exit(1)
        print("decoded: %.2fs at %d Hz, channels=%d"
              % (dec["duration"], dec["sample_rate"], dec["channels"]))
        try:
            res = cmd_separate({"id": 1, "model_path": model_path,
                                "left_path": dec["left_path"],
                                "right_path": dec["right_path"],
                                "out_dir": work, "hop_samples": hop,
                                "provider": provider, "bench": bench})
        except Exception as exc:  # noqa: BLE001
            print("separate FAILED: %s" % exc)
            sys.exit(1)
        meta = _model_cache.get((model_path, provider or ""))
        if meta is None:
            meta = {"provider": "unknown", "segment": DEFAULT_SEGMENT,
                    "input_name": "?", "input_fp16": False}
        print("model: provider=%s segment=%d input=%s fp16=%s"
              % (meta["provider"], meta["segment"], meta["input_name"],
                 meta["input_fp16"]))
        for name in res["stem_order"]:
            d = res["stems"][name]
            flag = "SILENT!" if d["silent"] else "ok"
            print("stem %-7s rms=%.4f peak=%.3f %s"
                  % (name, d["rms"], d["peak"], flag))
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
            for name in res["stem_order"]:
                d = res["stems"][name]
                l = np.fromfile(d["left_path"], dtype=np.float32)
                r = np.fromfile(d["right_path"], dtype=np.float32)
                _write_wav(os.path.join(out_dir, "%s.wav" % name),
                           l, r, SAMPLE_RATE)
            print("wrote stems to %s" % out_dir)
        if bench and res.get("bench"):
            print("BENCH " + json.dumps(res["bench"]))


def main():
    _apply_process_priority()
    parser = argparse.ArgumentParser(description="Bakushi AI sidecar")
    parser.add_argument("--selftest", action="store_true",
                        help="report Python/onnxruntime/PyAV status and exit")
    parser.add_argument("--infer-test", action="store_true",
                        help="with --selftest --model: run one random chunk")
    parser.add_argument("--model", default=None,
                        help="ONNX model path (selftest or --separate)")
    parser.add_argument("--separate", default=None,
                        help="decode + separate an audio file and exit")
    parser.add_argument("--out", default=None,
                        help="output directory for --separate (WAV stems)")
    parser.add_argument("--hop", type=int, default=DEFAULT_HOP,
                        help="overlap-add hop in samples (default %d)"
                             % DEFAULT_HOP)
    parser.add_argument("--provider", default=None,
                        choices=["cpu", "gpu", "openvino"],
                        help="force one backend (benchmark mode; no silent "
                             "fallback): cpu=OpenVINO CPU, gpu=OpenVINO GPU "
                             "(probe-validated device), openvino=OV CPU")
    parser.add_argument("--bench", action="store_true",
                        help="with --separate: emit per-chunk timings, total "
                             "time and peak RSS as a BENCH line")
    args = parser.parse_args()
    if args.selftest:
        selftest(args.model, infer_test=args.infer_test)
        return
    if args.separate:
        run_cli_separate(args.separate, args.model, args.out, args.hop,
                         provider=args.provider, bench=args.bench)
        return
    server()


if __name__ == "__main__":
    main()
