"""Quick OpenVINO device test: CPU vs GPU on the 4-stem model."""
import os
import time

import numpy as np

# The pip `openvino` wheel keeps its runtime DLLs in openvino/libs and ORT's
# OpenVINO EP cannot find them without this bootstrap (the full-installer
# setupvars.bat does the same thing).
import openvino
_OV_LIBS = os.path.join(os.path.dirname(openvino.__file__), "libs")
if os.path.isdir(_OV_LIBS):
    os.add_dll_directory(_OV_LIBS)
    os.environ["PATH"] = _OV_LIBS + os.pathsep + os.environ.get("PATH", "")

import onnxruntime as ort  # noqa: E402

MODEL = r"assets\models\htdemucs_4s.onnx"
x = (np.random.default_rng(0).standard_normal((1, 2, 343980)) * 0.1).astype(np.float32)

cases = [
    ("OV-CPU", [("OpenVINOExecutionProvider", {})]),
    ("OV-GPU", [("OpenVINOExecutionProvider", {"device_type": "GPU"})]),
    ("OV-GPU.0", [("OpenVINOExecutionProvider", {"device_type": "GPU.0"})]),
]

for name, providers in cases:
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    t0 = time.time()
    try:
        sess = ort.InferenceSession(MODEL, so, providers=providers)
        load = time.time() - t0
        actual = sess.get_providers()
        t0 = time.time()
        y = sess.run(None, {"mix": x})[0]
        run = time.time() - t0
        y = np.asarray(y, dtype=np.float32)
        print("%-8s OK  providers=%s load=%.1fs run=%.2fs max=%.4f" %
              (name, actual, load, run, float(np.abs(y).max())))
    except Exception as e:  # noqa: BLE001
        print("%-8s FAILED after %.1fs: %s" % (name, time.time() - t0,
                                               str(e)[:200]))
