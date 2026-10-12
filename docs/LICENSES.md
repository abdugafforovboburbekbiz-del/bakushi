# External dependencies & licenses

Bakushi itself: your application code. This file lists the third-party
components it depends on.

## Dart packages (pubspec.yaml)

| Package | License |
| --- | --- |
| `ffi` | BSD-3-Clause |
| `file_picker` | MIT |
| `desktop_drop` | MIT |
| `path_provider` | BSD-3-Clause |
| `path` | BSD-3-Clause |
| `cupertino_icons` | MIT |
| Flutter SDK | BSD-3-Clause |

## Native C engine

| Component | License |
| --- | --- |
| `miniaudio.h` (mackron/miniaudio) | Public domain / MIT-0 (alternative) |
| `native/engine/bakushi_engine.{h,c}` | MIT (our code) |

## Python sidecar (sidecar/requirements.txt)

| Package | License | Role |
| --- | --- | --- |
| `numpy` | BSD-3-Clause | PCM buffers, windowing |
| `av` (PyAV) | BSD-3-Clause | decoding WAV/MP3/OGG/M4A |
| FFmpeg (bundled by PyAV wheels) | LGPL-2.1+ | demuxing/decoding/resampling |
| `onnxruntime` | MIT | ONNX inference (CPU EP) |
| `onnxruntime-openvino` | Apache-2.0 | OpenVINO execution provider |
| `onnxruntime-directml` | MIT | DirectML execution provider |
| OpenVINO runtime | Apache-2.0 | Intel GPU/CPU acceleration |

## Model

HTDemucs is the architecture from Meta's Demucs (MIT). You supply the ONNX
export; see the license of the Hugging Face repository you download it from
(e.g. `ModernMube/HTDemucs_onnx` is MIT, `rysertio/Demucs-onnx` is CC BY-NC).

No audio is uploaded to any server by this application.
