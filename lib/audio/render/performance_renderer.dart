/// Sampler Polish: pure-Dart offline performance renderer.
///
/// Renders a recorded performance (trigger/stop events over pad-setting
/// snapshots) into stereo float32 PCM: one-shot varispeed playback per
/// trigger (rate = 2^(st/12), reverse flag, gain already baked into the
/// snapshot buffers, loop-wrap re-fade), overlapping events sum, final
/// hard clamp at [-1, 1]. Reports the PRE-clamp peak.
///
/// No sequencer, no quantization, no metronome - just the audio the
/// user actually played.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/pad.dart';
import '../pad_play.dart';

/// One recorded action.
class PadEvent {
  final int padIndex;

  /// 'trigger' or 'stop'.
  final String kind;

  /// Milliseconds since recording start.
  final int timeMs;

  const PadEvent({
    required this.padIndex,
    required this.kind,
    required this.timeMs,
  });
}

/// Immutable snapshot of everything the renderer needs for one pad.
class PadRenderSpec {
  final Float32List left;
  final Float32List right;
  final int sampleRate;
  final int pitchSemitones;
  final bool reverse;
  final bool loop;
  final double gain;
  final double fadeMs;
  final String label;

  const PadRenderSpec({
    required this.left,
    required this.right,
    required this.sampleRate,
    required this.pitchSemitones,
    required this.reverse,
    required this.loop,
    required this.gain,
    required this.fadeMs,
    required this.label,
  });

  /// Snapshot of a pad's CURRENT settings (buffers are copied).
  factory PadRenderSpec.fromPad(Pad pad) {
    return PadRenderSpec(
      left: Float32List.fromList(pad.leftChannel ?? Float32List(0)),
      right: Float32List.fromList(pad.rightChannel ?? Float32List(0)),
      sampleRate: pad.sampleRate,
      pitchSemitones: pad.pitchSemitones,
      reverse: pad.reverse,
      loop: pad.loop,
      gain: pad.gain,
      fadeMs: pad.fadeMs,
      label: pad.label,
    );
  }

  int get frames => math.min(left.length, right.length);
}

class RenderedPerformance {
  final Float32List left;
  final Float32List right;
  final double peak; // pre-clamp peak (clipped warning signal)
  final double durationSeconds;
  final int sampleRate;

  const RenderedPerformance({
    required this.left,
    required this.right,
    required this.peak,
    required this.durationSeconds,
    required this.sampleRate,
  });
}

/// Runs [_renderSync] in a worker isolate. Closure is created HERE, in a
/// top-level synchronous function, so its context only holds the three
/// parameters (the known Isolate.run `_Timer` capture bug).
Future<RenderedPerformance> renderPerformanceInIsolate(
  List<PadEvent> events,
  Map<int, PadRenderSpec> specs,
  int sampleRate,
) {
  return Isolate.run(() => _renderSync(events, specs, sampleRate));
}

/// Synchronous render (used as the isolate fallback and by Export Played
/// Pad, where the slice is short).
RenderedPerformance renderPerformanceSync(
  List<PadEvent> events,
  Map<int, PadRenderSpec> specs,
  int sampleRate,
) {
  return _renderSync(events, specs, sampleRate);
}

