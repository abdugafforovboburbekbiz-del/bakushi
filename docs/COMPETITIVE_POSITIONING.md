# Bakushi — Competitive Positioning

> Reconstructed from verified project facts. All performance numbers are
> from Bakushi's own local benchmark on the development machine (Intel
> Iris Xe, 2026-10-11) — they are machine-specific, not market claims.

## What Bakushi actually is

A **local-first, single-device** pipeline: song → AI stem separation →
beat-tracked auto-cut → a 16-pad sampler with per-pad HIT/LOOP, pitch,
reverse, gain, a Canva-style cut editor, custom-sample upload, optional
starter kit, and a persistent local library.

The bet: most "sampler" apps ask the user to source and cut samples
manually; most "stem separation" tools stop at stems. Bakushi connects
the two automatically but keeps the last mile human — every pad is
editable with two draggable cut lines.

## Position vs. comparable products

| Product | What it is | Where Bakushi differs |
| --- | --- | --- |
| StemDeck | Free (Apache-2.0), LOCAL desktop source separation (Demucs 6s) with practice tools | StemDeck has no sampler; Bakushi adds the automatic 16-pad sampler workflow on top of the same model class |
| UVR5 (Ultimate Vocal Remover) | Free GUI with a large model zoo, manual processing | Manual, track-by-track workflow, no sampler; Bakushi automates decode → separation → pads |
| Serato Sample / Studio | Paid; real-time Stems separation inside the sampler | Real-time, pro-grade, paid and closed; Bakushi is offline batch separation with a toy-level cropper |
| djay (Neural Mix) | Freemium; on-device real-time separation for DJing | Real-time DJ tool with closed models; Bakushi targets sampling/beat-making, offline, with editable pads |

## Where Bakushi is honestly strong

1. **Local + private**: the entire pipeline (decode, inference, mixing,
   library) runs on one Windows machine.
2. **Open models, no lock-in**: standard HTDemucs ONNX exports; the
   model file is user-supplied and switchable (4- or 6-stem).
3. **Verified acceleration on the dev machine**: native OpenVINO ≈1.6x
   faster than plain ONNX Runtime CPU on every model tested there
   (0.77x real-time for the default fp16 4-stem model); GPU is used
   only when probe-validated. See the performance disclaimer below.
4. **Automatic → editable**: separation and beat-tracking feed pads
   automatically, but every result is human-correctable with a simple
   visual editor; per-pad settings persist.
5. **Honest about AI limits**: silent stems are filtered with a visible
   threshold, the UI states that stems are AI estimates, and the app
   errors out instead of emitting silent/all-zero audio.

## Where Bakushi is honestly weak (and knows it)

1. **Raw-f32 library size** (~650 MB per 5-min song) — fine for a local
   tool, wasteful vs. FLAC/16-bit storage.
2. **Varispeed pitch only** — no tempo-preserving pitch shift.
3. **Toy-level editor** — deliberately; it is not a DAW.
4. **Hardware-dependent acceleration** — GPU results vary per machine;
   the CPU path is the reliable baseline.
5. **Single song at a time** — no multi-song library editing, no export
   of pad slices.

## Explicit non-claims

Bakushi does **not** claim to be:

- **Real-time** — separation is a batch job (≈0.77x real-time on the
  dev machine, slower when the machine is hot).
- **Perfect source separation** — output is AI-estimated.
- **Original studio stems** — stems are model reconstructions, not the
  master tracks.
- **A DAW, VST, or plugin** — it is a standalone toy-level sampler
  editor.

Stems are AI estimates and may contain bleed or artifacts.

## Performance disclaimer

The "OpenVINO ≈1.6x faster than plain ONNX Runtime CPU" figure was
measured on ONE machine — the Bakushi development laptop (Intel Iris
Xe, Windows, benchmarked 2026-10-11, onnxruntime 1.24.1). It is a
local observation, **not a guarantee** for other hardware or software
versions. The reliable baseline everywhere is the CPU path; GPU
acceleration depends on model/driver compatibility and is
probe-validated before use.

## Positioning statement

> **Local offline AI stem separation plus automatic 16-pad sampler workflow.**
