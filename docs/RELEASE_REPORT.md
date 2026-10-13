# Bakushi — Release Report (v1.0.0)

Date: 2026-10-13 · Status: PUBLISHED — public GitHub repo + v1.0.0 release
with installer and zip assets, verified against the vision (V1-V13).

## What the app is

Bakushi turns any song into something you can play. Drop in a song, and a
local AI splits it into drums, bass, other and vocals — right on your
computer, nothing is uploaded. The 16 pads fill automatically with the
best musical moments (drums become one-shots, bass and vocals become
downbeat-anchored loops). Tap pads to play, program a beat on the step
grid, record and export WAV. Everything runs offline after install.

## What was verified, and when

All on 2026-10-12/13, on the development machine (Windows 10/11, Intel Iris Xe,
Python 3.11.9, OpenVINO CPU backend):

- **Unit tests:** 114/114 green, `flutter analyze` clean.
- **Autotest (release exe, dev tree):** full + library
  (`drop-it-like-it-s-hot-mp3`) + pads + sequencer gates →
  `autoTest.done`, no `UI STALL`. Musical auto-fill proof: 92.29 BPM,
  101 downbeats, 16 pads (4 drum HITs + 12 LOOPs with 0-sample downbeat
  offset). Sequencer proof: `seq.render bars=2 bpm=92.3 loop=5.201s
  voice=211`, `voice 211 playing=true`.
- **Installer round-trip (silent):** `dist\BakushiSetup.exe` (176 MB with
  VC++ redist; 153 MB without) — `/VERYSILENT /SUPPRESSMSGBOXES
  /NORESTART` exits 0; bundles the app + full Flutter runtime + sidecar +
  starter kit + licenses + the ONNX model + the python.org installer +
  `vc_redist.x64.exe`. Postinstall (PowerShell, ASCII-only): finds/installs
  Python 3.11, `pip install -r sidecar\requirements.txt`, sidecar
  `--selftest --model` → `stems detected: 4 ... SELFTEST-DONE`, pre-writes
  `model_path` into `bakushi_settings.json` (merge, no other keys lost)
  so the first launch skips the model picker. vc_redist runs BEFORE the
  postinstall step; its exit code is logged as non-fatal (1638 = runtime
  already present on this machine).
- **Installed app autotest:** library path + pads + sequencer →
  `autoTest.done`, no `UI STALL`.
- **Uninstall:** `unins000.exe /VERYSILENT` exits 0; install dir and
  registry key removed; user settings in `%APPDATA%` remain (expected).

## Clean-machine test status

**Not yet run — PENDING.** Windows Sandbox is not available on this
machine (checking/enabling the `Containers-DisposableClientVM` feature
needs elevation and possibly a reboot), so no claim of a clean-PC test
is made. Run this checklist on a fresh Windows 10/11 machine (VM or real
PC, no Python installed, no internet caching needed beyond pip):

1. Copy `BakushiSetup.exe` to the machine and run it (click through the
   wizard). Expect: installs to `%LOCALAPPDATA%\Programs\Bakushi`, no
   admin prompt, a pip install progress phase (needs internet), then
   success.
2. Launch Bakushi from the Start Menu. Expect: no model picker (the
   settings file was pre-written), the warm red-dark UI with the
   onboarding overlay on first run.
3. Drop a song, click **Separate Stems**. Expect: progress, then 16
   pads. Long songs take minutes on CPU (see limitations).
4. Tap pads, program the Beat Grid, press Play. Expect sound and the
   loop indicator.
5. Start Menu → "Uninstall Bakushi". Expect a clean removal.
6. Where failures would show: a red error dialog right after setup
   (Python/pip/selftest failure — rerun
   `powershell -ExecutionPolicy Bypass -File "<app>\tools\setup_postinstall.ps1" -AppDir "<app>"`
   and read `%TEMP%\bakushi_postinstall_*.log`), or the app's
   **Settings** section for engine/model errors.

## Build-from-source summary

Flutter SDK + VS 2022 (Desktop C++ workload) + Python 3.11 + the model
file → `pip install -r sidecar\requirements.txt` → `flutter pub get` →
`flutter build windows --release` → copy the sidecar next to the exe.
Full steps in `README.md` ("Building from source"), rules for
contributors in `CONTRIBUTING.md`, architecture in `docs\ARCHITECTURE.md`.

## Known limitations

