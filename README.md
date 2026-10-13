# Bakushi

Bakushi is a free, open-source Windows sampler for chopping songs into playable pads.

Load a song, play with the original audio, optionally separate it into local AI stems,
then crop, pitch, reverse, loop, and trigger sections on a 16-pad sampler.

It is a simple creative tool—not a DAW, not a professional stem extractor, and not an
AI that decides which part of a song sounds best.

## What Bakushi does

- Load a song locally.
- Play and chop the original mix.
- Optionally separate the song into stems using local AI.
- Assign sections of the original song or stems to pads.
- Program a beat on the 16-lane step grid.
- Play pads with your mouse or keyboard.
- Change pitch, reverse, gain, HIT/LOOP mode, and add short fades.
- Export processed pad audio and recorded performances as WAV.
- Save and reopen local projects.

## What Bakushi does not do

- It does not run in the cloud.
- It does not upload your audio.
- It does not require an account.
- It does not automatically find “the best” sample moments.
- It does not replace a DAW, MPC, Serato Sample, Koala, or professional audio tools.
- Separated stems are AI estimates and may contain bleed, artifacts, or missing detail.

## Honest limitations

- Stem separation is batch processing, not real time.
- Separation speed depends heavily on your CPU, RAM, and selected model.
- AI stems can sound watery, phasey, dull, or artifact-heavy.
- The original song remains the cleanest source; stems are an optional creative starting point.
- Bakushi is designed for experimentation, not studio-quality stem extraction.

## Licensing

Bakushi’s application code is licensed under the MIT License (`LICENSE`).

The bundled HTDemucs stem-separation model is MIT-licensed
(facebookresearch/demucs, ONNX export by StemSplitio). Other third-party
models, model weights, and dependencies may have separate licenses -
check `assets\licenses\THIRD_PARTY.md` before redistributing this
project or its bundled components.

Users are responsible for ensuring they have the right to use, sample,
and distribute any audio they import into Bakushi.

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

Honest note: separation speed depends heavily on your CPU and its
instruction set. Measured on a modern laptop CPU via OpenVINO: roughly
0.8x real-time, i.e. a 4-minute song separates in about 3-5 minutes. On
an older 4-core CPU without AVX2, expect roughly 2-3x longer. Long
songs take longer; the progress bar always shows the real state.

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

There are two ways to hand Bakushi to someone else:

- **Installer (recommended):** `BakushiSetup.exe` installs everything in
  one click - Python, the sidecar dependencies, and the model. The person
  running it does not install or download anything separately.
- **Portable ZIP:** `bakushi-release.zip` unpacks to a folder with
  `bakushi.exe`, the runtime, the sidecar and the starter kit (no model,
  no Python). The person using it must install Python 3.11 once and
  download the model once - the app remembers the model path after the
  first pick, so that is a single-time step.

In both cases the app is not one self-contained EXE: it needs its
`sidecar\` folder and `assets\starter_kit\` next to it. Share the whole
installed folder or ZIP, not just `bakushi.exe`.

## Troubleshooting

- **"Python not found"** - install Python 3.11 with "Add to PATH" checked,
  then restart the terminal and run the `pip install` step again.
- **"Separation failed"** - the model file is wrong or corrupt. Re-pick it
  via **Choose model file** in Step 2. If a GPU backend fails, the app
  falls back to CPU automatically.
- **No sound** - open **Settings** at the bottom of the window and click
  **Retry audio engine**.
- **Disk space** - saved songs are kept in
  `%APPDATA%\com.bakushi\bakushi\library` as raw 32-bit float audio
  (roughly 650 MB per 5-minute song: original + four stems + a drum-stem
  backup). There is no in-app cleanup button yet; removing unneeded song
  folders there reclaims the space.

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

