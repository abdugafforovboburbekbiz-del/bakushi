"""Deep-check native OpenVINO: CPU correctness vs ORT, GPU NaN scope."""
import os
import time

import numpy as np

import openvino as ov
import onnxruntime as ort

_OV_LIBS = os.path.join(os.path.dirname(ov.__file__), "libs")
if os.path.isdir(_OV_LIBS):
    os.add_dll_directory(_OV_LIBS)
    os.environ["PATH"] = _OV_LIBS + os.pathsep + os.environ.get("PATH", "")

MODEL = r"assets\models\htdemucs_4s.onnx"
rng = np.random.default_rng(0)
x = (rng.standard_normal((1, 2, 343980)) * 0.1).astype(np.float32)

# Reference: ORT CPU.
so = ort.SessionOptions()
so.intra_op_num_threads = 4
s_ref = ort.InferenceSession(MODEL, so, providers=["CPUExecutionProvider"])
t0 = time.time()
y_ref = np.asarray(s_ref.run(None, {"mix": x})[0], dtype=np.float32)
print("ORT-CPU reference run %.2fs" % (time.time() - t0))

core = ov.Core()
model = core.read_model(MODEL)


def run(device, cfg, n=3):
    compiled = core.compile_model(model, device, cfg)
    req = compiled.create_infer_request()
    inp = compiled.input(0)
    req.set_tensor(inp, ov.Tensor(x))
    req.infer()
    times = []
    for _ in range(n):
        t0 = time.time()
        req.infer()
        times.append(time.time() - t0)
    y = np.asarray(req.get_tensor(compiled.output(0)).data, dtype=np.float32)
    return times, y


def report(name, times, y):
    a = y_ref.ravel()
    b = y.ravel()
    finite = np.isfinite(b)
    nan_frac = float((~finite).mean())
    if finite.all():
        corr = float(np.corrcoef(a, b)[0, 1])
    else:
        bb = np.where(finite, b, 0.0)
        corr = float(np.corrcoef(a, bb)[0, 1])
    per_stem = []
    for s in range(y.shape[1]):
        seg = y[0, s]
        segnan = float(np.isnan(seg).mean())
        segmax = float(np.nanmax(np.abs(seg))) if np.isfinite(seg).any() else 0.0
        per_stem.append("stem%d nan=%.4f max=%.3f" % (s, segnan, segmax))
    print("%-22s runs=%s  corr=%.4f  nan_frac=%.4f\n    %s" %
          (name, ["%.2f" % t for t in times], corr, nan_frac,
           "  ".join(per_stem)))


for name, device, cfg in [
    ("OV-CPU", "CPU", {}),
    ("OV-GPU.0", "GPU.0", {}),
    ("OV-GPU.0-f16", "GPU.0", {"INFERENCE_PRECISION_HINT": "f16"}),
    ("OV-GPU.1", "GPU.1", {}),
    ("OV-AUTO", "AUTO", {}),
]:
    t0 = time.time()
    try:
        times, y = run(device, cfg)
        print("  load %.1fs" % (time.time() - t0), end=" ")
        report(name, times, y)
    except Exception as e:  # noqa: BLE001
        print("%-22s FAILED after %.1fs: %s" % (name, time.time() - t0,
                                                str(e)[:150]))
