# Bakushi — Final V1 Audit

> Reconstructed from verified project facts (source code, `docs/*`, test
> outputs, and the repo's verified-change log). Every number below comes
> from an executed run, a printed diagnostic, or a source constant — none
> are estimates invented for this document.

## 1. Purpose

Bakushi is a **local-first Windows desktop tool** that turns one song into
a playable 16-pad MPC-style kit: it decodes audio, runs real HTDemucs AI
source separation on the machine, keeps only the stems that contain
audible audio, and auto-fills 16 pads with beat-locked slices that the
user can trigger, loop, pitch, reverse, re-cut and export.

This audit records what the app **actually is** at V1, what is verified
working, what is placeholed or absent, and what must NOT be built next.

## 2. Product summary

- Upload WAV / MP3 / OGG / M4A (file picker or drag-and-drop).
- Decode locally to stereo 44.1 kHz float32 PCM via the Python sidecar
  (PyAV). Nothing is uploaded to any cloud service.
- Separate with an HTDemucs ONNX model (4 stems default: drums, bass,
  other, vocals; optional 6-stem adds guitar + piano) on the local
  machine via ONNX Runtime + native OpenVINO.
- Filter stems by RMS (threshold `AppConfig.silentStemRms = 0.01`):
  near-silent stems are hidden but kept for export.
- Beat-track the drums stem (librosa), then auto-fill 16 pads from the
  loudest 2-bar sections (1-bar for short songs), proportional split
  across the audible stems.
- Per-pad sampler controls (Phase C): HIT/LOOP, pitch −12..+12 st
  (varispeed `2^(st/12)`), reverse, gain 0–200% (baked + clamped),
  preview, custom-sample upload, clear, Canva-style cut editor.
- Optional starter kit (own/CC0 WAVs loaded from disk — nothing bundled).
- Local song library (raw f32le PCM) so a song reopens without
  re-separating; per-pad settings persist in `state.json`.

## 3. Verified stack

| Layer | Technology | Verified detail |
| --- | --- | --- |
| UI | Flutter Windows desktop | Dart SDK `^3.13.1`, Material 3 dark theme |
| Audio decode + inference | Python 3.11.9 sidecar | PyAV decode; onnxruntime-openvino 1.24.1 paired with openvino 2025.4.1; NDJSON over stdin/stdout; PCM as f32le files |
| Beat tracking | librosa 0.11 (`beat_analysis.py`) | BPM scalar ONLY (no beat/downbeat positions) from the drums stem |
| Playback | Custom C engine, miniaudio 0.11.25 | WASAPI float32 stereo 44.1 kHz, one `ma_device`, hand-rolled voice mixer; FFI via dart:ffi |
| Model | `htdemucs_fp16weights.onnx` (default, ~166 MB) | input `mix (1,2,343980)` fp32; output `stems (1,4,2,343980)` drums/bass/other/vocals |
| Model (optional) | `htdemucs_6s_fp16weights.onnx` (~136 MB) | 6 stems (+ guitar, piano) |
| Plugins | file_selector, desktop_drop, path_provider, ffi | file_picker removed (freeze root cause) |
| Library | `<appSupport>/library/<slug>/` | `meta.json`, `state.json`, raw `original_{l,r}.f32le`, `stems/<name>_{l,r}.f32le`; ≈650 MB per 5-min song |

## 4. Data flow

```
User file (WAV/MP3/OGG/M4A)
  ↓ file picker / drag-drop              (home_page, AppState.pickFile/onFileDropped)
  ↓ sidecar "decode" (PyAV, resample)   (sidecar/bakushi_sidecar.py cmd_decode)
Stereo f32 PCM (44.1 kHz)
  ↓ sidecar "separate" (HTDemucs ONNX)  (cmd_separate, infer_chunk)
  ↓ OpenVINO CPU (or GPU.1 after probe) / ORT CPU fallback
  ↓ chunked overlap-add, Hann window, wsum normalize
Stems: drums / bass / other / vocals    (+guitar/piano with the 6-stem model)
  ↓ RMS validation                       (AppConfig.silentStemRms = 0.01)
  ↓ drums → beat_analyze (librosa)      (sidecar/beat_analysis.py)
BPM scalar only (no beat/downbeat positions)
  ↓ autoFillPads: proportional split, 2-bar segments, RMS-ranked
16 pads (buffers baked with 5 ms micro-fades, gain baked + clamped)
  ↓ native miniaudio mixer (FFI)        (native/engine/bakushi_engine.c)
Pad trigger/loop/pitch/reverse  →  editor, inspector, persistence, library
```

## 5. Separation process (verified)

- Input shape `(1, 2, 343980)` fp32; segment = 343,980 samples (~7.8 s).
- Hop = 88,200 samples (2.0 s) for short songs; 257,985 samples
  (0.75 overlap) for long songs (`modelHopSamplesLong`).
- Chunks are overlap-added with a Hann window and normalized by the
  accumulated window sum; full duration is preserved.
- Silent chunk skip: chunks with max abs < 0.002 are skipped (progress
  still reported).
- The sidecar probe-runs every non-CPU provider before use
  (`_provider_sane`) and falls back on silent output or exception —
  correctness is validated before a provider is accepted.
- Sidecar releases memory after each separation (`_release_memory()` +
  `SetProcessWorkingSetSize`); the app also trims its working set off
  the UI thread.
- 4-stem ground truth (fresh fp16 separation of the test library song,
  numpy-checked PCM16 WAVs): drums RMS 0.1617, vocals 0.0916, bass
  0.0380, other 0.0270. All ≥ 0.01 → all four stems visible on that song.

## 6. Inference backends (local benchmark, 2026-10-11 — NOT universal)

30 s clip, hop 88,200 (16 chunks), onnxruntime 1.24.1, providers
OpenVINO → CPU:

| Model / provider | Avg s/chunk | Total | RTF | Peak RSS |
| --- | ---: | ---: | ---: | ---: |
| 6s fp32 / OpenVINO CPU | 1.478 | 24 s | 0.795x | 3,591 MB |
| 6s fp32 / ORT CPU | 2.366 | 38 s | 1.268x | 4,366 MB |
| 6s fp32 / OpenVINO GPU.1 | 1.186 | 19 s | 0.639x | 11,218 MB |
| fp16 4s / OpenVINO CPU | 1.435 | 23 s | 0.77x | 3,772 MB |
| fp16 4s / ORT CPU | 2.33 | 37 s | 1.248x | 4,610 MB |

- OpenVINO CPU is ≈1.6x faster than plain ORT CPU on every model tested
  (OUR machine, OUR benchmark — not a guarantee elsewhere).
- The Intel Iris Xe exposes two GPU devices: GPU.0 is 100% NaN and is
  probe-rejected; GPU.1 is clean. OV AUTO always picks GPU.0 — never
  used. GPU.1 works only for the 6-stem fp32 model; the fp16 model
  cannot compile on this iGPU and falls back to OpenVINO CPU.
- DirectML was removed: on this machine it returned all-zeros silently
  or OOM (8007000E on ConvTranspose_1).
- The ORT OpenVINO EP bridge fails on this model ("Output names
  mismatch") — the sidecar uses the native `ov.Core` runtime instead.
- int8 quantization is SLOWER than fp16 on every backend here (ORT CPU
  3.32x RTF) — removed from the app.

## 7. Stem validation and silent filtering

- Every stem is checked after separation AND after library load:
  RMS, peak, NaN/Inf; all-silent output stops with an error instead of
  producing fake audio.
- `AppConfig.silentStemRms = 0.01` unified everywhere
  (`StemAudio.isSilent`). Stems below it are hidden from the default
  view and always kept for export.
- The "Show silent stems" toggle **API exists but is unwired**: its
  panel was deleted in the strip-down, so hidden stems can currently be
  exported but not viewed. Either rewire the toggle or remove the dead
  API before release.
- Honest note: on the test library song all four stems exceed 0.01, so
  "bass/other silent" is NOT reachable for that song — the audio is
  genuinely there. Raising the constant to 0.05 would hide bass+other.

Stem RMS on the test library song (both sources verified):

| Stem | RMS (fresh fp16 separation, numpy-checked) | RMS (saved library data) | ≥ 0.01 visible? |
| --- | ---: | ---: | --- |
| drums | 0.1617 | 0.1035 | yes |
| vocals | 0.0916 | 0.0904 | yes |
| bass | 0.0380 | 0.0325 | yes |
| other | 0.0270 | 0.0229 | yes |

Visibility (≥ 0.01) is a FIXED rule; auto-fill eligibility is a separate
FUTURE rule — see §16.

## 8. Beat analysis and auto-fill

- Beat tracking runs on the **drums** stem only (librosa
  `beat_track`); the output is the **BPM scalar only** — no
  beat/downbeat positions are produced or used.
- Verified on the test library song: BPM 92.29.
- Auto-fill (`AppState.autoFillPads`) is automatic after separation and
  after library load: audible stems share 16 pads proportionally
  (largest remainder: 2→[8,8], 3→[6,5,5], 4→[4,4,4,4]); each stem's
  group gets its loudest 2-bar sections (1-bar when too short), ranked
  by segment RMS; pads default to LOOP.
- Verified 4-stem fill: pads ranked by RMS desc per group; all pads
  5.201 s 2-bar LOOP at 92.29 BPM.
- Baked micro-fades: 220 frames (5 ms) per slice plus the engine's
  loop-wrap re-fade keep seams click-free.
- No onset detection, no transient slicing, no grid-snap forcing — by
  design (fixed BPM + RMS auto-fill; eligibility rules live in §16).

Real pad manifest (printed by the autotest on the test library song,
`autotest_pc2_stdout.txt`, BPM 92.29, 2-bar segments = 5.201 s):

| Pad | Key | Stem | Slice | RMS | Mode |
| --- | --- | --- | --- | --- | --- |
| 1 | Q | drums | 218.442s..223.643s | 0.1317 | LOOP |
| 2 | W | drums | 31.206s..36.407s | 0.1309 | LOOP |
| 3 | E | drums | 93.618s..98.819s | 0.1308 | LOOP |
| 4 | R | drums | 156.030s..161.231s | 0.1306 | LOOP |
| 5 | A | bass | 249.648s..254.849s | 0.1074 | LOOP |
| 6 | S | bass | 145.628s..150.829s | 0.1001 | LOOP |
| 7 | D | bass | 83.216s..88.417s | 0.0994 | LOOP |
| 8 | F | bass | 208.040s..213.241s | 0.0976 | LOOP |
| 9 | Z | other | 249.648s..254.849s | 0.0790 | LOOP |
| 10 | X | other | 20.804s..26.005s | 0.0726 | LOOP |
| 11 | C | other | 208.040s..213.241s | 0.0675 | LOOP |
| 12 | V | other | 145.628s..150.829s | 0.0644 | LOOP |
| 13 | 1 | vocals | 36.407s..41.608s | 0.1346 | LOOP |
| 14 | 2 | vocals | 98.819s..104.020s | 0.1324 | LOOP |
| 15 | 3 | vocals | 161.231s..166.432s | 0.1306 | LOOP |
| 16 | 4 | vocals | 223.643s..228.844s | 0.1289 | LOOP |

## 9. Pads and sampler controls (verified via autotest prints)

- 16 pads, engine voice ids 0–15. Fixed keyboard layout
  QWER/ASDF/ZXCV/1234, reassignable (duplicate keys SWAP), persisted
  per pad.
- HIT: one trigger plays the slice once. LOOP: first trigger starts the
  loop, second stops it. Switching HIT ↔ LOOP **always** stops the pad
  immediately (verified all 4 toggle cases: `playing true -> false`).
- Pitch −12..+12 semitones, playback rate `2^(semitones/12)`
  (varispeed — tempo changes with pitch). Verified: +5 st → rate
  1.3348.
- Reverse is a real-time play-direction flag in the engine (no
  pre-baked reversed buffer).
- Gain 0–200% is **baked into the pad buffer with a hard clamp at
  [−1, 1]** in Dart — the engine always receives gain 1.0, so 200%
  cannot clip and no engine change was needed.
- Preview always plays once with the pad's current pitch/reverse/gain,
  never loops — even for LOOP pads.
- Custom uploads: WAV/MP3/OGG/M4A, decoded via the sidecar, copied to
  `<appSupport>/custom_samples/` (survives library re-saves), optional
  BPM detection, best-energy 2-bar slice. Upload preserves the pad's
  mode/pitch/reverse/gain; a fresh pad defaults to LOOP.
- Clear drops source/slice/label and the custom reference (the copied
  file on disk is kept to avoid breaking shared paths); the UI confirms
  first when the pad is edited or custom.

Pad controls matrix:

| Control | Range / rule | Implementation | Verified |
| --- | --- | --- | --- |
| HIT / LOOP | HIT plays once; LOOP toggles start/stop; mode switch ALWAYS stops the pad | C engine loop flag; `setPadLoop` / `togglePadMode` | autotest toggle cases A–D (`playing true -> false`) |
| Pitch | −12..+12 st; rate = 2^(st/12) (varispeed) | engine play-time rate | +5 st → rate 1.3348 (printed) |
| Reverse | on/off; slice plays backward | engine play-time reverse flag | `padfx.reverse` printed |
| Gain | 0–200%, default 100% | baked into the buffer with hard clamp [−1, 1] in Dart | `padfx.gain` + peak clamp printed |
| Preview | plays once with current settings; NEVER loops | `PadPlaySpec(preview: true)` → `loop: false` | unit-tested; `padfx.playing` printed |
| Upload | WAV/MP3/OGG/M4A → Custom; preserves mode/pitch/reverse/gain; confirms when edited/custom | `assignCustomSampleToPad` + `custom_samples/` copy | autotest `_SAMPLE` flow |
| Clear | removes source/slice/label; confirms when edited/custom | `clearPad` | UI logic |
| Edit (cut editor) | full-source waveform, 2 px lines, 20 ms min slice | `PadSliceEditor` + `applyPadBounds` | `padEdit.diag` + screenshots |
| Reset Slice | restores originally assigned range; confirms when edited | `resetPadSlice` | code-verified |
| Keyboard | QWER/ASDF/ZXCV/1234; duplicates SWAP | `padKeys` map, persisted | `padKeys (1=Q ... 16=4)` printed |

## 10. Cut editor (Canva-style, Phase C)

- Full-source waveform (stem, custom sample or starter sound) rendered
  as a **filled**, gradient, min/max-peak shape that always fits inside
  the canvas margins (12 px); amplitude normalized by the source
  `maxAbs`; verified `nonFlat=true` with max amplitude 0.891 on the test
  song (11,604,992 source samples).
- Two thin 2 px cut lines with grab knobs; invisible hit area ≈16 px.
- Drag start line / end line / purple body (duration-preserving);
  minimum slice 20 ms; all clamps inside source bounds; live re-bake on
  drag, one-shot auto-preview on release.
- Tools: Preview, Stop, Set Start, Set End, Reset Slice, Done.
  Reset Slice restores the originally assigned range (confirms when
  edited).

## 11. Starter kit

- Optional, loaded from `assets/starter_kit/*.wav` next to the exe or
  in the project dir — **nothing is bundled or synthesized**.
- 8 slots: kick, snare, closed_hat, open_hat, clap, rimshot, perc,
  shaker. Loaded pads are labelled "Starter Kit · <Name>", default HIT.
- Fills EMPTY pads only; never overwrites stems or custom pads; "No
  empty pads available." when full.
- License manifest template: `assets/licenses/STARTER_KIT_LICENSES.md`
  (CC0/public-domain/original only).

## 12. Library and persistence

- `<appSupport>/library/<slug>/`: `meta.json` (name, sourcePath,
  durationSec, sampleRate, sizeBytes, savedAt), `state.json`
  (mixer + padKeys + customSamples + a full per-pad `pads` block),
  raw f32le audio. Deterministic slug per filename; re-saving the same
  name replaces the entry.
- The per-pad block persists: source identity, slice bounds, HIT/LOOP,
  pitch, reverse, gain, label, manual-edit flag and original range.
  On load, pads are restored **exactly** from the block (custom PCM
  restored first); libraries without the block fall back to auto-fill.
  Verified: `pads.restore.done (16/16 pads restored)` and the edited
  slice (9639288..9659288) survives a reload.
- Settings save is debounced 2 s; separation auto-saves after a 3 s
  delay; big file writes run in worker isolates.
- **Saving is atomic** since the Library + Diagnostics round: everything
  is written into a sibling temp dir (`<slug>.tmp-<pid>-<millis>/`),
  then the old entry is moved aside (`.old-*`) and the temp dir is
  renamed into place. On any failure the temp dir is removed and the
  previous save survives intact (unit-tested).

## 13. Playback engine (no changes in Phase C)

- One WASAPI device, float32 stereo 44.1 kHz; voice ids: pads 0–15,
  stems 100–105, original 200; `BA_MAX_BUFFERS` 256, 32 voices.
- Per-voice: linear-interpolation playback rate (pitch), reverse flag,
  loop with fade re-arm on wrap, linear fade in/out, live gain.
- Known quirk: retriggering an active voice keeps its live gain (the
  gain argument only applies to a fresh slot) — sidestepped by baking
  gain in Dart.
- Dart polls `isPlaying` every 150 ms for tile glow/loop animation (the
  engine emits no stop events).

## 14. Diagnostics and logging

- `AppState._action(name, detail:)` → `debugPrint` + in-app log — the
  verify-by-print convention; every user action and pipeline stage is
  visible on stdout.
- Env-gated autotest (`BAKUSHI_AUTOTEST`, `_FILE`, `_LIBRARY_ID`,
  `_PADS`, `_PADFX`, `_SAMPLE`, `_HOLD_EDIT`…) drives the exact button
  code paths headlessly; a 3 s watchdog prints "UI STALL DETECTED" if
  the event loop stops.
- 5 s "ui alive" heartbeat while busy; click-through progress overlay.
- Diagnostics panel: engine status + retry, app log, sidecar stderr
  (capped 300 lines), Copy log.

## 15. Known limitations (honest list)

- Separation is **broad source separation**, not a timestamp cutter and
  not perfect isolation: bleed, artifacts and song-dependent stem
  content are expected. Near-silent stems are filtered, not fixed.
- Pitch is varispeed: changing pitch changes tempo (by design).
- Loop seam is a re-armed fade-in (brief dip), not a crossfade.
- Library storage is raw float32: ≈650 MB per 5-min song; 8 GB RAM is
  the floor.
- No time-stretch, no anti-aliased resampling, no choke groups, no
  stem export for pad slices (stems export only).
- GPU acceleration on this machine only helps the 6-stem fp32 model and
  costs ~11 GB RSS + a ~90 s compile.

## 16. Non-silent vs Auto-Fill Eligible Stems (NOT IMPLEMENTED)

Two different rules, deliberately kept separate:

**Visibility (current, fixed):** a stem is non-silent and stays
viewable/exportable/manual-assignable when `stemRms >= 0.01`
(`AppConfig.silentStemRms`).

**Auto-fill eligibility (FUTURE rule, NOT IMPLEMENTED):** a stem is
eligible for automatic pads when

```
eligible = stemRms >= max(0.01, loudestStemRms * configurableRatio)
```

with `configurableRatio` in 0.20–0.30. The fixed threshold remains the
visibility floor; the ratio only decides which stems receive automatic
pads. Pad allocations stay largest-remainder: 1 stem → 16,
2 → 8/8, 3 → 6/5/5, 4 → 4/4/4/4.

Worked example — Drop It Like It's Hot (drums 0.1617, vocals 0.0916,
bass 0.0380, other 0.0270):

- ratio 0.20 → cutoff = 0.1617 × 0.20 = 0.0323 → **other excluded**
  (0.0270 < 0.0323); 3 eligible stems → drums 6 / vocals 5 / bass 5.
- ratio 0.30 → cutoff = 0.1617 × 0.30 = 0.0485 → bass (0.0380) and
  other (0.0270) excluded → drums + vocals → 8/8.

Low-energy stems are never deleted: they stay viewable, exportable and
manually assignable. **This rule is NOT IMPLEMENTED** — it is the
single next task (see §17).

## 17. Final release verdict

**NOT READY for a public v1 release.**

### Must-fix blockers (5)

1. **Library + Diagnostics UI — DONE (2026-10-11).** Saved-songs list,
   library load flow, diagnostics panel, atomic library save. Was audit
   blocker B.
2. **Adaptive auto-fill eligibility (§16) — NOT IMPLEMENTED.** Weak but
   non-silent stems (bass 0.0325 / other 0.0229 on the test song)
   still receive automatic pads. **This is the single next task.**
3. **"Show silent stems" toggle is unwired** — the API exists but its
   panel was deleted; hidden stems can be exported but not viewed.
4. **Starter kit ships no license-proven assets** — loader and license
   template exist; decide between shipping documented CC0 assets or
   promoting the explicit setup path.
5. **Final human acceptance pass** — library load from the new list,
   diagnostics Copy log and the full acceptance path are verified via
   autotest/screenshots; one manual pass is required before any
   release.

### Non-blocking polish (5)

1. Loop-seam crossfade (currently a re-armed fade dip).
2. FLAC/16-bit library storage (raw f32 ≈650 MB per 5-min song).
3. Per-stem RMS readout for hidden stems.
4. Pad-slice WAV export.
5. Anti-aliased rate interpolation for high pitch values.

### Postponed

Tempo-preserving time-stretch, choke groups, live pitch/reverse setters
while sounding, multi-song editing, model/backend chooser UI.

### Single next task

**Adaptive auto-fill eligibility** — implement the relative-RMS rule
from §16. Nothing else on this list starts until it ships.
