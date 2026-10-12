# Bakushi — Hobby Sampler UX Research

> Sources: professional sampler/DAW documentation and open-source projects.
> Purpose: ground the Bakushi pad editor in proven patterns WITHOUT turning
> the app into a DAW.

## Product frame (locked)

Bakushi is a **local AI separator + 16-pad HOBBY sampler**. It is:

- NOT a DAW.
- NOT real-time separation — separation is a batch job.
- Stems are **AI estimates**, not studio tracks.

## Main references

1. **Koala Sampler (pad-first shell)** — one screen, a grid of pads, tap
   to play, per-pad controls tucked behind a tap. The pad grid IS the
   app. Reference for: pad-first layout, minimal chrome, instant
   playability.
2. **Serato Sample (auto-pads)** — software auto-assigns detected slices
   to pads, the user corrects. Reference for: automatic → editable flow.
3. **Logic / Quick Sampler waveform editing** — full waveform with a
   start line, an end line, and a tinted selection; drag the lines to
   crop, drag the body to move. Reference for: the cut editor
   (Apple Quick Sampler Slice mode,
   https://support.apple.com/en-my/guide/logicpro/lgcp18515788/).

## What hobby samplers teach us

- **One obvious action per control.** Every visible control does one
  thing; hidden automatic behavior is the #1 confusion source.
- **Show the source and the region.** The user must always see what
  audio a pad uses and which region will play.
- **Pad-first, editor-second.** Play first, edit on demand — never
  block playing behind an editor.
- **Manual correction is normal.** Even pro tools expect the user to
  fix automatic slices by hand; Bakushi's two-line crop editor is the
  human-correction step.
- **Small grids stay readable.** 16 tiles need compact badges (keycap,
  mode, duration, pitch), not full controls per tile.

## Explicit reject list (never build)

Sequencer, piano roll, effects racks, ADSR, filter/LFO, automation,
buses, DAW routing, time-stretch, MIDI routing, social features, new
slicing AI, VST hosting.

## Decision matrix (locked)

| # | Decision | Choice | Reason |
| --- | --- | --- | --- |
| D1 | Performance recording persistence | Save rendered WAV + JSON metadata into `library/<slug>/performances/`; read-only list UI (Preview / Export / Delete) | User can keep a take without a sequencer |
| D2 | "Export Played Pad" | PROCESSED output only (rendered through the pad settings: bounds, pitch, reverse, gain, fades) | What you hear is what you export; no raw-slice confusion |
| D3 | Pitch semantics | Varispeed `rate = 2^(st/12)`, range −24..+24 | Simple, engine-supported, hobby-grade |
| D4 | Per-pad fade | 0–50 ms micro-fade, default 5 ms, baked at slice creation | Click-free pads without an ADSR |
| D5 | Original-sample mode | Chop the full mix WITHOUT separation; pads hold bounds only (shared immutable source PCM) | Sampling own recordings needs no inference |
| D6 | Pan | SKIP — no engine support | Not worth engine changes for a hobby sampler |

## Verification convention

Every feature ships with printed proof (`AppState._action`): bounds,
rates, fades, event counts, render duration, peak, WAV paths, persisted
metadata. Nothing is claimed working without test output or a printed
value.
