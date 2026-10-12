# Bakushi Starter Kit — Asset Licenses

The starter kit is an **optional** built-in beat kit. It is never required
for the app to work. Sounds are resolved from `assets/starter_kit/` next to
the executable (or in the project directory) — nothing is bundled by
default.

## Rules

Every sound in this kit MUST be one of:

1. **CC0 / public domain** (e.g. CC0 1.0, works in the public domain), or
2. **Original**, created specifically for Bakushi.

No copyrighted commercial drum-kit samples may be used. No AI-generated
copies of commercial kits either.

## Asset manifest

All sounds below are **original synthesized works created for Bakushi** by
`tools/make_starter_kit.py` (numpy synthesis, no sampled recordings, no
external sources). License: **CC0 1.0** — the Bakushi project dedicates
these synthesized sounds to the public domain, so they can be shared and
reused without any attribution or restriction.

| File            | Sound         | Creator / source | License  | Notes                       |
| --------------- | ------------- | ---------------- | -------- | --------------------------- |
| `kick.wav`      | Kick (55 Hz)  | Bakushi original (tools/make_starter_kit.py) | CC0 1.0 | 44.1 kHz stereo, 0.42 s    |
| `snare.wav`     | Snare         | Bakushi original | CC0 1.0  | 0.22 s                      |
| `closed_hat.wav`| Closed hat    | Bakushi original | CC0 1.0  | 0.07 s                      |
| `open_hat.wav`  | Open hat      | Bakushi original | CC0 1.0  | 0.40 s                      |
| `clap.wav`      | Clap          | Bakushi original | CC0 1.0  | 0.28 s                      |
| `rimshot.wav`   | Rimshot       | Bakushi original | CC0 1.0  | 0.09 s                      |
| `perc.wav`      | Percussion    | Bakushi original | CC0 1.0  | 0.30 s                      |
| `shaker.wav`    | Shaker        | Bakushi original | CC0 1.0  | 0.50 s                      |
| `loop_90.wav`   | Loop 90 BPM   | Bakushi original | CC0 1.0  | 2-bar boom-bap loop, 5.33 s |
| `loop_100.wav`  | Loop 100 BPM  | Bakushi original | CC0 1.0  | 2-bar boom-bap loop, 4.80 s |
| `loop_120.wav`  | Loop 120 BPM  | Bakushi original | CC0 1.0  | 2-bar boom-bap loop, 4.00 s |

## Status

**Installed** — the kit is synthesized by `tools/make_starter_kit.py` and
deployed as `assets/starter_kit/*.wav` next to the executable. On a brand-
new install the app auto-loads the kit into empty pads on first launch.

### Regenerating

Run `python tools/make_starter_kit.py` (numpy + stdlib only) to regenerate
the WAVs, then copy `assets/starter_kit/` next to the release exe.
2. Name them exactly `kick.wav`, `snare.wav`, `closed_hat.wav`,
   `open_hat.wav`, `clap.wav`, `rimshot.wav`, `perc.wav`, `shaker.wav`
   (44.1 kHz recommended; other rates are auto-converted on load).
3. Copy them into `assets/starter_kit/` next to the app executable.
4. Fill in the manifest table above with the creator, source URL and
   license for each file, and keep proof of the license (e.g. the
   download page link or an export notice).

Pads loaded from the starter kit are visibly labelled
`Starter Kit · <Sound>` and only fill **empty** pads — they never
overwrite stems or custom samples.
