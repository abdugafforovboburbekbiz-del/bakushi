/// Phase-A auto-cut math: beat-locked equal segments from the BPM scalar.
///
/// Pure math - no onset detection, no transient detection, no grid-snap
/// forcing. Segment boundaries land exactly on the beat/bar lines of the
/// uniform grid anchored at sample 0.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../config.dart';
import '../models/pad.dart';
import 'dsp.dart';
import 'pad_play.dart';

class PadSegment {
  final int startSample;
  final int endSample;
  const PadSegment(this.startSample, this.endSample);

  int get length => endSample - startSample;
}

/// Cut [totalFrames] into equal beat-locked segments (at most
/// [maxSegments]).
List<PadSegment> computePadSegments({
  required double bpm,
  required int sampleRate,
  required int totalFrames,
  required Division division,
  int maxSegments = 16,
}) {
  final beatSec = 60.0 / bpm;
  final segSamples = math.max(
    1,
    (division.beats * beatSec * sampleRate).round(),
  );
  final n = math.min(
    maxSegments,
    math.max(1, (totalFrames + segSamples - 1) ~/ segSamples),
  );
  return [
    for (var i = 0; i < n; i++)
      PadSegment(i * segSamples, math.min(totalFrames, (i + 1) * segSamples)),
  ];
}

/// Split 16 pads proportionally across [stemCount] stems (largest
/// remainder: 1->[16], 2->[8,8], 3->[6,5,5], 4->[4,4,4,4]).
List<int> proportionalPadShares(int stemCount) {
  assert(stemCount >= 1);
  final base = 16 ~/ stemCount;
  final rem = 16 % stemCount;
  return [for (var i = 0; i < stemCount; i++) base + (i < rem ? 1 : 0)];
}

/// RMS of the stereo region [startSample, endSample) - the energy used
/// to rank segments (loudest first).
double segmentRms(
  Float32List left,
  Float32List right,
  int startSample,
  int endSample,
) {
  final s = math.max(startSample, 0);
  final e = math.min(endSample, math.min(left.length, right.length));
  if (e <= s) return 0.0;
  var sum = 0.0;
  for (var i = s; i < e; i++) {
    sum += left[i] * left[i] + right[i] * right[i];
  }
  return math.sqrt(sum / (2 * (e - s)));
}

/// Apply new bounds to a pad: clamp, re-copy the PCM from the stem and
/// bake the micro-fades. This is the live slice-edit path (Task 3).
/// [gain] (Phase C, 0..2) is baked into the new buffers with a hard
/// clamp at [-1, 1] so high gains cannot clip.
void applyPadBounds(
  Pad pad, {
  required Float32List stemLeft,
  required Float32List stemRight,
  required int sampleRate,
  required int startSample,
  required int endSample,
  int fadeSamples = 220,
  double gain = 1.0,
}) {
  final frames = math.min(stemLeft.length, stemRight.length);
  final s = math.min(math.max(startSample, 0), math.max(0, frames - 2));
  final e = math.min(math.max(endSample, s + 2), frames);
  pad
    ..startSample = s
    ..endSample = e
    ..leftChannel = createSliceBuffer(stemLeft, s, e, fadeSamples, gain: gain)
    ..rightChannel = createSliceBuffer(stemRight, s, e, fadeSamples, gain: gain)
    ..sampleRate = sampleRate;
}

/// Sampler Polish Task 4B: bake an original-song chop into a pad. The
/// pad holds bounds + a baked slice only - the source PCM stays SHARED
/// (no duplication). A fresh pad gets HIT + neutral settings; an
/// existing pad keeps its loop/pitch/reverse/gain/fade.
void applyChopToPad(
  Pad pad, {
  required Float32List stemLeft,
  required Float32List stemRight,
  required int sampleRate,
  required int start,
  required int end,
  required String label,
}) {
  final wasEmpty = pad.isEmpty;
  final keepLoop = wasEmpty ? false : pad.loop;
  final keepPitch = wasEmpty ? 0 : pad.pitchSemitones;
  final keepReverse = wasEmpty ? false : pad.reverse;
  final keepGain = clampPadGain(wasEmpty ? 1.0 : pad.gain);
  final keepFade = clampPadFadeMs(wasEmpty ? 5.0 : pad.fadeMs);
  pad.clear();
  applyPadBounds(
    pad,
    stemLeft: stemLeft,
    stemRight: stemRight,
    sampleRate: sampleRate,
    startSample: start,
    endSample: end,
    fadeSamples: padFadeSamples(keepFade, sampleRate),
    gain: keepGain,
  );
  pad
    ..original = true
    ..label = label
    ..loop = keepLoop
    ..pitchSemitones = keepPitch
    ..reverse = keepReverse
    ..gain = keepGain
    ..fadeMs = keepFade
    ..origStartSample = start
    ..origEndSample = end
    ..edited = false;
}

