/// Step-grid sequencer: pure model + math + render round-trip through
/// the existing performance renderer. No AppState, no engine.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/render/performance_renderer.dart';
import 'package:bakushi/models/pattern.dart';

const _sr = 44100;

PadRenderSpec _spec(double amp, {bool loop = false}) {
  final l = Float32List(1000);
  final r = Float32List(1000);
  for (var i = 0; i < 1000; i++) {
    l[i] = amp;
    r[i] = amp;
  }
  return PadRenderSpec(
    left: l,
    right: r,
    sampleRate: _sr,
    pitchSemitones: 0,
    reverse: false,
    loop: loop,
    gain: 1.0,
    fadeMs: 5.0,
    label: 'test',
  );
}

void main() {
  group('step math (16th notes)', () {
    test('stepStartSamples is sample-accurate', () {
      expect(stepStartSamples(0, 120, _sr), 0);
      // One 16th at 120 BPM = 0.125 s = 5512.5 samples (rounded).
      expect(stepStartSamples(4, 120, _sr), 22050);
      expect(stepStartSamples(16, 100, _sr), 105840); // 2.4 s
    });

    test('stepStartMs matches the PadEvent time base', () {
      expect(stepStartMs(8, 100), 1200);
      expect(stepStartMs(0, 180), 0);
    });

    test('patternFrames = bars * 4 * 60 / bpm * sampleRate', () {
      expect(patternFrames(bpm: 120, bars: 1, sampleRate: _sr), 88200);
      expect(patternFrames(bpm: 120, bars: 2, sampleRate: _sr), 176400);
      expect(patternFrames(bpm: 100, bars: 4, sampleRate: _sr), 423360);
    });
  });

  group('Pattern model', () {
    test('laneFor grows on demand and totalSteps follows bars', () {
      final p = Pattern(bpm: 120, bars: 2);
      expect(p.totalSteps, 32);
      final lane = p.laneFor(3);
      expect(lane.length, 32);
      expect(lane.every((v) => !v), isTrue);
      expect(p.isEmpty, isTrue);
    });

    test('setBars resizes lanes and preserves existing steps', () {
      final p = Pattern(bpm: 120, bars: 1);
      final lane = p.laneFor(0);
      lane[3] = true;
      lane[15] = true;
      p.setBars(2);
      expect(p.bars, 2);
      expect(p.totalSteps, 32);
      final grown = p.laneFor(0);
      expect(grown.length, 32);
      expect(grown[3], isTrue);
      expect(grown[15], isTrue);
      expect(grown[16], isFalse);
      // Shrink back truncates.
      p.setBars(1);
      final shrunk = p.laneFor(0);
      expect(shrunk.length, 16);
      expect(shrunk[3], isTrue);
    });

    test('toJson/fromJson round-trips', () {
      final p = Pattern(bpm: 132, bars: 4);
      final lane = p.laneFor(7);
      lane[0] = true;
      lane[63] = true;
      final restored = Pattern.fromJson(p.toJson())!;
      expect(restored.bpm, 132);
      expect(restored.bars, 4);
      expect(restored.stepAt(7, 0), isTrue);
      expect(restored.stepAt(7, 63), isTrue);
      expect(restored.stepAt(7, 1), isFalse);
    });

    test('fromJson is legacy-safe and clamps', () {
      expect(Pattern.fromJson(null), isNull);
      expect(Pattern.fromJson({}), isNotNull);
      final weird = Pattern.fromJson({
        'bpm': 999,
        'bars': 99,
        'lanes': {'2': [true, false]},
      })!;
      expect(weird.bpm, 180);
      expect(weird.bars, 4);
      expect(weird.stepAt(2, 0), isTrue);
    });
  });

  group('patternEvents', () {
    test('builds one trigger per active step, sorted by time', () {
      final lanes = {
        0: [true, false, false, true, false, false, false, false],
        3: [false, false, true, false, false, false, false, false],
      };
      final events = patternEvents(totalSteps: 8, bpm: 120, lanes: lanes);
      expect(events.length, 3);
      expect(events[0].padIndex, 0);
      expect(events[0].timeMs, 0);
      expect(events[1].timeMs, 250); // step 2 @ 120 BPM
      expect(events[2].padIndex, 0);
      expect(events[2].timeMs, 375); // step 3
    });

    test('muted lanes are skipped entirely', () {
      final lanes = {
        0: [true, true],
        5: [true, true],
      };
      final events = patternEvents(
        totalSteps: 2,
        bpm: 120,
        lanes: lanes,
        mutedLanes: {5},
      );
      expect(events.length, 2);
      expect(events.every((e) => e.padIndex == 0), isTrue);
    });

    test('bars multiply the lane length into more steps', () {
      final lanes = {0: List<bool>.filled(32, false)};
      lanes[0]![20] = true;
      final events = patternEvents(totalSteps: 32, bpm: 100, lanes: lanes);
      expect(events.single.timeMs, stepStartMs(20, 100));
      expect(stepStartMs(20, 100), 3000); // 20 * 150 ms
    });

    test('empty lanes produce no events', () {
      expect(patternEvents(totalSteps: 16, bpm: 120, lanes: {}), isEmpty);
    });
  });

  group('render round-trip via renderPerformance', () {
    test('one full bar renders non-zero PCM with the exact loop length', () {
      final bpm = 120.0;
      final bars = 1;
      final lanes = {0: List<bool>.filled(16, false)};
      lanes[0]![0] = true;
      lanes[0]![4] = true;
      lanes[0]![8] = true;
      final events = patternEvents(totalSteps: 16, bpm: bpm, lanes: lanes);
      final specs = {0: _spec(0.4)};
      final rendered = renderPerformanceSync(events, specs, _sr);
      expect(rendered.durationSeconds, greaterThan(0));
      // Fit to the pattern loop: EXACTLY bars*4*60/bpm seconds.
      final frames = patternFrames(bpm: bpm, bars: bars, sampleRate: _sr);
      final loop = fitPatternLoop(rendered, frames);
      expect(loop.left.length, frames);
      expect(loop.right.length, frames);
      var nonZero = false;
      for (var i = 0; i < frames; i++) {
        if (loop.left[i] != 0 || loop.right[i] != 0) {
          nonZero = true;
          break;
        }
      }
      expect(nonZero, isTrue);
    });

    test('two bars at a different tempo render at the right length', () {
      final bpm = 100.0;
      final bars = 2;
      final lanes = {2: List<bool>.filled(32, false)};
      lanes[2]![31] = true; // last step only
      final events = patternEvents(totalSteps: 32, bpm: bpm, lanes: lanes);
      final rendered = renderPerformanceSync(events, {2: _spec(0.2)}, _sr);
      final frames = patternFrames(bpm: bpm, bars: bars, sampleRate: _sr);
      final loop = fitPatternLoop(rendered, frames);
      expect(loop.left.length, frames);
      // The hit at the last step starts ~(31 * 150 ms) = 4.65 s in a
      // 4.8 s loop - rendered buffer must cover it.
      expect(rendered.durationSeconds, greaterThanOrEqualTo(4.65));
    });

    test('multiple lanes mix together', () {
      final lanes = {
        0: List<bool>.filled(16, false)..[0] = true,
        1: List<bool>.filled(16, false)..[4] = true,
      };
      final events = patternEvents(totalSteps: 16, bpm: 120, lanes: lanes);
      final rendered = renderPerformanceSync(
        events,
        {0: _spec(0.4), 1: _spec(0.3)},
        _sr,
      );
      final frames = patternFrames(bpm: 120, bars: 1, sampleRate: _sr);
      final loop = fitPatternLoop(rendered, frames);
      expect(loop.left.length, frames);
      // The first 1000 samples carry the pad-0 tone.
      expect(loop.left[500].abs(), greaterThan(0.1));
    });
  });
}
