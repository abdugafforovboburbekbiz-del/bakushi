# Architecture

```
+--------------------------------------------------------------------+
| Flutter UI (Dart)                                                   |
|   Upload -> Processing -> Mixer -> Waveform editor -> Pads -> Diag  |
+----------------------------+---------------------------------------+
                             | dart:ffi (bakushi_engine.dll)
              +--------------v--------------+   stdin/stdout NDJSON
              | NativeEngine / PadEngine    |        |
              | (miniaudio WASAPI mixer)    |        |  Process.start
              | pads 0..15, stems 100..105, |        |
              | original 200                |        |
              +-----------------------------+   +----v----------------+
                                                | Python sidecar        |
                                                |  decode (PyAV)        |
                                                |  separate (onnxruntime|
                                                |    OpenVINO/DirectML/ |
                                                |    CPU)               |
                                                +-----------------------+
```

## Where the uploaded audio becomes a tensor

1. **Upload**: `AppState.pickFile()/onFileDropped()` keeps the path only.
2. **Decode** (`lib/audio/decoder/decoder_service.dart`): `DecoderService`
   sends a `decode` command to the sidecar. `cmd_decode` in
   `sidecar/bakushi_sidecar.py` opens the file with PyAV, resamples to
   **44100 Hz stereo float32** and writes `decoded_l.f32le` /
   `decoded_r.f32le` into the temp work dir. Dart reads them back into
   `StereoAudio.left/right` (`Float32List`).
3. **Tensor layout** (`cmd_separate`): `[left, right]` is stacked to a
   `(2, N)` array. For every chunk the sidecar takes a `(2, segment)`
   window, pads it, adds the batch dimension -> `(1, 2, segment)` and feeds
   it to `session.run` under the model's real input name. If the model's
   input dtype is float16, the array is converted with `.astype(np.float16)`
   right before the call. This is where the uploaded audio literally becomes
   the ONNX input tensor.

## Where model outputs become stem audio

1. `infer_chunk` runs `session.run(output_names, feeds)` using the model's
   real output names (mapped to the six stems by keyword, demucs order as
   fallback; a single concatenated `(1, 6, 2, N)` or `(1, 12, N)` output
   is split into 6 channel pairs; 4-stem exports are handled the same way).
2. Outputs are cast to float32 and placed into a `(n_stems, 2, segment)`
   array.
3. Chunks are overlap-added with a Hann window and normalized by the
   accumulated window sum (`out / wsum`), then trimmed to the original
   length - **full duration is preserved**.
4. Each stem's channels are written to `<workdir>/<name>_{l,r}.f32le` and
   `SeparationService` (Dart) loads them into `StemAudio`, recomputes/checks
   RMS, peak, NaN/Inf and silence. All-silent output stops with an error
   instead of fake audio.

Chunking constants: `MODEL_SEGMENT_SAMPLES = 343980` (~7.8 s),
`MODEL_HOP_SAMPLES = 88200` (2.0 s overlap step), overridable in
`lib/config.dart`; the segment length is re-derived from the loaded model's
input shape whenever possible.

## How stems play back (transport)

1. **Buffers** (`lib/audio/engine/transport_engine.dart`): each stem's PCM
   is registered with `loadStem()`; the native copy is deferred until the
   first transport play (`_ensureStemsInEngine`) to keep memory pressure
   on the inference process.
2. **Play** (`AppState.playAllStems` / `playSingleStem` / `playOriginal`):
   `startTransport(startSec, durationSec, stemGains)` starts every loaded
   voice at the same frame with the mixer's gains (mute/solo/volume
   applied via `effectiveStemGain`). `playSingleStem` zeroes every other
   stem so one layer can be auditioned alone.
3. **Playhead** (`_startPolling`): a 33 ms timer polls the native engine's
   frame position and notifies listeners - the UI shows the moving
   playhead on every waveform strip.
4. **Stop/pause/seek**: `pauseTransport` stops all voices and remembers
   the position; `seekTransport` restarts playing voices at a new frame.

## Native engine

`native/engine/bakushi_engine.c` implements a voice mixer on one miniaudio
WASAPI device (float32 stereo 44100): per-voice linear-interpolation
playback with fade-in and fade-out. Pad voices 0..15 remain in the C code
but are unused by this UI. Commands from the UI are applied under a
CRITICAL_SECTION that is also held by the audio callback. Playback latency
is "low-latency local playback" (WASAPI), not "zero latency".

## Files that matter

| Concern | File |
| --- | --- |
| Constants (model path, segment, cap) | `lib/config.dart` |
| Models | `lib/models/*.dart` |
| DSP helpers | `lib/audio/dsp.dart` |
| WAV codec | `lib/audio/wav_codec.dart` |
| FFI bindings | `lib/audio/engine/native_engine.dart` |
| Transport engine | `lib/audio/engine/transport_engine.dart` |
| Sidecar protocol | `lib/sidecar/sidecar_client.dart` |
| Decode | `lib/audio/decoder/decoder_service.dart` |
| Separation + validation | `lib/audio/separation/separation_service.dart` |
| Export | `lib/audio/export/export_service.dart` |
| State | `lib/state/app_state.dart` |
| Library (atomic save, list, load) | `lib/state/library_store.dart` |
| Starter kit loader | `lib/state/starter_kit.dart` |
| Home shell (steps, saved songs list) | `lib/ui/home_page.dart` |
| Pads + editor + inspector UI | `lib/ui/panels/pads_panel.dart`, `pad_editor.dart`, `pad_inspector.dart` |
| Diagnostics panel | `lib/ui/panels/diagnostics_panel.dart` |
| Python sidecar | `sidecar/bakushi_sidecar.py` |
| C engine | `native/engine/bakushi_engine.c` |
