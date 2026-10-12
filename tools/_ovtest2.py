"""Workaround matrix for the ORT-OpenVINO 'Output names mismatch' error."""
import os
import time

import numpy as np

import openvino
_OV_LIBS = os.path.join(os.path.dirname(openvino.__file__), "libs")
if os.path.isdir(_OV_LIBS):
    os.add_dll_directory(_OV_LIBS)
    os.environ["PATH"] = _OV_LIBS + os.pathsep + os.environ.get("PATH", "")

import onnxruntime as ort  # noqa: E402

MODEL = r"assets\models\htdemucs_4s.onnx"
x = (np.random.default_rng(0).standard_normal((1, 2, 343980)) * 0.1).astype(np.float32)

cases = [
    ("OV-CPU+dynoff", "CPU", {"disable_dynamic_shapes": "True"}, "DISABLE_ALL"),
    ("OV-CPU+basic", "CPU", {}, "BASIC"),
    ("OV-GPU+dynoff", "GPU", {"disable_dynamic_shapes": "True"}, "DISABLE_ALL"),
    ("OV-GPU+basic", "GPU", {}, "BASIC"),
]

for name, device, opts, level in cases:
    so = ort.SessionOptions()
    so.graph_optimization_level = getattr(
        ort.GraphOptimizationLevel,
        "ORT_ENABLE_BASIC" if level == "BASIC" else "ORT_DISABLE_ALL")
    prov_opts = {"device_type": device, **opts}
    t0 = time.time()
    try:
        sess = ort.InferenceSession(
            MODEL, so,
            providers=[("OpenVINOExecutionProvider", prov_opts)])
        load = time.time() - t0
        t0 = time.time()
        y = sess.run(None, {"mix": x})[0]
        run = time.time() - t0
        y = np.asarray(y, dtype=np.float32)
        print("%-16s OK  providers=%s load=%.1fs run=%.2fs max=%.4f"
              % (name, sess.get_providers(), load, run, float(np.abs(y).max())))
    except Exception as e:  # noqa: BLE001
        print("%-16s FAILED after %.1fs: %s" % (name, time.time() - t0,
                                                str(e)[:160]))
