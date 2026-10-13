# Contributing to Bakushi

Bakushi is a Flutter Windows app: local AI stem separation into 16 pads
plus a step sequencer. Contributions are welcome. Keep it simple - this
guide is short on purpose.

## Where things live

| Concern | Location |
| --- | --- |
| Pure models (pad, pattern) | `lib\models\` |
| Pure DSP (segments, planner, playback math, renderer) | `lib\audio\` |
| App state, persistence, engine facade | `lib\state\` |
| UI panels | `lib\ui\panels\` |
| Native miniaudio engine (C) | `native\engine\` |
| Python sidecar (decode, separation, beats) | `sidecar\` |
| Installer + packaging | `tools\` |
| End-user docs | `README.md` |
| Design / audit docs | `docs\` |

## Rules that are easy to get wrong

- **New DSP must be pure and unit-tested.** `AppState` is NOT
  constructible in unit tests (`NativeEngine.instance` throws when the
  DLL is missing). Put new math in pure helpers (like `lib\audio\pad_cut.dart`)
  and test those; exercise FFI paths via the autotest environment instead.
- **Isolate closures:** create `Isolate.run` closures in TOP-LEVEL
  helpers, never inside async `State` methods. A closure made inside an
  async method captures the frame's shared context (holds `this` and its
  timers) and dies with "object is unsendable: _Timer". An inline arrow
  in the async method does NOT help.
- **Sidecar commands with librosa/scipy** must run INLINE on the sidecar
  server main thread (a worker thread deadlocks while the main thread is
  blocked on stdin).
- **Engine voice ids:** pads 0..15, stems 100..105, original 200, preview
  210, sequencer 211. New ids must stay below `BA_MAX_BUFFERS` (256).
- **state.json round-trips** through `_librarySettings`; never break
  legacy compatibility (old entries without new fields must still load).
- **stdout-visible proof:** use `_action(name, detail:)` - `log()` only
  writes the in-memory list.

## Verifying your change

```powershell
flutter analyze                       # must be clean
flutter test                          # must stay green (114+ tests)
flutter build windows --release       # no build regressions
```

End-to-end (release exe, env-driven, no human needed):

```powershell
$env:BAKUSHI_AUTOTEST='full'
$env:BAKUSHI_AUTOTEST_FILE='test_song.wav'            # or any song
$env:BAKUSHI_AUTOTEST_LIBRARY_ID='drop-it-like-it-s-hot-mp3'  # fast path
$env:BAKUSHI_AUTO_ADVANCE='1'
$env:BAKUSHI_AUTOTEST_PADS='1'
$env:BAKUSHI_AUTOTEST_SEQ='1'
```

Expected: `autoTest.done` with no `UI STALL`. Screenshots via
`tools\_winshot.ps1`; hold hooks `BAKUSHI_AUTOTEST_HOLD_*` exist.

## Packaging

Installer: `iscc tools\installer.iss` (Inno Setup 6) produces
`dist\BakushiSetup.exe`. PowerShell scripts must be PURE ASCII -
PowerShell 5.1 parses BOM-less UTF-8 as ANSI and breaks on em-dashes
and smart quotes.