// =============================================================
// Phase A (vision upgrade): MUSICAL pad planning.
//
// LOOP pads start on REAL downbeats (2-bar preferred, 1-bar
// fallback), ranked by RMS energy, loudest first. HIT pads are
// onset one-shots from the sidecar (RMS >= 0.01, 50 ms local-RMS
// gate, wait 30 ms). Pads end up with VARIED, musical timestamps -
// explicitly not the old uniform sample-0 grid (computePadSegments
// above stays only as the no-downbeats fallback).
// =============================================================

/// LOOP pad candidates: every segment starts EXACTLY on a downbeat and
/// ends on the downbeat [loopBars] bars later (2-bar preferred).
/// Non-overlapping by construction (downbeats are monotonic).
List<PadSegment> downbeatLoopCandidates({
  required List<int> downbeats,
  required int totalFrames,
  int loopBars = 2,
  int maxSegments = 1 << 30,
}) {
  final dbs = [...downbeats]..sort();
  final out = <PadSegment>[];
  for (var i = 0; i < dbs.length && out.length < maxSegments; i++) {
    final start = dbs[i];
    if (start < 0 || start >= totalFrames) continue;
    final j = i + loopBars;
    if (j >= dbs.length) continue;
    final end = dbs[j];
    if (end <= start || end > totalFrames) continue;
    out.add(PadSegment(start, end));
  }
  return out;
}

/// HIT pad candidates from onset samples: start = onset, end = min(next
/// onset - 10 ms, start + [maxHitSamples]). A new hit must wait
/// [waitMs] after the previously accepted onset.
List<PadSegment> hitCandidates({
  required List<int> onsets,
  required int totalFrames,
  required int sampleRate,
  int waitMs = 30,
  double maxHitMs = 1500,
}) {
  final waitSamples = math.max(1, (sampleRate * waitMs / 1000).round());
  final maxHit = math.max(1, (sampleRate * maxHitMs / 1000).round());
  final gapSamples = math.max(1, (sampleRate * 10 / 1000).round());
  final os = [...onsets]..sort();
  final out = <PadSegment>[];
  var lastStart = -waitSamples - 1;
  for (var i = 0; i < os.length; i++) {
    final s = os[i];
    if (s - lastStart < waitSamples) continue;
    if (s < 0 || s >= totalFrames - 2) continue;
    final next = i + 1 < os.length ? os[i + 1] : totalFrames;
    final end = math.min(math.max(s + 2, next - gapSamples), s + maxHit);
    if (end <= s + 1) continue;
    out.add(PadSegment(s, end));
    lastStart = s;
  }
  return out;
}

/// Keep only segments whose total RMS is >= [minRms] AND whose first
/// [gateMs] ms (local RMS gate) is >= [minRms] - rejects quiet tails
/// and false onset hits.
List<PadSegment> rmsGatedSegments({
  required List<PadSegment> segments,
  required Float32List left,
  required Float32List right,
  required int sampleRate,
  double minRms = 0.01,
  int gateMs = 50,
}) {
  final gate = math.max(1, (sampleRate * gateMs / 1000).round());
  final frames = math.min(left.length, right.length);
  final out = <PadSegment>[];
  for (final seg in segments) {
    if (seg.endSample > frames) continue;
    if (segmentRms(left, right, seg.startSample, seg.endSample) < minRms) {
      continue;
    }
    final gEnd = math.min(seg.startSample + gate, seg.endSample);
    if (segmentRms(left, right, seg.startSample, gEnd) < minRms) continue;
    out.add(seg);
  }
  return out;
}

/// Rank segments by RMS energy, loudest first.
List<({PadSegment segment, double rms})> rankSegmentsByRms(
  List<PadSegment> segments,
  Float32List left,
  Float32List right,
) {
  final ranked = [
    for (final seg in segments)
      (
        segment: seg,
        rms: segmentRms(left, right, seg.startSample, seg.endSample),
      ),
  ];
  ranked.sort((a, b) => b.rms.compareTo(a.rms));
  return ranked;
}

/// Whether [seg] overlaps any interval in [taken] (open intervals).
bool overlapsAny(List<PadSegment> taken, PadSegment seg) {
  for (final t in taken) {
    if (seg.startSample < t.endSample && seg.endSample > t.startSample) {
      return true;
    }
  }
  return false;
}

/// PCM source for one stem, used by the pure planner (unit-testable
/// without AppState).
class FillSource {
  final String name;
  final Float32List left;
  final Float32List right;
  final int sampleRate;

