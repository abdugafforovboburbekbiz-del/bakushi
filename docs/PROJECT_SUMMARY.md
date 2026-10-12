# Bakushi — Full Project Summary (2026-10-10)

## 1. What Bakushi is
A Flutter Windows desktop app that performs REAL LOCAL AI music source
separation (HTDemucs ONNX via a Python sidecar) into 6 stems (vocals, drums,
bass, other, guitar, piano), plus a 16-pad MPC sampler, waveforms,
beat-locked auto-divide, WAV export, and a local song library. Goal: an
"automatic MPC" - drop a song, get separated beats/instruments, and
auto-divide them onto 16 pads with beat-locked math.

## 2. The stack (final)
- Flutter Windows desktop (Dart SDK ^3.13.1), Material 3 dark theme.
- Python 3.11.9 sidecar (`sidecar/bakushi_sidecar.py`): decode (PyAV) +
  inference (onnxruntime-openvino 1.24.1; native OpenVINO runtime used for
  both CPU and GPU choices — see docs/OPENVINO_SETUP.md).
  NDJSON over stdin/stdout, PCM passed as f32le files in a temp dir.
- Model: `htdemucs_6s.onnx` (258,159,781 bytes, StemSplitio, MIT).
  Input `mix (1,2,343980)` fp32; output `stems (1,6,2,343980)`, order:
  drums, bass, other, vocals, guitar, piano. VERIFIED COMPATIBLE.
- Native C engine `native/engine/bakushi_engine.c` (miniaudio WASAPI mixer)
  via dart:ffi. Voice ids: pads 0-15, stems 100-105, original 200.
  BA_MAX_BUFFERS 256. BA_TRACE gated by _DEBUG.
- Library: raw f32le per channel (650 MB per 5-min song) + meta.json +
  state.json, under <appSupport>/library/<slug>/.
- Plugins: file_selector (browse/save), desktop_drop, path_provider, ffi.

## 3. The freeze saga — every problem and its definitive root cause
1. "Browse froze the app" — file_picker (even 12.x) spawns an isolate that
   calls CoInitializeEx(STA); already-MTA isolate throws HRESULT 0x80010106,
   the isolate dies and `port.first` hangs forever. FIX: official
   file_selector plugin (COM dialog on platform thread). file_picker removed.
2. "Play Original did nothing" — C BA_MAX_BUFFERS was 128 but originalVoiceId
   = 200 → ba_load_buffer rc=-1 → exception swallowed → silent no-op.
   FIX: BA_MAX_BUFFERS 256. Verified playhead advancing.
3. "Froze during separation" (perception) — UI was actually ALIVE; the busy
   ModalBarrier blocked all input so it FELT frozen. FIX: click-through
   IgnorePointer overlay; app fully usable while separating.
4. "Froze during separation" (real) — CPU starvation: inference saturated all
   cores for minutes. FIX: sidecar BELOW_NORMAL_PRIORITY_CLASS +
   intra_op_num_threads = min(cores-1, 4); per-chunk progress + elapsed/ETA.
5. "Froze when separation finished" — PCM16 WAV encode loops (7 files x 23M
   samples) + 325 MB single waveform isolate transfer + immediate auto-save.
   FIX: raw f32le library storage (O(1) views), waveform peaks computed one
   row at a time, auto-save delayed 3 s.
6. "App stuck at 75%" — thermal throttling on Intel Iris Xe laptop: chunk
   time grew 2.3 s → 6 s; the run was NOT stuck (`ui alive` kept printing).
   FIX: ETA + avg s/chunk in progress text, 60 s stall watchdog warning,
   BAKUSHI_ORT_THREADS env override, docs note.
7. Freeze AFTER separation — RAM exhaustion (system paging): sidecar ~1 GB
   model session + ~800 MB buffers; app ~1.5 GB. FIX: sidecar
   _release_memory() (gc + SetProcessWorkingSetSize trim) + Flutter
   NativeEngine.trimWorkingSet() after separation/save. Use the RELEASE exe.
8. Startup hang — WASAPI enumeration stall. FIX: runApp() before state.init(),
   engine init via Isolate.run with 10 s timeout, "Retry audio engine" button.

