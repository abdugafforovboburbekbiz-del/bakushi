# OpenVINO — implemented (native runtime, not the ORT EP)

Status: **LIVE**. The GPU and CPU choices in the app now run OpenVINO's
native Python API (`ov.Core`), not the ONNX Runtime OpenVINO execution
provider. The ORT EP bridge is unusable for this model — see "Why native"
below.

## Why the app's GPU was broken

1. DirectML (`DmlExecutionProvider`) was proven dead on this machine (Iris
   Xe returned silent output / OOM). It was uninstalled to install
   OpenVINO, but the app's GPU button still sent `provider: 'dml'` — the
   sidecar answered "DmlExecutionProvider is not available" and the UI
   looked frozen at "loading".
2. The ORT OpenVINO EP (`onnxruntime-openvino`) fails at runtime on this
   model: `[OpenVINO-EP] Output names mismatch between OpenVINO and ONNX`
   (the EP bridge cannot map the dynamic-shape graph back to ONNX output
   names).
3. The Intel iGPU exposes TWO devices. `GPU.0` compiles and runs but
   produces **100% NaN**. `GPU.1` is clean and fast. `AUTO` (and the EP)
   pick GPU.0 → garbage.

## What is implemented (sidecar/bakushi_sidecar.py)

- **DLL bootstrap**: `_ov_bootstrap()` adds `<site-packages>/openvino/libs`
  to the DLL search path and PATH before anything imports onnxruntime
  (pip's openvino wheel keeps `openvino.dll` there; nothing else finds it).
- **Native engine**: `_OvEngine` + `_load_ov_meta()` compile the ONNX with
  `ov.Core().compile_model()` and run inference through `ov.Tensor`.
- **Device validation**: for `provider=gpu` every `GPU.*` device is
  compiled and probe-run; output must be finite and non-silent or the
  device is rejected. The first clean device is remembered as
  `last_gpu_device` in `provider_state.json` so later loads skip the broken
  ones.
- **Routing** in `load_model()`:
  - `gpu` → native OV GPU (validated device). Failure is raised honestly.
  - `cpu` → native OV CPU (≈2x ORT CPU), falls back to the ORT CPU EP if
    OpenVINO is missing or fails. `BAKUSHI_OV=0` forces the old ORT path.
  - `openvino` → native OV CPU, no fallback (benchmark honesty).
- **Per-chunk NaN guard**: a mid-run NaN check in `infer_chunk` fails fast
  instead of writing garbage stems.

## Measured on this machine (htdemucs_6s, tools/_ovtest4.py)

| Backend | chunk | result |
| --- | --- | --- |
| ORT CPU EP | 2.07 s | reference, corr=1.0000 |
| **OV CPU** | **1.44 s** | corr=1.0000 |
| OV GPU.0 | 2.71 s | **100% NaN — rejected** |
| **OV GPU.1** | **1.08 s** | corr=0.9994 ✓ |
| OV AUTO | 2.71 s | NaN (picks GPU.0) — never use AUTO |

GPU.1 is the working device: ~2x faster than ORT CPU and ~1.3x faster than
OV CPU. First load per device pays a ~75-100 s compile; subsequent loads in
the same sidecar process are instant (`_model_cache`).

## Pairing / install (unchanged)

- `onnxruntime-openvino==1.24.1` + `openvino==2025.4.1` (official pairing;
  one ORT runtime wheel only — never co-install DirectML).
- `pip install openvino` keeps runtime DLLs under `openvino/libs`; the
  sidecar bootstraps them itself, so no `setupvars.bat` shell is needed.

## CLI verification

```powershell
python sidecar/bakushi_sidecar.py --separate test_song.wav `
  --model C:\path\to\model.onnx `
  --out test_stems_gpu --provider gpu --bench
python sidecar/bakushi_sidecar.py --separate test_song.wav `
  --model C:\path\to\model.onnx `
  --out test_stems_cpu --provider cpu --bench
```

## Decision gate

Keep OpenVINO only if the benchmark shows a real win on this laptop's
thermally-limited CPU. The current quality-mode baseline: RTF ~1.65x
(3.07 s/chunk, cool machine) with the 2 s hop; with the new 0.75-stride hop:
RTF ~0.62x (2.65 s/chunk). If OpenVINO cannot beat that meaningfully, stay on
CPU EP and invest in the preview-window + auto-fill-pads path instead.