RenderedPerformance _renderSync(
  List<PadEvent> events,
  Map<int, PadRenderSpec> specs,
  int sampleRate,
) {
  // Sorted timeline.
  final timeline = [...events]..sort((a, b) => a.timeMs.compareTo(b.timeMs));

  // End time of every trigger event.
  final ends = <int>[];
  final stops = <int, List<int>>{}; // padIndex -> stop times
  for (final e in timeline) {
    if (e.kind == 'stop') {
      (stops[e.padIndex] ??= []).add(e.timeMs);
    }
  }
  final consumed = <int, int>{};
  int nextStop(int pad, int afterMs) {
    final list = stops[pad];
    if (list == null) return -1;
    var idx = consumed[pad] ?? 0;
    while (idx < list.length && list[idx] < afterMs) {
      idx++;
    }
    consumed[pad] = idx;
    if (idx >= list.length) return -1;
    final t = list[idx];
    consumed[pad] = idx + 1;
    return t;
  }

  var maxEndMs = 0;
  for (final e in timeline) {
    if (e.kind != 'trigger') continue;
    final spec = specs[e.padIndex];
    if (spec == null || spec.frames == 0) continue;
    final rate = padPlayRate(spec.pitchSemitones);
    final sliceMs = (spec.frames / spec.sampleRate / rate * 1000).ceil();
    int endMs;
    if (spec.loop) {
      final st = nextStop(e.padIndex, e.timeMs);
      endMs = st > e.timeMs ? st : e.timeMs + math.max(500, sliceMs);
    } else {
      endMs = e.timeMs + sliceMs;
    }
    ends.add(endMs);
    maxEndMs = math.max(maxEndMs, endMs);
  }
  if (ends.isEmpty && timeline.isNotEmpty) {
    // Nothing rendered a sound: keep a minimal non-zero length.
    maxEndMs = timeline.last.timeMs + 100;
  }
  if (maxEndMs <= 0) {
    return RenderedPerformance(
      left: Float32List(0),
      right: Float32List(0),
      peak: 0,
      durationSeconds: 0,
      sampleRate: sampleRate,
    );
  }

  final totalFrames = (maxEndMs / 1000 * sampleRate).ceil();
  final outL = Float32List(totalFrames);
  final outR = Float32List(totalFrames);
  var peak = 0.0;

  for (final e in timeline) {
    if (e.kind != 'trigger') continue;
    final spec = specs[e.padIndex];
    if (spec == null || spec.frames == 0) continue;
    final rate = padPlayRate(spec.pitchSemitones);
    final sliceFrames = spec.frames;
    final sliceMs = (sliceFrames / spec.sampleRate / rate * 1000).ceil();
    final loop = spec.loop;
    final endMs = loop
        ? (() {
            final st = nextStop(e.padIndex, e.timeMs);
            return st > e.timeMs ? st : e.timeMs + math.max(500, sliceMs);
          })()
        : e.timeMs + sliceMs;
    final fadeSec = clampPadFadeMs(spec.fadeMs) / 1000;
    final fadeFrames = math.max(0, (fadeSec * sampleRate).round());
    final t0Frame = (e.timeMs / 1000 * sampleRate).round();
    final tEndFrame = (endMs / 1000 * sampleRate).round().clamp(0, totalFrames);
    for (var n = t0Frame; n < tEndFrame; n++) {
      final elapsed = (n - t0Frame) / sampleRate;
      final pos = elapsed * rate * sliceFrames / spec.sampleRate * sampleRate;
      // Same varispeed + reverse math as the C engine (linear interp).
      double i0f;
      double frac;
      if (spec.reverse) {
        final p = (sliceFrames - 1) - (pos % sliceFrames);
        i0f = math.max(0, p.floorToDouble());
        frac = p - i0f;
      } else {
        i0f = pos.floorToDouble();
        frac = pos - i0f;
      }
      var i0 = i0f.toInt();
      var i1 = spec.reverse ? i0 - 1 : i0 + 1;
      if (spec.reverse) {
        if (i1 < 0) i1 = 0;
      } else if (i1 >= sliceFrames) {
        i1 = sliceFrames - 1;
      }
      if (i0 >= sliceFrames) i0 = sliceFrames - 1;
      final l = spec.left[i0] * (1 - frac) + spec.left[i1] * frac;
      final r = spec.right[i0] * (1 - frac) + spec.right[i1] * frac;
      // Loop-wrap re-fade (mirrors the C engine's fade re-arm).
      var wrapGain = 1.0;
      if (loop && fadeFrames > 0) {
        final inIteration = (pos % sliceFrames);
        if (inIteration < fadeFrames) {
          wrapGain = fadeFrames == 0 ? 1.0 : inIteration / fadeFrames;
        }
      }
      outL[n] += l * wrapGain;
      outR[n] += r * wrapGain;
      final a = outL[n].abs();
      final b = outR[n].abs();
      if (a > peak) peak = a;
      if (b > peak) peak = b;
    }
  }

  // Final hard clamp (the safety limiter) after summing.
  for (var n = 0; n < totalFrames; n++) {
    outL[n] = outL[n].clamp(-1.0, 1.0);
    outR[n] = outR[n].clamp(-1.0, 1.0);
  }

  return RenderedPerformance(
    left: outL,
    right: outR,
    peak: peak,
    durationSeconds: totalFrames / sampleRate,
    sampleRate: sampleRate,
  );
}

/// Render a single pad once (Export Played Pad, D2): one non-loop
/// trigger at time 0 through the pad's full settings.
RenderedPerformance renderSinglePad(Pad pad, {int sampleRate = 44100}) {
  final spec = PadRenderSpec.fromPad(pad);
  if (spec.frames == 0) {
    return RenderedPerformance(
      left: Float32List(0),
      right: Float32List(0),
      peak: 0,
      durationSeconds: 0,
      sampleRate: sampleRate,
    );
  }
  return _renderSync(
    [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
    {0: spec},
    sampleRate,
  );
}