## 4. Backend/provider findings (verified on this machine)
- DirectML on Intel Iris Xe (8 GB shared): returns ALL ZEROS silently or OOM
  8007000E on ConvTranspose_1. HONEST DEAD END. Uninstalled.
- ORT OpenVINO EP bridge (onnxruntime-openvino 1.24.1 + openvino 2025.4.1):
  runs but FAILS at runtime on this model ("Output names mismatch between
  OpenVINO and ONNX") - unusable.
- **Native OpenVINO (ov.Core) - LIVE, replaces both**: OV-CPU 1.44 s/chunk
  corr=1.0000; OV-GPU.1 1.08 s/chunk corr=0.9994 (fastest measured). The
  iGPU exposes TWO devices: GPU.0 is 100% NaN and is probe-rejected; GPU.1
  is clean. AUTO always picks GPU.0 - never use it. The sidecar validates
  every GPU device before use and remembers the winner
  (`last_gpu_device` in provider_state.json). See docs/OPENVINO_SETUP.md.
- CPU EP: works correctly (440 Hz sine → piano stem dominant). ~2.3 s per
  7.8 s chunk, throttles to ~6 s. 133 chunks for a 4-5 min song = 6-15 min.
- Wheel conflict: onnxruntime-directml bundles ORT; installing plain
  onnxruntime alongside silently drops DmlExecutionProvider. One wheel only.

## 5. Other bugs fixed
- PyAV 12+ resample returns a LIST and default "flt" is PACKED (doubled
  duration) → use format="fltp" + resample(None) flush.
- MS Store python stubs (exit 9009) → probe
  %LOCALAPPDATA%\Programs\Python\Python3{10,11,12}\python.exe.
- Empty pads did FFI work on tap → now fully inert (no notify/FFI).
- Native.addressOf(TypedData) not allowed for lookupFunction pointers →
  calloc+setAll copy kept.
- intl/pdf/latlong2-style export shadowing avoided (not hit here, but the
  Float32List import WAS missing in separation_service.dart → fixed).

## 6. Optimization round (latest changes)
- Sidecar skips silent chunks (max abs < 0.002) — intros/outros/breaks cost 0.
- AppConfig.modelHopSamplesLong = 132300 (3 s hop) for inputs > 120 s —
  ~1.5x fewer chunks, small quality trade (Demucs reference uses similar).
- separate(maxSeconds:) crops to the first N seconds — MPC hits are almost
  always in the first ~90 s. Default still 0 (full song) until wired to UI.
- **UI rework**: single 3-step wizard instead of 7 stacked panels.
  Step 1 Upload (Choose Song + drop zone + auto-decode + metadata +
  Play Original + waveform preview), Step 2 model chooser (Quality 6-stem
  fp32 vs Fast 4-stem int8 cards + Continue), Step 3 Separate (one big
  button, progress + ETA + Cancel; after completion: 16-pad grid + stem
  waveforms). No tabs/sidebars/settings/export/library by default;
  diagnostics live in a collapsible footer. Pipeline untouched.
- **Fast Mode model** built by `tools/quantize_model.py`: slices BOTH final
  projections (tdecoder.3 12->8 ch, decoder.3 24->16 ch) + both reshape
  constants 6->4, output (1,4,2,343980). Verified BIT-EXACT: max diff 0.0
  vs the 6-stem original's first 4 stems. Dynamic-int8 quantized variant
  `htdemucs_4s_int8.onnx` (182.5 MB, 4 stems drums,bass,other,vocals),
  corr 0.97 vs fp32. HONEST CAVEAT (benchmarked on cooled machine): int8
  is ~6x SLOWER on this laptop's ORT CPU EP (17.99 vs 3.07 s/chunk, RTF
  9.6x vs 1.65x) with NO RAM savings (~4.8 GB peak either way) -
  QLinearConv 1-D kernels are poorly optimized. Fast Mode therefore ships
  the fp32 4-stem slice; the int8 file stays as an option (swap names in
  lib/config.dart). Numbers in tools/benchmark_results.json.
