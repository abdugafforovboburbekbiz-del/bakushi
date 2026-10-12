# Troubleshooting

Every failure surfaces in two places: the **Diagnostics panel console** at
the bottom of the app, and an inline status in the panel where it happened.

## "Python 3.10-3.12 was not found on this machine."

- Install Python 3.11 and check **"Add python.exe to PATH"** during install.
- Then `pip install -r sidecar/requirements.txt` (see `docs/SETUP_PYTHON.md`).
- Restart the app.

## "Model file not found."

- Place the verified export at `assets/models/htdemucs_6s.onnx` or use
  **Choose model file** in the Processing panel (see `docs/MODEL_SETUP.md`).
  The chosen path is remembered across restarts.
- Verify the file is the real export: size must be 258,159,781 bytes.
- The Diagnostics console prints every location the app checked.

## "No usable ONNX execution provider."

- Run `python sidecar/bakushi_sidecar.py --selftest` and check the provider
  list.
- CPU and GPU both need `onnxruntime-openvino` + `openvino`
  (the native OpenVINO runtime does the work; the ORT EP bridge is broken
  for this model). Install via: `pip install -r sidecar/requirements.txt`.
- If the machine has none of them, the app reports
  "This machine cannot run the local separation model..." - install the
  packages above.

## "Unsupported file type: .xxx"

Only WAV / MP3 / OGG / M4A are accepted. Convert the file first.

## "Decoded audio is empty" / "The file contains no audio stream"

The file is corrupt or has no audio track. Try another file.

## "Stem separation failed: ..."

- Check the model path, input shape, and backend (shown in Diagnostics).
- Look at the sidecar stderr in the Diagnostics console - it contains the
  real ONNX Runtime error.
- A model exported for a different segment length is handled automatically
  only when the segment is visible in the input shape; otherwise update
  `MODEL_SEGMENT_SAMPLES` / `MODEL_HOP_SAMPLES` in `lib/config.dart`.

## "Model inference returned silent output..."

The model ran but produced zeros for every stem. Check the model format,
tensor shape, output indexing, and backend. Try another export. The app will
not substitute fake audio.

## "Input is too long for the prototype"

Raise `AppConfig.maxInputSeconds` in `lib/config.dart` on a machine with
enough RAM, or trim the song. The cap is 300 s (5 min). A full 5-minute
separation keeps ~2 GB of audio in memory across the app and the sidecar.

## Separation is very slow

- Long songs now use the demucs-reference hop (0.25 overlap → ~5.85 s
  stride): a 5-minute song is ~46 chunks instead of ~133.
- On laptops the CPU may thermal-throttle during long runs: chunk times can
  grow (e.g. 2.5 s → 6 s). The run still completes - watch the ETA instead
  of the percentage. On throttling-prone machines set the environment
  variable `BAKUSHI_ORT_THREADS=2` before launching the app to reduce heat
  with steadier (but slower) performance.
- On Intel GPUs the app runs native OpenVINO. GPU choice = the
  probe-validated device (on Iris Xe the first device GPU.0 can return
  NaN; the sidecar validates and switches to GPU.1 automatically - see
  docs/OPENVINO_SETUP.md). CPU choice = OpenVINO CPU, about 2x the old
  ORT CPU. On a CPU-only machine a 5-minute song can take 10-30+ minutes
  when throttled.

## App froze AFTER separation finished (results shown, then nothing responds)

The UI had three stall sources at the end of a long run, all fixed:

1. The sidecar kept the compiled OpenVINO GPU model (several GB of OpenCL
   memory) alive for its whole lifetime. It is now freed after every GPU
   separation (`BAKUSHI_KEEP_GPU_MODEL=1` keeps it cached; the next run
   then pays the ~90 s device compile again, with progress shown).
2. Working-set trims (`SetProcessWorkingSetSize(-1,-1)`) ran synchronously
   on the UI thread. They now run in a background isolate.
3. The waveform painter drew every peak bucket of the whole song
   (~58k segments per row). It now only paints the visible viewport.

Note: after separation the 16 pads are intentionally EMPTY until you assign
slices to them (select a slice in a waveform, then "Assign to next empty
pad"). Auto-fill is a planned feature.

## App "froze" on the first separation ("Loading model ..." with nothing happening)

The first model load compiles OpenVINO kernels for each GPU device it
probes (GPU.0 then GPU.1 on Iris Xe), which can take a couple of minutes
with no output, which looks exactly like a freeze. Progress text shows
"Testing OpenVINO GPU GPU.x backend ..." during this phase, and the
provider-state cache + last-good GPU device make later loads fast.

Fixed by the provider-state cache:

- The sidecar remembers the last working provider and skips previously failed
  ones, persisted in `%LOCALAPPDATA%\Bakushi\provider_state.json`. Delete the
  file to force a fresh probe of all backends.
- While probing, the app now shows "Testing <backend> backend ..." and then
  "Loading model ..." so the wait is visible instead of blank.
- The first-ever load on a fresh machine may still probe once; after that,
  model loads take seconds.

## Browse button froze / no file dialog appeared

- This app uses the official `file_selector` plugin (COM dialog on the
  platform thread) — the old `file_picker` isolate approach could hang the
  app with HRESULT 0x80010106.
- If a dialog still does not appear, look for "File picker failed" in the
  Diagnostics console and restart the app.

## "Native audio engine not found (bakushi_engine.dll)"

- Rebuild the Windows runner: `flutter build windows --release` (or
  `flutter run -d windows`). CMake builds the DLL from `native/engine` and
  copies it next to the exe.
- Running from a debug build requires the debug DLL next to the debug exe
  (handled by the same POST_BUILD copy).

## Audio device failed to initialize

- Check that a default Windows output device exists and is not disabled.

## Pads don't sound / no audio at all

- Confirm the Diagnostics header shows "Audio engine: ok" and "Backend" is
  not "Unsupported".
- Check Windows volume mixer for the app.
- Empty pads intentionally do nothing (they show "No slice assigned").
