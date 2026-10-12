# Model setup

The app runs a **real HTDemucs ONNX model** locally. Models are
intentionally not bundled with the repo and are loaded lazily, only when
you click **Separate Stems**.

## 1. The two supported models

| Model | File | Size | Stems | Use |
| --- | --- | --- | --- | --- |
| **4-Stem (Recommended for MPC)** | `htdemucs_fp16weights.onnx` | ~166 MB (fp16 weights, fp32 in/out) | drums, bass, other, vocals | Default. Best quality-per-stem, fastest. |
| **6-Stem (Guitar + Piano)** | `htdemucs_6s_fp16weights.onnx` | ~136 MB (fp16 weights, fp32 in/out) | + guitar, piano | Full mixes. Slower. |

Verified exports come from `StemSplitio/htdemucs-6s-onnx` on Hugging Face
(MIT; mirrored in `Acapellas/htdemucs-6s-onnx` and
`adowu/htdemucs-6s-onnx`).

- Tensor spec (the sidecar introspects all of this, nothing is hardcoded):
  - Input: `mix`, `(1, 2, 343980)`, float32 - stereo 44.1 kHz, 7.8 s segment
  - Output: `stems`, `(1, 4|6, 2, 343980)`, stem order
    `drums, bass, other, vocals[, guitar, piano]`

> The int8-quantized 4-stem variant was REMOVED: the 2026-10-11 benchmark
> proved it slower than fp16 on every backend on this machine (3.32x RTF
> on the ORT CPU EP). See `docs/BENCHMARKS.md`.

## 2. Place the files

Expected location (configurable in `lib/config.dart`):

```
assets/models/htdemucs_fp16weights.onnx        (default 4-stem)
assets/models/htdemucs_6s_fp16weights.onnx     (optional 6-stem)
```

Alternatives that also work:

- any path chosen in-app via **Choose model file** - the choice is
  **persisted across restarts** (settings file in the app support dir)
- `<exe folder>/assets/models/<file>` (release builds)
- `<exe folder>/<file>`

> Models are loaded **by path**; they are not part of the Flutter assets,
> so they never inflate the built executable.

## 3. Verify

```powershell
python sidecar/bakushi_sidecar.py --selftest --model assets/models/htdemucs_fp16weights.onnx
```

Expected:

```
model OK: provider=... segment=343980 input=... fp16=...
stems detected: 4 (drums, bass, other, vocals)
```

Add `--infer-test` to also run one random 7.8 s chunk through the model and
print per-stem RMS - a cheap check that the output mapping produces audio,
not zeros.

## 4. End-to-end without the Flutter app

```powershell
python sidecar/bakushi_sidecar.py --separate song.wav --model assets/models/htdemucs_fp16weights.onnx --out stems
```

Decodes the song, runs chunked overlap-add separation and writes
`stems\<name>.wav` for every stem, printing RMS/peak per stem.

## How the app adapts to the model

The sidecar never assumes names or shapes. It inspects the loaded session:

- **Input tensor**: name, shape (segment length is taken from dim 2 when
  present, otherwise `DEFAULT_SEGMENT = 343980`), float16/float32 dtype.
- **Output tensors**: mapped to stems by name keywords; unlabeled outputs
  fall back to demucs order. A single concatenated output is detected from
  its shape - `(1, 4|6, 2, N)` stem-major or `(1, 8|12, N)` channel pairs -
  and split into the right number of stems. Unsupported layouts raise a
  visible error instead of producing silence.

The app adapts to the model's stem count: separation returns the model's
own `stem_order`, and the mixer, waveform rows and exports follow it
(4 stems by default, 6 for the six-stem model).

If the model file is missing, the app shows a clear error and does not fake
audio. If the model returns silence for every stem, the app stops with the
message "Model inference returned silent output..."

## Hardware requirements

| | Minimum (songs <= 1-2 min) | Recommended (5-min songs) |
| --- | --- | --- |
| CPU | 4 cores, any x86-64 | 8+ cores |
| RAM | 8 GB | 16 GB (separation keeps ~2 GB of audio buffers) |
| GPU | none required | none required (OpenVINO CPU is primary) |
| Storage | ~170 MB model + temp files | ~750 MB temp during a 5-min separation |
| OS | Windows 10/11 | same |

Backend order: **OpenVINO (primary) -> ORT CPU (fallback)**. DirectML is
removed (all-zeros on Intel Iris Xe). See `docs/BENCHMARKS.md` for the
measured numbers.


