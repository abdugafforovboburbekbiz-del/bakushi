# Bakushi — Hobby Sampler UX Spec (Sampler Polish phase)

## Product statement

Bakushi is a **local AI separator + 16-pad HOBBY sampler** for Windows.

- NOT a DAW. NOT real-time separation.
- Stems are **AI estimates**, not studio tracks.
- Main UX reference: Koala pad-first shell + Serato auto-pads + Logic
  waveform editing.

## Non-negotiable audio rules

1. HIT plays the slice once.
2. LOOP: first trigger starts, second trigger stops.
3. Switching HIT ↔ LOOP always stops the pad.
4. Preview is always one-shot (never loops, even for LOOP pads).
5. Changing pitch / reverse / gain / fade / source / bounds stops the
   pad's playback first.
6. Editor drag-release regenerates the pad buffer (with micro-fades) and
   previews once.
7. Every output uses real PCM — never fake audio.

## Controls per pad

| Control | Range | Rule |
| --- | --- | --- |
| Mode | HIT / LOOP | pills; switching always stops |
| Pitch | −24..+24 semitones | `rate = 2^(st/12)` varispeed; slider commits on release + preview |
| Reverse | on / off | engine play-time flag; REV badge |
| Gain | 0–200% | baked + clamped; badge when ≠100% |
| Fade | 0–50 ms, default 5 | baked into every slice; badge when ≠5 ms |
| Reset Sound | — | restores original bounds + pitch 0 + reverse off + gain 100% + fade 5 ms; confirms when edited/custom |
| Reset Slice | — | bounds-only reset to the original range; confirms when edited |
| Upload | wav/mp3/ogg/m4a | copies into app storage; label `Custom · <file>`; confirms when edited/custom |
| Clear | — | confirms when edited/custom |
| Export Played Pad | — | PROCESSED render through all pad settings (D2) |

## Cut editor (unchanged core + fade)

Full-source waveform, centre line, dimmed outside, purple selection,
two 16 px-hit cut lines, Start/End/Duration readouts, exactly 6 actions:
Preview, Stop, Set Start, Set End, Reset Slice, Done. Drag start = start
only, drag end = end only, drag body = move preserving duration. 20 ms
minimum slice. Release regenerates the buffer with the pad's fade and
previews once.

## Recording (performance capture, D1)

- Records trigger/stop events with full pad-setting snapshots.
- Offline render (pure Dart): one-shot varispeed render per trigger,
  LOOP sustains with wrap re-fade until its stop event, overlapping
  events sum, final hard clamp at [−1, 1], pre-clamp peak reported.
- Persisted to `library/<slug>/performances/performance-<ts>.wav` +
  `.json` (`name, createdAt, durationSeconds, sampleRate 44100,
  channels 2, peak, eventCount, sourceSong`).
- UI: Record / Stop Recording / Preview / Export / Discard + a library
  performance list with Preview / Export / Delete ONLY.
- NO timeline editing, NO sequencer, NO overdub, NO quantization, NO
  metronome.

## Original Sample Mode (chop the full mix, no separation)

- Button "Chop Original Song" on Step 2 (works without Separating) and
  in the pads footer.
- Pads hold bounds + baked slices only; the source is the ONE shared
  immutable original PCM (no duplication).
- Chop editor reuses the shared slice-canvas painter; markers for
  existing original-pad regions; controls: Preview, Stop, Set Start,
  Set End, Reset Selection, Assign to Selected Pad, Assign to Next
  Empty Pad, Done; copyright notice.
- Assign to Next Empty Pad never overwrites; if no empty pad the user
  is asked which pad to replace.
- Label `Original · <song title>`; distinct color.
- Persisted like every pad (`original` flag); restored from the
  original PCM on library load.

## Explicit reject list

Sequencer, piano roll, effects, VST, MIDI routing, ADSR, filter/LFO,
automation, buses, time-stretch, social, new slicing AI. Pan is skipped
(no engine support).
