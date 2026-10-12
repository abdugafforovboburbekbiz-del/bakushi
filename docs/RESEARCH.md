# Research: what existing projects do, and what Bakushi should copy

Sources: GitHub repositories + official docs, fetched 2026-10-10.
No code was changed in Bakushi as part of this research.

---

## 1. StemDeck (github.com/stemdeckapp/stemdeck) — Apache-2.0

The closest product in spirit (drop a song, get 6 stems, mute/solo/loop/practice).
**Critical fact: StemDeck does NOT run an ONNX model for the 6-stem split.**
It runs the **PyTorch** Demucs `htdemucs_6s` via the `demucs` package.

### A. Model loading
- `app/pipeline/demucs_worker.py`: `model = get_model("htdemucs_6s")` (demucs.pretrained),
  `model.eval(); model.cpu()`. A **persistent worker process** loads the model once
  and serves jobs over stdin/stdout JSON (`{"source","job_dir","shifts"}`); reused
  across consecutive jobs on the same device, killed on cancel/failure (never reused
  after a failure — GPU state is not trusted).
- Input normalization: `wav = load_track(...); ref=wav.mean(0); wav=(wav-ref.mean())/ref.std()`
  and outputs denormalized: `sources*ref.std()+ref.mean()`.
- Output WAV: `save_audio(..., clip="rescale", bits_per_sample=16)`.
- The only ONNX in the stack: `UVR_MDXNET_KARA_2.onnx` (karaoke lead/backing split) via
  the `audio-separator` package (fresh subprocess per invocation, not persistent).
- Sanity checks: `load_or_heal()` in `app/core/model_cache.py` — if loading a checkpoint
  fails, delete cached artifacts and retry once (guards truncated downloads).
- `shifts`: 1 by default, 2 for "best" quality (demucs time-shift ensemble, ~2x cost).

### B. Chunking / overlap-add
- Delegated to Demucs itself: `apply_model(model, wav[None], device, shifts, split=True,
  overlap=0.25, transition_power=1., progress=True, num_workers=0, segment=None)`.
