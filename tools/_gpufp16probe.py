"""Probe the fp16-weights 4-stem model on OpenVINO GPU devices:
full compile errors + optional precision hints + GPU.0 check."""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "sidecar"))
import bakushi_sidecar as bs  # noqa: E402

MODEL = os.environ.get(
    "BAKUSHI_MODEL",
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "..", "assets", "models",
                                  "htdemucs_fp16weights.onnx")))


def main():
    ov = bs._ov_bootstrap()
    core = ov.Core()
    print("devices:", core.available_devices)
    model = core.read_model(MODEL)
    probe_x = bs._ov_probe_input(343980)

    for dev in core.available_devices:
        for cfg in (None, {"INFERENCE_PRECISION_HINT": "f16"}):
            label = "%s%s" % (dev, "" if cfg is None else "-f16hint")
            t0 = time.time()
            try:
                compiled = core.compile_model(model, dev, config=cfg or {})
                req = compiled.create_infer_request()
                req.set_tensor(compiled.input(0), ov.Tensor(probe_x))
                req.infer()
                y = np.asarray(req.get_tensor(compiled.output(0)).data)
                ok = bool(np.isfinite(y).all()) and float(np.abs(y).max()) > 1e-6
                print("%-22s OK compile=%.1fs infer=%.1fs finite=%s max=%.4f"
                      % (label, time.time() - t0, time.time() - t0, ok,
                         float(np.abs(y).max()) if y.size else 0))
            except Exception as exc:
                msg = str(exc)[:260].replace("\n", " ")
                print("%-22s FAIL %.1fs: %s" % (label, time.time() - t0, msg))
        # drop the compiled graph before the next device
        try:
            del compiled, req
        except Exception:
            pass


if __name__ == "__main__":
    main()
