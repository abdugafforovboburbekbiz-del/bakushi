# Python sidecar setup

The app runs a small local Python process (`sidecar/bakushi_sidecar.py`) that
decodes audio (PyAV/FFmpeg) and runs ONNX inference (onnxruntime + the
native OpenVINO runtime). OpenVINO is the primary backend, the ORT CPU EP
is the automatic fallback. DirectML was removed (all-zeros on Intel Iris
Xe - see docs/BENCHMARKS.md).

## 1. Install Python 3.11

- Download from https://www.python.org/downloads/windows/
- During install: check **"Add python.exe to PATH"**.

Verify:

```powershell
python --version
```

Should print something like `Python 3.11.x`. The app also accepts 3.10 or
3.12 (and `py -3`).

## 2. Install sidecar packages

```powershell
cd <repo folder>
pip install -r sidecar/requirements.txt
```

Packages:

| Package | Purpose |
| --- | --- |
| `numpy` | PCM buffers, windowing |
| `av` (PyAV) | decode WAV/MP3/OGG/M4A (bundles FFmpeg, resample to 44.1 kHz) |
| `onnxruntime-openvino` | bundles ORT + the OpenVINO EP (see pairing below) |
| `openvino` | native OpenVINO runtime used for inference |
| `scipy` | drum punch DSP chain (kept out of requirements, install with it) |

> Working pairing: `onnxruntime-openvino == 1.24.1` + `openvino == 2025.4.1`.
> If the native OpenVINO runtime is missing, the sidecar automatically
> falls back to the ORT CPU EP.

## 3. Self-test

```powershell
python sidecar/bakushi_sidecar.py --selftest
```

Expected output shows the available providers, e.g.:

```
onnxruntime: 1.xx.x
available providers: OpenVINOExecutionProvider, DmlExecutionProvider, CPUExecutionProvider, ...
PyAV decode: OK
SELFTEST-DONE
```

With a model in place, add `--model <path>` to also verify model loading,
provider choice and the detected stem mapping:

```powershell
python sidecar/bakushi_sidecar.py --selftest --model C:\path\to\model.onnx
```

Expected: `stems detected: 6 (drums, bass, other, vocals, guitar, piano)`.
Add `--infer-test` to run one random 7.8 s chunk and print per-stem RMS.

Full end-to-end test without the Flutter app:

```powershell
python sidecar/bakushi_sidecar.py --separate song.wav --model C:\path\to\model.onnx --out stems
```

## Notes

- The sidecar is started automatically when you click **Load Audio** or
  **Separate Stems**. If Python is missing, the app logs a clear error in the
  Diagnostics panel.
- Communication is newline-delimited JSON over stdin/stdout; PCM is exchanged
  as little-endian float32 files in a temp folder. Nothing is sent over the
  network.