- Demucs defaults: segment ~7.8 s at 44.1 kHz, **overlap 0.25 → stride = 5.85 s**.
  (Bakushi uses a 2.0 s hop — ~3x more chunks than the reference tool. This is the single
  biggest legitimate speedup available: StemDeck's effective hop is 5.85 s.)
- No silent-chunk skipping in StemDeck.

### C. Memory management
- Worker-process isolation: model lives in a child process; killing it returns all RAM.
- Parent watchdog (`arm_parent_watchdog`): child exits when parent dies.
- Streamed waveform peaks (`app/pipeline/audio_stats.py::scan_stem`): `sf.blocks()` with
  `blocksize = frames // buckets`, constant memory even for 20-min stems (vs ~420 MB full
  `sf.read`). Golden test locks peaks to the old full-load output.
- Web playback: `chunkedAudioEngine.js` — 10 s chunks over HTTP Range requests,
  "keep previous + current chunk in cache", peak RAM ~28 MB vs ~420 MB full decode.
- `_pipeline_lock = asyncio.Semaphore(1)` — only ONE heavy job at a time.

### D. Waveform rendering
- Backend precomputes `peaks.json`: per-stem `[[min,max],...]`, `_PEAK_POINTS = 3000`
  (enough for 10x zoom at full panel width). Signed min/max per bucket (DAW-style
  mirror-symmetric waveform), + RMS from the same single pass (for stem presence).
- Frontend renders bars as SVG `<rect>`s in a `viewBox` (overview) and a `<canvas>`
  footer waveform; **one shared normalization across all stems** so loudness relations
  (drums tall, piano short) are preserved — explicitly rejected per-stem normalization.
- Zoom redraws from the cached peak array (never rescans PCM); playhead is a positioned
  overlay synced via the audio clock.

### E. (not applicable — no pads)

### F. Backend/EP handling
- Device model: persisted choice `auto|cuda|mps|cpu`; `get_demucs_device()` re-probes on
  `auto`; forcing cuda/mps **verifies availability first and refuses to persist otherwise**.
- GPU failure → **one loud CPU retry** ("GPU failed — retrying on CPU (slower)..."), with
  `job.gpu_fallback = True` and `compute_device = "cpu (fallback from cuda)"` persisted in
  job metadata. The project's own lesson (#247): "a fallback must never be silent".
- Stall watchdog: terminate demucs if stderr has no output for `TIMEOUT_DEMUCS_STALL`
  (30 min). Progress parsed from tqdm `NN%` lines on stderr; cancel = proc.terminate().

### Freeze-avoidance patterns worth copying
- Heavy ML in a separate process; UI process only supervises (stall watchdog + cancel).
- Persistent worker to amortize model load; kill-and-respawn on any failure.
- All long stages emit progress; stage timings recorded (`separate_startup`, etc.).

---

## 2. TagYourSample (tagyoursample.com) — closed source

- The Sampler and Studio features are **premium-locked**; the sampler page 404s
  anonymously. No public repository exists (GitHub search: 0 repos). Its public surface
  (Tagger, waveform pins, clip ✂, key/BPM detection) is a browser app.
- **A/B/C/D/F: not extractable from source.** The site exposes UX only: waveform with
  pinned tags, "Cut" → clip a fragment, key/BPM analysis, MP3/WAV export.
- E: pad/sampler logic — unverifiable. The standard implementation for this class of web
  sampler is Web Audio `AudioBufferSourceNode` (one per voice, `start(when, offset)`,
  `playbackRate` for pitch) — but **no source code confirms this for TagYourSample**;
  treat any such detail as an assumption, not a finding.

---

## 3. StemTube Desktop (benasterisk.github.io/stemtube-desktop-app) — MIT

### What it does (product-level findings)
- **1.4 MB installer**; on first launch the app downloads a self-contained engine
  (Python + PyTorch + CUDA + Demucs + madmom + Whisper + FFmpeg): ~600 MB CPU, ~3 GB
  NVIDIA GPU. Afterwards fully offline. GPU type detected at first launch.
- Separation: Demucs `htdemucs_6s` (PyTorch), CUDA acceleration with automatic CPU
  fallback. New "fine" mode = 3-stage pipeline (Demucs → DrumSep → MVSep Mega
  BS-RoFormer Wiener-mask heads, up to 17 stems, GPU-only, ~1.5 GB weights).
- Chords: hybrid BTC Transformer + madmom CRF, 170 chord types, real-time diagrams.
- Beats: madmom CNN + DBN (beats + downbeats + bar positions), manual tap-sync.
- Tempo: SoundTouch time-stretch with pitch correction (0.5–1.0x).
- Installer is **unsigned** — SmartScreen warning; engine zip hosted on GitHub Releases.
- Honest hardware gate: the 17-stem mode checks free VRAM (~4.5 GB needed) and says so
  plainly instead of hiding the option; "does not run on CPU" is explicit.
- (No sampler/slicer; waveforms and a full mixer only.)

---

## 4. Ultimate Vocal Remover v5 (Anjok07/ultimatevocalremovergui) — MIT

### Architecture
- One `separate.py` with a `SeperateAttributes` base class + per-architecture classes:
  `SeperateVR` (VR Architecture, multi-band), `SeperateMDX` (MDX-Net),
  `SeperateMDXC` (MDX-C TFC-TDF), `SeperateDemucs` (Demucs v1/v2/v3/v4 + vendored copy
  of demucs `apply.py`).
- **Every model is described by a `ModelData` object** (path, stem config, method,
  segment size, overlap, batch size, JSON param file for VR bands, TTA, denoise,
  secondary models, ensembles, cache keys). The UI is generated from the model list —
  this is the reference pattern for "many models, one pipeline".

### Key implementation details
- **ONNX**: MDX models can run through `ort.InferenceSession(model_path,
  providers=self.run_type)` where `run_type` is `['CPUExecutionProvider']` or
  `['CUDAExecutionProvider']` (chosen by device detection). Fallback to
  onnx2pytorch `ConvertModel` when the ONNX segment size does not match the UI setting.
- **DirectML**: torch-directml integration exists in the tree but is **commented out**
  (dead code) — i.e., even UVR5 gave up on DirectML; current builds use CUDA/CPU.
- Device logic: `cuda` if available, else `cpu`; `is_other_gpu` paths force demucs v3/v4
  back to CPU (non-CUDA unsupported).
- **MDX-C overlap-add** (`SeperateMDXC.demix`): `chunk_size = hop_length*(dim_t-1)`,
  `hop = chunk_size // overlap`; zero-pad both ends by `chunk_size - hop_size`;
  `mix.unfold(1, chunk_size, hop)`; accumulate into a zero tensor; final
  `estimated_sources[..., chunk_size-hop:-(pad+chunk_size-hop)] / overlap`. Direct,
  clean reference implementation.
- **VR architecture**: multi-band (4 bands), each band resampled, spectrogram → padded
  ROI windows with batch processing, masks applied to the ORIGINAL mix phase
  (`postprocess(mask, X_mag, X_phase)`) — phase is never synthesized; it comes from the
  mix. Optional TTA (half-window shifted second pass averaged).
- Memory: `clear_gpu_cache()` after every model run; per-model results cached to disk
  (`cached_source_callback`) to skip re-inference; progress per patch batch.

### F. EP order / fallback
- `run_type` list per model; no provider probing/validation — trust the backend.
- Device forced to CPU for demucs v3/v4 on non-CUDA GPUs (mps handled separately).

---

## 5. INTERSECT (tucktuckg00se/INTERSECT) — GPL-3.0 — **the closest to Bakushi**

A VST3/AU/standalone **sample slicer** with on-demand GPU-accelerated stem separation.
This is the only studied project that combines separation + slicing + a triggering
instrument, which makes it the single most relevant codebase.

### A. Model loading
- Catalog: `bs_roformer_sw_6stem.onnx` (BS-RoFormer SW 6-stem), downloaded on demand
  from GitHub Releases; catalog entry carries `sampleRate=44100`, `chunkSize=131072`,
  `overlapRatio=0.5`, 6 output roles (drums,bass,other,vocals,guitar,piano).
- **ORT is NOT bundled with the plugin.** It is a per-platform downloadable bundle
  (`onnxruntime-win-x64-directml.zip` etc.) loaded at runtime via `LoadLibraryExW(...,
  LOAD_WITH_ALTERED_SEARCH_PATH)` + `ORT_API_MANUAL_INIT`. This keeps the plugin zip in
  single-digit MB and lets the user pick CPU/DirectML/CUDA/MIGraphX/CoreML after install.
- Output tensor contract enforced: expected `[1, stems, 2, chunkSize]`, else hard error.
- "instrumental" = residual (original minus vocals), computed automatically.

### B. Chunking / overlap-add (exact, from `src/audio/StemSeparationJob.cpp`)
- `chunkSize = 131072` samples (~2.97 s @44.1k), `overlapRatio = 0.5` → **hop 65536**.
- Mirror-pad to `fullLen = (chunks-1)*hop + chunkSize`; per chunk:
  - fill `[1, 2, chunkSize]` input tensor, run session,
  - validate output shape each chunk,
  - **Hann window** (`makeHannWindow`) applied to the output, accumulated per stem;
  - `weightAccum[i] += window`; final divide `if (w > 1e-8) dst[i] /= w`;
  - trim padding back to original length.
- Cancel checked between chunks (`shouldCancel` atomic).
- Resample source to model rate before inference; stems resampled back for WAV export.
- Progress phases: preparing(0.1) → separating → writing(0.7–1.0) → importing.

### C. Memory
- Separation runs on a `juce::Thread` (background priority) — the audio thread is never
  blocked; the UI stays interactive during inference.
- Windows session options: `intra_op_num_threads = clamp(1,4,cpus)`,
  `ORT_SEQUENTIAL`, `DisableMemPattern()`, `DisableCpuMemArena()`,
  `graph_optimization_level = ORT_ENABLE_BASIC`. (DirectML **requires**
  DisableMemPattern + sequential execution.)
- Accumulation buffers allocated once on first chunk; per-chunk input buffer reused.

### D. Waveform rendering
- `SampleData.h::PeakMipmap` — **3 mipmap levels** of min/max peaks per sample, computed
  once at load; zoom levels pick the mip level (the standard approach to fast zoomed
  waveforms). Loading happens off the audio thread.

### E. Pad/sampler logic (the "16-pad grid" equivalent)
- Slices are regions of a sample with a MIDI mapping. **No auto-slicing on load**; three
  creation modes: Draw, Lazy chop (note-ons drop boundaries at the playhead),
  **Auto chop**: `SPLIT EQUAL` or `SPLIT TRANSIENTS` (detected transients).
- Default mapping: first slice = C2 (note 36), successive notes upward; `RESEQ` remaps.
- Per-slice parameter locks over sample-wide defaults (inheritance model): pitch,
  filter, envelope, loop, output bus; locked params override, unlatching re-inherits.
- **32 voices** (31 + 1 preview); voice stealing picks the lowest amp-envelope voice.
- Loop: ping-pong supported; **loop crossfade** (`FADE`, equal-power) smooths seams;
  `1SHOT` ignores note-off; `REV` reverse.
- **Mute groups = choke groups** (newest wins; group 0 disables). Identical semantics to
  Bakushi's choke groups.
- Pitch engines: Repitch (linear/cubic interp), Signalsmith, Bungee (granular).

### F. Backend/EP handling
- `configureExecutionProvider`: CPU = no provider appended; GPU = CUDA/MIGraphX/DML/
  CoreML per installed bundle; DML needs the sequential/no-mem-pattern options.
- On GPU failure at export: "GPU unavailable, used CPU instead" **warning surfaced in
  the header status bar** (never silent), plus honest pre-flight check that reports why
  GPU is unavailable.

---

## Answers to the six specific questions

1. **Does StemDeck use the same htdemucs_6s.onnx (258 MB)?**
   No. StemDeck uses the **PyTorch** htdemucs_6s checkpoint via the `demucs` package
   (`demucs_worker.py: get_model("htdemucs_6s")`). The 258 MB `htdemucs_6s.onnx` Bakushi
   uses is a third-party export (StemSplitio). Same architecture and weights, different
   runtime. Their only ONNX model is `UVR_MDXNET_KARA_2.onnx` (karaoke split).

2. **How does StemDeck handle "DirectML returns all zeros on Intel Iris Xe"?**
   It never meets the problem: no DirectML in their stack (PyTorch CUDA/MPS/CPU; the
   ONNX karaoke path is `audio_separator`, and they force CPU by setting
   `CUDA_VISIBLE_DEVICES=""`). UVR5 shipped torch-directml and then **commented it out**.
   INTERSECT ships DirectML bundles with the required `DisableMemPattern`+sequential
   options but shows no evidence of hitting the all-zeros bug (different model family).
   **Conclusion: no public workaround exists for htdemucs_6s ONNX + DirectML all-zeros
   on Iris Xe. Bakushi's probe-validation fallback (`_provider_sane`) is currently the
   state of the art for this exact combination — keep it.**

3. **Automatic transient/silence-based slicing?**
   - INTERSECT: `SPLIT TRANSIENTS` auto-chop exists (thresholds not published in docs;
     implementation lives in the repo's slice code).
   - StemDeck does not slice to pads, but has a fully parameterized transient pipeline
     worth copying wholesale (drum-stem beat refinement):
     - onset envelope: `librosa.onset.onset_strength(y, sr=22050, hop_length=512,
       aggregate=np.median)` for coarse; fine envelope for snap: `hop_length=32,
       n_fft=512, n_mels=64, aggregate=np.median` (~1.45 ms/frame).
     - peaks: `librosa.util.peak_pick` with `pre_max=15ms, post_max=15ms,
       pre_avg=45ms, post_avg=60ms, delta=1.5 * percentile(env, 90), wait=30ms`,
       then **parabolic sub-frame interpolation** (0.19 ms std-dev vs synthetic clicks).
     - grid logic: phase-flip check (support ratio 2.0), beat snap window ≤ 0.15 beat
       (cap 100 ms), max move 0.10 beat (cap 70 ms), interior gap fill, consistency
       pass (0.10-beat outlier threshold), edge extrapolation.
     - source preference: drums stem → original → mix.
     - Silence gating via RMS: e.g. drums RMS 0.008 in breakdowns vs 0.098 whole stem.

4. **Does TagYourSample use AudioBufferSourceNode?**
   Unverifiable: closed source, sampler is premium-locked, no repo. Its public UX
   (waveform pins, clip, key/BPM) gives no engine detail. `AudioBufferSourceNode`
   is the standard mechanism for this class of web sampler, but this is an assumption,
   not a finding.

5. **OpenVINO + onnxruntime-openvino version matching (DLL error 127)?**
   Yes — the rule is official and recent (onnxruntime.ai, OpenVINO EP docs):
   - onnxruntime-openvino **1.24.1 ↔ OpenVINO 2025.4.1**
   - 1.23.0 ↔ OpenVINO 2025.3
   - 1.22.0 ↔ OpenVINO 2025.1
   Plus: the full OpenVINO install must be in the environment (`setupvars.bat` on
   Windows) even for the pip wheel. Bakushi's earlier failure (ORT 1.24.4 with
   openvino 2025.2, no setupvars) violated both rules. Recommended test pairing for
   Bakushi: `onnxruntime-openvino==1.24.1` + `openvino==2025.4.1` + `setupvars.bat`
   (and never co-install `onnxruntime-directml` — wheel overwrite).

6. **Any project already combining separation + auto-slicing + pad sampler?**
   **INTERSECT** is the closest: separation (BS-RoFormer ONNX) + slicing (draw/lazy/
   auto-transients) + triggering instrument (MIDI) in one plugin. Differences from
   Bakushi: no 16-pad grid UI (MIDI-note mapping instead), no automatic pad filling
   (slices must be created by the user), DAW-plugin distribution vs desktop app.
   No open project has Bakushi's exact chain (separation → auto-slice → auto-fill 16
   pads). That chain is Bakushi's unique gap to build.

