# The HTDemucs ONNX model

The app's default model is `htdemucs_fp16weights.onnx` (4 stems: drums,
bass, other, vocals; ~166 MB, fp16 weights, MIT-licensed HTDemucs).

## Not committed, not downloaded

Model files are **never committed to git** (`*.onnx` is gitignored - the
files are far above GitHub's 100 MB limit) and the source tree does not
download them. You need the file on disk in one of the locations below.

## Not bundled by default - but the installer bundles it

The regular app build does **not** bundle the model. However, the
`BakushiSetup.exe` installer in this project **does bundle**
`htdemucs_fp16weights.onnx` and installs it into
`<app>\assets\models\`, so an installed copy works with zero extra
downloads. If the model is missing, the app shows a clear error and the
**"Choose model file"** path below still works.

## Where the app looks

The app resolves the model at (in order):

1. A path you chose with **"Choose model file"** (Step 2 or the
   Settings section; remembered in `bakushi_settings.json`).
2. `assets/models/htdemucs_fp16weights.onnx` relative to the working
   directory (this folder when you run `flutter run -d windows`).
3. `<exe folder>/assets/models/htdemucs_fp16weights.onnx`
4. `<exe folder>/htdemucs_fp16weights.onnx`

Any 4-stem HTDemucs ONNX export works; the file name does not matter
when picked manually.

## Getting the model manually

Download the verified export `htdemucs_fp16weights.onnx` from
`StemSplitio/htdemucs-onnx` on Hugging Face (MIT) and copy it here:

```
assets/models/htdemucs_fp16weights.onnx
```

The sidecar inspects the model's real input/output names, shapes and
dtypes at load time and adapts.

## Verifying

```powershell
python sidecar/bakushi_sidecar.py --selftest --model assets/models/htdemucs_fp16weights.onnx
```

Expected: `stems detected: 4 (drums, bass, other, vocals)`.

See `docs/MODEL_SETUP.md` for full details.

## Notes

- Other large model files in this folder (e.g. `htdemucs_4s.onnx`,
  `htdemucs_4s_int8.onnx`, `htdemucs_6s_fp16weights.onnx`) are local
  experiments. They are gitignored and NOT part of the installer.
- If the model file is missing, the UI shows a clear error and no audio
  is faked.