  const FillSource({
    required this.name,
    required this.left,
    required this.right,
    required this.sampleRate,
  });

  int get frames => math.min(left.length, right.length);
}

/// One planned pad fill (bounds + HIT/LOOP mode; buffers are baked by
/// the caller).
class PlannedFill {
  final String stemName;
  final int startSample;
  final int endSample;
  final bool loop;

  const PlannedFill({
    required this.stemName,
    required this.startSample,
    required this.endSample,
    required this.loop,
  });
}

/// Pure musical auto-fill planner.
///
/// [stemNames] = audible stems in fill order, [shares] = per-stem pad
/// counts (proportionalPadShares). Stems with onset data ('drums')
/// become HIT one-shots; the rest become downbeat-anchored LOOPs
/// (2-bar preferred, 1-bar when the song is short). Every group ranks
/// candidates by RMS, loudest first. A HIT stem with no usable onsets
/// falls back to downbeat loops. Returns at most
/// sum(shares) planned fills in stem order.
List<PlannedFill> planMusicalPads({
  required List<String> stemNames,
  required List<int> shares,
  required Map<String, FillSource> sources,
  required double bpm,
  required List<int> downbeats,
  Map<String, List<int>>? onsets,
  double minRms = 0.01,
}) {
  assert(stemNames.length == shares.length);
  final out = <PlannedFill>[];
  for (var si = 0; si < stemNames.length; si++) {
    final name = stemNames[si];
    final src = sources[name];
    if (src == null) continue;
    final needed = shares[si];
    if (needed <= 0) continue;

    final stemOnsets = onsets?[name] ?? const <int>[];
    final wantsHits = name == 'drums' && stemOnsets.isNotEmpty;

    // 1. Candidate geometry.
    final loops2 = downbeatLoopCandidates(
      downbeats: downbeats,
      totalFrames: src.frames,
      loopBars: 2,
    );
    final loops1 = loops2.length < needed
        ? downbeatLoopCandidates(
            downbeats: downbeats,
            totalFrames: src.frames,
            loopBars: 1,
          )
        : const <PadSegment>[];

    List<PadSegment> candidates;
    var loop = true;
    if (wantsHits) {
      candidates = rmsGatedSegments(
        segments: hitCandidates(
          onsets: stemOnsets,
          totalFrames: src.frames,
          sampleRate: src.sampleRate,
        ),
        left: src.left,
        right: src.right,
        sampleRate: src.sampleRate,
        minRms: minRms,
      );
      loop = false;
      // No usable one-shots -> the stem falls back to downbeat loops.
      if (candidates.isEmpty) {
        candidates = loops2.isNotEmpty ? loops2 : loops1;
        loop = true;
      }
    } else {
      // 2-bar preferred, 1-bar when the song is short.
      candidates = loops2.length >= needed ? loops2 : loops1;
    }

    // 2. Rank by RMS energy, loudest first; dedupe by start sample and
    //    skip segments that overlap an already-picked one (pads never
    //    reuse the same source time).
    final ranked = rankSegmentsByRms(candidates, src.left, src.right);
    var taken = 0;
    final used = <PadSegment>[];
    for (final entry in ranked) {
      if (taken >= needed) break;
      final seg = entry.segment;
      if (overlapsAny(used, seg)) continue;
      used.add(seg);
      out.add(
        PlannedFill(
          stemName: name,
          startSample: seg.startSample,
          endSample: seg.endSample,
          loop: loop,
        ),
      );
      taken++;
    }

    // 3. Top the group up from the other geometry kind (LOOP segments
    //    keep their musical loop mode).
    if (taken < needed) {
      final extra = loop ? loops1 : <PadSegment>[...loops2, ...loops1];
      final rankedExtra = rankSegmentsByRms(extra, src.left, src.right);
      for (final entry in rankedExtra) {
        if (taken >= needed) break;
        if (overlapsAny(used, entry.segment)) continue;
        used.add(entry.segment);
        out.add(
          PlannedFill(
            stemName: name,
            startSample: entry.segment.startSample,
            endSample: entry.segment.endSample,
            loop: true,
          ),
        );
        taken++;
      }
    }
  }
  return out;
}

/// Distance (samples, absolute) from [sample] to the nearest downbeat.
/// Used by the acceptance proof: every LOOP pad start must coincide
/// with a downbeat (0 samples) or fall back to a bar-spaced position.
int nearestDownbeatOffset(List<int> downbeats, int sample) {
  if (downbeats.isEmpty) return -1;
  var best = (sample - downbeats[0]).abs();
  for (final d in downbeats) {
    final off = (sample - d).abs();
    if (off < best) best = off;
  }
  return best;
}