---

## Best-practices synthesis (one choice per sub-problem)

| Sub-problem | Best approach | Source |
|---|---|---|
| Model loading | Persistent worker/sidecar process; kill-and-respawn on failure; cache-heal on load failure | StemDeck |
| Chunking | Hann-window overlap-add with weight accumulation; normalize by weight sum; trim padding; validate output shape every chunk; cancel between chunks | INTERSECT |
| Hop size | Use the demucs reference hop: overlap 0.25 → stride 5.85 s (Bakushi's 2 s hop is ~3x more work) | StemDeck/demucs |
| Silent skip | Bakushi's `max abs < 0.002` skip is original — keep (nobody else does it) | Bakushi |
| Memory | Streamed block reads for peaks (sf.blocks); chunked playback cache (previous+current); ORT: DisableMemPattern + sequential on Windows | StemDeck + INTERSECT |
| Waveforms | Signed min/max per bucket at fixed point count (3000), shared cross-stem normalization, mipmap levels for zoom, precomputed JSON | StemDeck + INTERSECT |
| Pads/voices | Fixed voice pool with lowest-envelope stealing; choke groups = mute groups; loop crossfade; 1SHOT; per-pad overrides over defaults | INTERSECT |
| Backend | Persisted choice auto/cpu/gpu; probe-validate GPU output (Bakushi's original); loud, visible fallback with persisted `gpu_fallback` flag | StemDeck + Bakushi |
| Progress/UI | Staged progress (preparing/separating/writing), stall watchdog, click-through UI during inference | StemDeck + Bakushi |

---

## Gap analysis (what Bakushi must build that no project provides)

1. **Auto-fill of the 16 pads after separation** — no project does this; everyone stops
   at slices. Bakushi owns the chain: separation → transient detection (copy StemDeck's
   onset params) → top-N slices → assign to pads.
2. **DirectML all-zeros guard for htdemucs_6s ONNX** — no published solution exists;
   Bakushi's `_provider_sane` probe is the reference implementation now.
3. **Low-end CPU optimization** — none of the projects targets 8 GB / Iris Xe
   (StemDeck assumes a desktop; INTERSECT says "older PCs take minutes per minute";
   StemTube's fine mode is CUDA-only). Bakushi's silent-skip + long-hop + preview-window
   combo is the only CPU-first effort.
4. **A desktop app with an MPC grid** — INTERSECT is a DAW plugin; Bakushi is the only
   standalone desktop app combining separation with a pad grid.

## Specific values worth copying

- `apply_model(split=True, overlap=0.25, transition_power=1.0)` — demucs reference.
  For Bakushi's sidecar this means: **hop = segment × 0.75 = 257,985 samples (~5.85 s)**
  instead of 88,200 (~2 s): ~3x fewer chunks with the exact same overlap-add math
  (Bakushi already uses Hann + weight-sum normalization — identical to INTERSECT's).
- INTERSECT chunk contract: 131072 samples, 50% overlap, Hann, divide by weight.
- ORT Windows session options for long CPU inference: `intra_op = clamp(1,4,cpus)`,
  `DisableMemPattern`, `ORT_SEQUENTIAL`, `ORT_ENABLE_BASIC` (INTERSECT).
- Peaks: 3000 signed min/max buckets per stem, one streamed pass, shared normalization.
- Onset/transient constants (StemDeck beatgrid): hop 32, n_fft 512, n_mels 64,
  median aggregate, peak_pick(15/15 ms, 45/60 ms, delta 1.5×P90, wait 30 ms),
  parabolic interpolation.
- Choke-group semantics and voice stealing (INTERSECT).
- OpenVINO pairing table (Q5) and the `HF_HUB_DISABLE_SYMLINKS=1` Windows gotcha
  (StemDeck section_worker).
- Error UX: "GPU failed — retrying on CPU (slower)..." + persisted fallback flag.

## Ranked "copy this" vs "build this"

COPY (low effort, high value):
1. Demucs reference hop (overlap 0.25 → 5.85 s stride) for long songs — one constant.
2. INTERSECT-style ORT session options on Windows (sequential + no mem-pattern) for the
   CPU path — one session-options block.
3. StemDeck onset-envelope constants for the slice detector upgrade.
4. Peak mipmaps + shared cross-stem normalization in the waveform panel.
5. OpenVINO 1.24.1 ↔ 2025.4.1 pairing when roadmap #2 is attempted.

BUILD (unique to Bakushi, no source to copy):
1. Auto-fill pads: slice → assign chain (roadmap #3).
2. Probe-validated EP fallback for htdemucs_6s ONNX (already built — keep).
3. CPU-first long-song strategy (silent skip + preview window + ETA UX — already built).
4. 16-pad MPC grid in Flutter with the C engine (already built).

NOT WORTH COPYING:
- Rewriting inference in C++/Rust (INTERSECT does this in JUCE for DAW integration;
  Bakushi's Python sidecar gives the same isolation with far less code).
- torch-directml (UVR5 commented it out; dead end, matches Bakushi's measurements).
- TagYourSample's web engine (closed; web-specific anyway).