- **Unsigned exe:** SmartScreen shows "Windows protected your PC" on
  first run — "More info → Run anyway". Code-signing is planned, not
  done.
- **Internet needed during install:** the postinstall step downloads the
  Python sidecar wheels (numpy, PyAV, librosa, openvino) via pip. The
  model and Python installer are bundled — no other downloads.
- **MPC-lite scope:** no real-time recording into the grid, no swing, no
  note repeat, no 16 levels, no velocity, no time-stretch. The grid is a
  step editor; the engine is a sampler + renderer.
- **CPU separation takes time:** ~0.8x real-time on CPU; a 4-minute song
  takes roughly 3-5 minutes. GPU (OpenVINO) helps where supported.
- **Stems are AI estimates** and may contain bleed or artifacts.

## GitHub — published (2026-10-13)

- **Repo:** https://github.com/abdugafforovboburbekbiz-del/bakushi —
  public, default branch `main`.
- **Release:**
  https://github.com/abdugafforovboburbekbiz-del/bakushi/releases/tag/v1.0.0 —
  tag `v1.0.0`, title "Bakushi 1.0.0", notes from `dist\RELEASE_NOTES.md`.
- **Assets (both `uploaded`, download URLs return HTTP 200):**
  - `BakushiSetup.exe` — 184,840,205 bytes (~176 MB),
    sha256 `03b225acdda8246551655dfe0854c4dda3c15a6b7213939c0d9b07d3b21c4826`
  - `bakushi-release.zip` — 14,335,121 bytes (~13.7 MB),
    sha256 `e8c03ba272df603fab3fb52cc81cca6f52ea708ad204aceeaf69957d0da16719`
- **v1.0.1 (2026-10-13, supersedes v1.0.0's assets):**
  https://github.com/abdugafforovboburbekbiz-del/bakushi/releases/tag/v1.0.1 —
  same-day follow-up: saved-song Delete button (with confirm dialog),
  honest README positioning (does/does-not, limitations, licensing),
  version bump 1.0.0+1 → 1.0.1+2. Assets (both `uploaded`, HTTP 200):
  `BakushiSetup.exe` 184,865,511 bytes, `bakushi-release.zip`
  14,340,725 bytes. Verified by full round-trip: release build →
  dev-exe autotest `autoTest.done` no STALL → silent install exit 0 +
  postinstall `SELFTEST-DONE` → installed-app autotest `autoTest.done` →
  uninstall exit 0.
- **Consistency:** remote `main` HEAD =
  local `284b530c844747ecef5d62f38cbe8ccd50003c0c` (8 commits); top-level
  tree has exactly the 16 intended entries (README.md, CONTRIBUTING.md,
  LICENSE, lib/, docs/, tools/, test/, …) — no `dist\`, no `test_songs\`,
  no `*.onnx`.
- **Vision verification (V1-V13):** upload (V1) wizard + library
  autotest; AI separation (V2) 4 stems + sidecar selftest; one-tap
  auto-fill (V3); pad edits + undo (V4); library store (V5); chop
  editor (V6); starter kit (V7); braindead onboarding UX (V8); dark +
  red theme (V9); musical downbeat-anchored auto-fill (V10); MPC step
  sequencer, voice 211 loop (V11); silent installer round-trip (V12);
  buildable from source (V13). Known gaps: unsigned exe (SmartScreen),
  internet for pip on first install, clean-machine test not yet run.
- **Security:** publishing used a classic PAT with `repo` scope (plus
  broader admin scopes it did not need). **Revoke it after this
  session:** GitHub → Settings → Developer settings → Personal access
  tokens, and run `gh auth logout` locally.

Pre-push sanitization (2026-10-13): every machine-specific user-directory
path removed from tracked files (docs, `lib\state\app_state.dart`
fallbacks now derive from `BAKUSHI_MODEL` / `BAKUSHI_AUTOTEST_FILE` with
generic relative fallbacks, tool scripts use env vars + repo-relative
defaults); the three machine-specific `tools\benchmark*.json` files deleted
and gitignored; 3.4 GB of generated work artifacts under `tools\_*` work
dirs untracked, deleted and gitignored - and the whole git history was
rewritten (filter-branch) so no machine path or work artifact survives in
any commit. Size scan: no tracked file over 100 MB, no `*.onnx`, no
`dist\` content, no `test_songs\`.