- **Benchmark harness** `tools/benchmark.py`: fixed 30 s clip (kick/bass/
  melody/hats + 2 s silence) through model x backend matrix (cpu/gpu/openvino)
  via sidecar `--provider` (no silent fallback) + `--bench` (per-chunk
  seconds, total, RTF, peak RSS) -> tools/benchmark_results.json. 'cpu' now
  routes through native OpenVINO CPU, 'gpu' through the probe-validated OV
  GPU device.

## 7. Weaknesses (brutal, ranked)
1. Model weight class: htdemucs_6s fp32 258 MB is studio-grade. CPU RTF
   0.3-0.8 → minutes per song. ~80% of the speed problem. Fast mode =
   int8-quantized htdemucs 4-stem → 2-4x CPU.
2. Backend: DONE - native OpenVINO on both choices. CPU choice = OV-CPU
   (~2x ORT CPU, corr=1.0000); GPU choice = probe-validated OV GPU device
   (GPU.1 here, 1.08 s/chunk, corr=0.9994).
3. Whole-song + 6 stems + silence: wasteful for MPC. (Silent skip + hop +
   maxSeconds now implemented; auto-fill pads not yet wired.)
4. Memory floor is really 8 GB: ~1.3 GB peak arrays, 650 MB/song library.
   Future: 16-bit/FLAC storage, lazy stem loading.
5. Disk data path (raw f32le temp files): seconds on NVMe, low ROI to change.
6. ~~Manual pad assignment~~ DONE (2026-10-11): Fill Pads auto-divides any
   stem into beat-locked segments onto 16 pads (see 11).
7. No benchmark harness — backend decisions were made ad hoc.

## 8. Architecture verdict
The process topology (Flutter UI + Python ORT sidecar + C miniaudio via FFI)
is SOUND. A "custom build" of the runtime does NOT speed inference — model
weight class + EP backend set the speed. Rewriting inference in C++/Rust =
same ONNX Runtime underneath = zero gain, months of work. The custom work
that DOES matter: fast-mode quantized model, OpenVINO EP done right,
preview-window separation + auto-fill pads, benchmark harness.

## 9. Status
- flutter analyze: clean. Tests: 43/43 passing.
- Debug + release builds succeed (build\windows\x64\runner\Release\bakushi.exe
  recommended for real use).
- Model compatibility: verified (shapes match; full 133-chunk run completed).
- Fast Mode model: built + verified (bit-exact 4-stem slice; int8 quantized).
- Benchmark harness: implemented; results in tools/benchmark_results.json.
- Verification tooling: [action] tracing, ui-alive heartbeat, stall watchdog,
  BAKUSHI_AUTOTEST=1|full env-gated self-test, Start-Process log capture.

## 10. Roadmap (priority order)
1. ~~Fast mode.~~ DONE: 4-stem fp32 slice (bit-exact) ships as Fast Mode;
   int8 variant built + benchmarked but 6x slower on this CPU (see 6).
2. ~~OpenVINO EP done right.~~ DONE - but not the EP: the native OpenVINO
   runtime (the EP bridge fails on this model). CPU ~2x faster, GPU.1
   ~3x faster than the ORT CPU baseline (1.08 s/chunk).
3. ~~Preview-window separation (default ~90 s) + auto-slice -> auto-fill
   pads.~~ DONE in the Auto-Divide rework (2026-10-11, see 11); the
   ~90 s preview window is still open.
4. ~~Benchmark harness.~~ DONE - results: quality fp32 CPU RTF 1.65x
   (3.07 s/chunk); DML fails (silence probe); OpenVINO not installed.
5. 16-bit/FLAC library storage (halve disk + RAM).

## 11. Auto-Divide rework (2026-10-11)
The onset-based smart slicing (Hits/Loops/Phrases -> chop/loop modes) was
replaced with the 3-stage producer flow:
1. **Separate** (unchanged: OpenVINO sidecar, drum punch, 4/6 stems).
2. **Auto-Divide**: the sidecar returns only the beat grid (BPM + tracked
   beats + downbeats, `sidecar/beat_analysis.py`); pure Dart math
   (`lib/audio/analysis/division.dart`) divides the chosen stem into equal
   segments (1 Beat / 1 Bar / 2 Bars) and fills 16 pads (wrap with warning
   when fewer than 16; near-silent segments skipped).
