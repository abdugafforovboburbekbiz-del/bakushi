/// Step-grid sequencer model (the minimal MPC core).
///
/// Pure data + math, no AppState, no engine. The sequencer renders a
/// full pattern loop OFFLINE with the existing performance renderer and
/// plays the result through a loop voice - nothing here touches the C
/// engine or FFI, so everything is unit-testable.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/render/performance_renderer.dart';

/// One sequencer pattern: [lanes] maps pad index 0..15 to
/// `stepsPerBar * bars` booleans (16th-note grid).
class Pattern {
  double bpm;
  int bars; // 1..4
  final int stepsPerBar; // 16 (16th notes)

  /// pad index -> one boolean per step of the whole pattern.
  Map<int, List<bool>> lanes;

  Pattern({
    required this.bpm,
    required this.bars,
    this.stepsPerBar = 16,
    Map<int, List<bool>>? lanes,
  }) : lanes = lanes ?? {};

  /// Total step cells per lane.
  int get totalSteps => stepsPerBar * bars;

  /// True when no step anywhere is active.
  bool get isEmpty =>
      lanes.isEmpty || lanes.values.every((l) => l.every((v) => !v));

  /// The lane for [pad], created (empty) on first access.
  List<bool> laneFor(int pad) =>
      lanes.putIfAbsent(pad, () => List<bool>.filled(totalSteps, false));

  bool stepAt(int pad, int step) {
    final l = lanes[pad];
    if (l == null || step < 0 || step >= l.length) return false;
    return l[step];
  }

  /// Change the bar count: every lane is resized to the new length
  /// (new cells start off, existing steps keep their positions). Lanes
  /// are REPLACED (they may be fixed-length lists).
  void setBars(int newBars) {
    final b = newBars.clamp(1, 4);
    if (b == bars) return;
    final newLen = stepsPerBar * b;
    final grown = <int, List<bool>>{};
    lanes.forEach((pad, lane) {
      final l = List<bool>.filled(newLen, false);
      final n = math.min(lane.length, newLen);
      for (var i = 0; i < n; i++) {
        l[i] = lane[i];
      }
      grown[pad] = l;
    });
    lanes
      ..clear()
      ..addAll(grown);
    bars = b;
  }

  /// Drop every step (lanes map stays allocated).
  void clear() {
    for (final l in lanes.values) {
      for (var i = 0; i < l.length; i++) {
        l[i] = false;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'bpm': bpm,
    'bars': bars,
    'stepsPerBar': stepsPerBar,
    'lanes': {for (final e in lanes.entries) '${e.key}': e.value},
  };

  /// Restore from state.json (legacy-safe: null/missing -> null).
  static Pattern? fromJson(Map<String, dynamic>? m) {
    if (m == null) return null;
    final bpm = ((m['bpm'] as num?)?.toDouble() ?? 100.0).clamp(60.0, 180.0);
    final bars = ((m['bars'] as num?)?.toInt() ?? 2).clamp(1, 4);
    final lanes = <int, List<bool>>{};
    (m['lanes'] as Map?)?.forEach((k, v) {
      final pad = int.tryParse('$k');
      if (pad == null || pad < 0 || pad > 15 || v is! List) return;
      lanes[pad] = [for (final x in v) x == true];
    });
    return Pattern(bpm: bpm, bars: bars, lanes: lanes);
  }
}

/// Seconds of one 16th-note step.
double stepStartSeconds(int step, double bpm) => step * 60.0 / bpm / 4.0;

/// Sample-accurate start of [step] (16th notes from the pattern start).
int stepStartSamples(int step, double bpm, int sampleRate) =>
    (stepStartSeconds(step, bpm) * sampleRate).round();

/// Milliseconds (PadEvent time base) of [step].
int stepStartMs(int step, double bpm) =>
    (stepStartSeconds(step, bpm) * 1000).round();

/// Loop length of the whole pattern in samples.
int patternFrames({
  required double bpm,
  required int bars,
  required int sampleRate,
}) => (bars * 4 * 60.0 / bpm * sampleRate).round();

/// Build the one-shot trigger timeline for one full pattern loop:
/// active steps only, muted lanes skipped, [bars] reflected through the
/// lane lengths. Sorted by time (then pad) for deterministic rendering.
List<PadEvent> patternEvents({
  required int totalSteps,
  required double bpm,
  required Map<int, List<bool>> lanes,
  Set<int> mutedLanes = const {},
}) {
  final events = <PadEvent>[];
  lanes.forEach((pad, lane) {
    if (mutedLanes.contains(pad)) return;
    final n = math.min(lane.length, totalSteps);
    for (var s = 0; s < n; s++) {
      if (lane[s]) {
        events.add(
          PadEvent(padIndex: pad, kind: 'trigger', timeMs: stepStartMs(s, bpm)),
        );
      }
    }
  });
  events.sort((a, b) {
    final c = a.timeMs.compareTo(b.timeMs);
    return c != 0 ? c : a.padIndex.compareTo(b.padIndex);
  });
  return events;
}

/// Truncate (or zero-pad) a rendered loop to exactly [frames] so the
/// sequencer voice loops at precisely `bars * 4 * 60 / bpm` seconds.
({Float32List left, Float32List right}) fitPatternLoop(
  RenderedPerformance rendered,
  int frames,
) {
  final l = Float32List(frames);
  final r = Float32List(frames);
  final n = math.min(
    frames,
    math.min(rendered.left.length, rendered.right.length),
  );
  if (n > 0) {
    l.setRange(0, n, rendered.left, 0);
    r.setRange(0, n, rendered.right, 0);
  }
  return (left: l, right: r);
}
