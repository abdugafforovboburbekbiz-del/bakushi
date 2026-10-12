# Bakushi — Product Vision & Gap Analysis

Date: 2026-10-11 · Status: the implementation roadmap below

## 1. The vision (product contract)

A dopamine-friendly "creation out of depression" app:

1. User inputs a song.
2. The app separates it into stems.
3. The user gets **16 pads** they can immediately play.
4. Human edits happen on the pads (pitch slider etc.) — not in menus.
5. More songs can be added; a song can also be **chopped without separation**.
6. **Pre-made beats** (Incredibox / Koala style) work on day one, with zero separation.
7. The whole thing is **braindead simple**.
8. The UI must capture the feeling with **color theory: dark tones + RED**.
9. **Pad timestamps must be musical** — not identical 5.20 s grid copies.

## 2. Verified current state (code-cited)

- Stack: Flutter Windows + miniaudio C engine via FFI (`native/engine/bakushi_engine.c`) +
  Python sidecar (`sidecar/bakushi_sidecar.py`, NDJSON stdin/stdout, PCM as f32le files).
  Model: `htdemucs_fp16weights.onnx` (4 stems: drums, bass, other, vocals), OpenVINO CPU backend.
- 3-step wizard (`lib/ui/home_page.dart`): Upload (auto-decode, library list) → Separate
  (or "Chop Original Song") → 16 Pads.
- 16-pad auto-fill after separation and library load (`AppState.autoFillPads`,
  `lib/state/app_state.dart`).
- Per-pad: pitch ±24 st (varispeed), gain 0–200 % (baked), fade 0–50 ms, reverse,
  HIT/LOOP, waveform slice editor (`pad_editor.dart`, `slice_canvas.dart`), custom upload,
  keycaps QWER/ASDF/ZXCV/1234.
- Library with atomic saves (`lib/state/library_store.dart`), performance record → WAV
  (`lib/audio/render/performance_renderer.dart`).
- Starter-kit hook (`lib/state/starter_kit.dart`) with **no assets shipped**.

### Gaps

1. **Timestamps are a uniform beat grid anchored at sample 0**
   (`lib/audio/pad_cut.dart` `computePadSegments`): every pad is the same length
   (`i * segSamples`). The sidecar `beat_analyze` is BPM-only — beats/downbeats were
   stripped in an earlier round. Pads are not musical.
2. **No pre-made beats**: starter kit resolves files that do not exist.
3. **Wrong mood**: `lib/theme/app_theme.dart` is cool near-black `#0E0F13` + violet
   `#7C5CFF`, with hardcoded hexes across all panels. The vision says warm dark + red.
4. **~120 visible controls**: jargon chips ("Backend: OpenVINO", "Model: …"), an
   always-visible diagnostics panel, 6 interactive zones on every pad tile, no
   onboarding, no undo, and a dead "waiting for auto-fill" state.

## 3. Competitor research (what we borrow)

- **StemDeck** — local desktop practice app, Apache-2.0. Lesson: everything local,
  explain-by-pointing ("Guide mode").
- **Incredibox** — fail-proof loop kits: *any* combination sounds good; combo reward
  animations; record/share; Shuffle button. Lessons: curated compatible sounds,
  combo sparkle, shuffle.
- **Koala** — 16 performance FX, sequencer, keyboard scales, resampling.
  Lesson: pads are the instrument — everything else is secondary.

→ Bakushi's differentiator stays: **local offline AI separation + automatic musical
16-pad workflow**, now with the warm dark/red emotional palette and fail-proof kits.

## 4. Roadmap

- **Phase A — Musical timestamps (core fix).** Restore beats + downbeats in the
  sidecar (samples). LOOP pads = real downbeat starts (2-bar preferred, 1-bar
  fallback), ranked by RMS; HIT pads = sidecar onset one-shots (RMS ≥ 0.01, 50 ms
  local-RMS gate, wait 30 ms). Drums → hits; bass/other/vocals → downbeat loops.
  Cache beats, persist with the library entry, show progress during analysis.
  Uniform grid remains only as a no-downbeats fallback. Pure helpers + unit tests.
- **Phase B — Dark + red theme.** Named tokens: warm near-black base (`#171113`
  family), crimson primary (`#FF4D57`), amber secondary (`#FFB224`), warm white text
  (`#F5EFE9`). Convert all hardcoded hexes. Typography scale bump. Real pad glow
  while playing, press ripple/scale. Demote backend/model chips + diagnostics into
  one collapsed "⚙ Settings" section at the bottom.
- **Phase C — Pre-made beats.** Real starter kit in `assets/starter_kit/`
  (8 one-shots + 3 tempo-matched loops), CC0/original, licensed in
  `assets/licenses/STARTER_KIT_LICENSES.md`. First-launch auto-load into empty pads
  (persisted flag) — sound within ~10 s without separation. Optional Shuffle.
- **Phase D — Braindead-simple UX.** 3-screen onboarding (skippable, once).
  Whole tile = one trigger; editing only via the selected-pad inspector. One-level
  undo per pad. Friendly empty states ("Finding the best moments…"), "Tempo" instead
  of "BPM", remove the unwired show-silent-stems API.
- **Phase E — Optional dopamine FX** (only after A–D green). Master-bus low-pass +
  feedback echo in the C engine (`ba_set_fx`, wet=0 = exact passthrough) with two
  knobs; combo sparkle when ≥ 3 loops sound at once (pure Flutter).

## 5. Definition of done

- `flutter analyze` clean; full `flutter test` green; release exe rebuilt + sidecar
  redeployed after every phase.
- Autotest on the droplit library prints varied, downbeat-aligned pad timestamps
  (Phase A) and completes with `autoTest.done`, no STALL.
- Screenshots: red-dark theme, pad glow, starter-kit pads on first launch, onboarding,
  simplified tiles.
- This doc + `assets/licenses/STARTER_KIT_LICENSES.md` complete.
- Repository memory note `/memories/repo/bakushi.md` updated after each phase.

## 6. Out of scope

Sequencer, MIDI, Ableton export, stem-mixer UI revival, 6-stem default, cloud
sharing, mobile, real-time FX plugin architecture, any model change.