3. **Human correct**: waveform drag handles (pad-linked slices update the
   pad live), nudge whole slices by 1/16 / 1/8 / 1 beat, long-press-drag
   pad swap, re-divide with a confirm dialog when pads hold manual edits.
Verified on droplit (92.29 BPM): boundaries sample-exact on grid lines,
16/16 pads, min RMS 0.053, post-fade loop seam jump 0.0000
(`tools/_dividecheck.py`). flutter analyze clean, 43/43 tests.

## 12. Strip-down (2026-10-11): pure stem separator
Everything after separation was DELETED by user request - Bakushi is now a
StemDeck-style stem separator:
- REMOVED: 16-pad MPC sampler + pad APIs, all slicing (Division, chop,
  loops), BPM/beat tracking (`sidecar/beat_analysis.py`, the
  `beat_analyze` sidecar command, librosa requirement), nudge/swap/
  auto-fill/re-divide, diagnostics panel, pad/slice models, and 22
  slicing/pad tests (44 -> 22).
- KEPT: upload + decode, HTDemucs separation (OpenVINO), drum punch,
  transport playback (TransportEngine, the stripped former PadEngine -
  pad voices remain in the C engine but are unused), mute/solo/volume,
  view-only waveform strips, per-stem + all WAV export, library storage
  (mixer settings only), autotest (BAKUSHI_AUTOTEST=1|full,
  BAKUSHI_AUTOTEST_LIBRARY_ID).
- UI: 3 steps - Upload (picker + drop + metadata + Play Original +
  waveform) -> Separate (one button + progress/ETA + backend chip) ->
  Stems (per-stem waveform + play/mute/solo/volume/export, Play All,
  Stop All, Export All, New Song). Errors are toasts only.
- New: AppState.newSong(), playAllStems/playSingleStem with correct gain
  routing (original-only vs stems-only), exportAllStems (folder),
  showToast/clearToast.
- flutter analyze clean, 22/22 tests.

## 13. Silent stems + 16-pad auto-cut (2026-10-11, Tasks 1-2)
- TASK 1: stems with RMS < AppConfig.silentStemRms (0.01) are hidden from
  Step 3 with the note "N stems detected (X were near-silent)"; a
  "Show silent stems" switch reveals them (data kept for export). Each
  row now shows its measured RMS. NOTE: on the saved droplit library all
  four stems exceed 0.01 (drums 0.1035, vocals 0.0904, bass 0.0325,
  other 0.0229) so none are hidden for THAT data - the threshold is one
  constant if a relative/looser rule is wanted.
- TASK 2 (Phase A): minimal 16-pad auto-cut. PadMode {hit, loop}
  (config.dart); pad_cut.dart computePadSegments (1 beat / 2 bars from the
  BPM scalar, pure math, exact grid); sidecar/beat_analysis.py restored
  as a BPM-only provider (beat_track + tempogram halving fix, inline
  beat_analyze command, librosa back in requirements); TransportEngine
  pad voices (loadPad/playPad/stopPad/stopAllPads/isPadPlaying);
  AppState.analyzeBpm/autoFillPads/triggerPad (loop toggle), padKeys
  auto-assigned in trigger order A S D F Q W E R Z X C V T G B Y
  (assignPadKey steals from other pads), _startPadPlayMonitor;
  PadsPanel (mode chips + stem dropdown + Auto-Fill + Stop All + 4x4
  grid with HIT/LOOP chips and clickable key labels); keyboard handler in
  home_page. Autotest: BAKUSHI_AUTOTEST_PADS=1 + _PADMODE=loop.
- Verified on droplit: BPM 92.29, 16 pads filled, every loop pad
  triggered + toggled through the engine, 2-bar segment = 229364 samples
  (5.201 s), boundaries exactly on the uniform grid, post-fade loop seam
  jump 0.0. flutter analyze clean, 30/30 tests.
