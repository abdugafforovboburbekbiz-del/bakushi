# Bakushi

Version 1.0.0

## What this is

Bakushi turns any song into something you can play. Drop in a song, and a
local AI splits it into drums, bass, other and vocals - right on your
computer, nothing is uploaded. The 16 pads fill automatically with the best
musical moments (drums become one-shots, bass and vocals become loops that
start on the downbeat). Tap the pads to play, program a beat on the step
grid, then export your performance as a WAV. Everything runs offline.

## System requirements

Minimum:

- Windows 10/11 64-bit
- 4-core CPU
- 8 GB RAM
- ~5 GB free disk (Python + the 166 MB model + library storage of roughly
  650 MB per 5-minute song)
- No GPU required

Recommended:

- 16 GB RAM, 6+ cores, SSD
- Any CPU with AVX2

Honest note: separation is real-time-ish on CPU (~0.8x real-time). A
4-minute song takes roughly 3-5 minutes to separate. A long song takes
longer; the progress bar shows the real state.

## Model (required)

Bakushi uses `htdemucs_fp16weights.onnx` - the 4-stem HTDemucs model
(166 MB, fp16 weights, MIT-licensed HTDemucs). Any 4-stem HTDemucs ONNX
export works.

Download it in your browser:

`https://huggingface.co/StemSplitio/htdemucs-onnx`

On first run the app asks you to pick the model file - select the file you
downloaded (any file name works). The app remembers the path afterwards.

## Step-by-step setup

1. **Install Python 3.11** from [python.org](https://www.python.org/) and
   check **"Add to PATH"** during installation.
2. **Install the sidecar dependencies**: open PowerShell in the app folder
   and run:

   ```powershell
   pip install -r sidecar\requirements.txt
   ```

3. **Run the app**: start `bakushi.exe` from the `Release` folder.
4. **Pick the model** on first launch - select the downloaded ONNX file.
5. **Make beats**: drop a song onto the window (or choose one) → click
   **Separate Stems** → wait for the pads to fill → tap pads and program
   the beat grid.

If it says the model is missing: open **Settings** (bottom of the window)
or **Choose model file** in Step 2 and select your downloaded ONNX file.

## Installer

The one-click installer is `BakushiSetup.exe`. It installs everything -
Python, the sidecar dependencies, and the AI model - automatically.
There is nothing to configure: after setup finishes, launch Bakushi from
the Start Menu or desktop shortcut and drop in a song.

- Installs to `%LOCALAPPDATA%\Programs\Bakushi` (no admin rights needed)
- Bundles Python 3.11 and installs it silently when missing
- Bundles the `htdemucs_fp16weights.onnx` model (no download needed)
- Runs the sidecar self-test before finishing; a failed setup says so
  clearly instead of producing a broken app

**SmartScreen note:** the exe is not code-signed yet, so on first run
Windows may show "Windows protected your PC". Click **More info** →
**Run anyway**. Code-signing is planned but not done.

## Sharing the app

The EXE is **not** fully standalone. Share the whole `Release` folder:

- `bakushi.exe`
- `sidecar\` (the Python scripts)
- `assets\starter_kit\` (the built-in drum sounds)

The person receiving it must install Python once and download the model
once. After the first run the app remembers the model path, so they only
do that a single time.

## Troubleshooting

- **"Python not found"** - install Python 3.11 with "Add to PATH" checked,
  then restart the terminal and run the `pip install` step again.
- **"Separation failed"** - the model file is wrong or corrupt. Re-pick it
  via **Choose model file** in Step 2. If a GPU backend fails, the app
  falls back to CPU automatically.
- **No sound** - open **Settings** at the bottom of the window and click
  **Retry audio engine**.

## Building from source

Prerequisites:

- Flutter SDK (stable channel)
- Visual Studio 2022 with the **Desktop development with C++** workload
- Python 3.11 (for the sidecar; used at runtime too)
- The model file `htdemucs_fp16weights.onnx` - download it from
  `https://huggingface.co/StemSplitio/htdemucs-onnx` and put it in
  `assets\models\` (the installer bundles it; the source tree does not)

Build steps:

```powershell
# 1. Python sidecar dependencies (pinned versions matter - one runtime
#    only: onnxruntime-openvino==1.24.1 + openvino==2025.4.1)
pip install -r sidecar\requirements.txt

# 2. Dart dependencies and the release build
flutter pub get
flutter build windows --release
```

Deploy next to the built exe (`build\windows\x64\runner\Release`):

```powershell
mkdir sidecar   # create the folder first - Copy-Item to a missing dir makes a FILE
copy sidecar\bakushi_sidecar.py sidecar\beat_analysis.py sidecar\drum_punch.py sidecar\requirements.txt .\build\windows\x64\runner\Release\sidecar\
robocopy assets\starter_kit build\windows\x64\runner\Release\assets\starter_kit /E
```

Verification:

```powershell
flutter analyze
flutter test
# End-to-end self-test (release exe):
#   BAKUSHI_AUTOTEST=full, BAKUSHI_AUTOTEST_FILE=<song>, BAKUSHI_AUTOTEST_LIBRARY_ID=<slug>,
#   BAKUSHI_AUTO_ADVANCE=1, BAKUSHI_AUTOTEST_PADS=1, BAKUSHI_AUTOTEST_SEQ=1
```

Architecture overview: `docs\ARCHITECTURE.md`. Want to contribute? See
`CONTRIBUTING.md`.

