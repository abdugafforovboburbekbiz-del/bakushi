"""Native OpenVINO fallback test (bypasses the ORT EP bridge entirely)."""
import os
import time

import numpy as np

import openvino as ov

_OV_LIBS = os.path.join(os.path.dirname(ov.__file__), "libs")
if os.path.isdir(_OV_LIBS):
    os.add_dll_directory(_OV_LIBS)
    os.environ["PATH"] = _OV_LIBS + os.pathsep + os.environ.get("PATH", "")

MODEL = r"assets\models\htdemucs_4s.onnx"
core = ov.Core()
print("devices:", core.available_devices)
x = (np.random.default_rng(0).standard_normal((1, 2, 343980)) * 0.1).astype(np.float32)

for device, cfg in [("CPU", {}), ("GPU", {}),
                    ("GPU", {"INFERENCE_PRECISION_HINT": "f16"})]:
    t0 = time.time()
    try:
        model = core.read_model(MODEL)
        compiled = core.compile_model(model, device, cfg)
        req = compiled.create_infer_request()
        inp = compiled.input(0)
        req.set_tensor(inp, ov.Tensor(x))
        req.infer()
        out = req.get_tensor(compiled.output(0))
        y = np.asarray(out.data, dtype=np.float32)
        print("%s %s OK load=%.1fs run=%.2fs shape=%s max=%.4f" %
              (device, cfg or "", time.time() - t0,
               time.time() - t0, y.shape, float(np.abs(y).max())))
        t1 = time.time()
        req.infer()
        print("    second run=%.2fs" % (time.time() - t1))
    except Exception as e:  # noqa: BLE001
        print("%s %s FAILED after %.1fs: %s" %
              (device, cfg or "", time.time() - t0, str(e)[:200]))
