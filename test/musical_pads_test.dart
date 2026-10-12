/// Phase A (vision upgrade): musical pad planning - downbeat-anchored
/// LOOP pads and onset one-shots for HIT pads. Pure math, no AppState,
/// no engine.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/pad_cut.dart';

Float32List _zeros(int n) => Float32List(n);

/// Stereo PCM where a 100-sample region starting at [at] carries a
/// 0.5 amplitude tone (elsewhere silent).
({Float32List left, Float32List right}) _burstAt(
  int total,
  int at, {
  double amp = 0.5,
}) {
  final l = _zeros(total);
  final r = _zeros(total);
  for (var i = at; i < math.min(at + 100, total); i++) {
    l[i] = amp;
    r[i] = amp;
  }
  return (left: l, right: r);
}

void main() {
  const sr = 44100;

  group('downbeatLoopCandidates', () {
    test('every candidate starts exactly on a downbeat', () {
      // Bar = 1000 samples; downbeats every 4 bars.
      final downbeats = [for (var i = 0; i < 20; i++) i * 4000];
      final segs = downbeatLoopCandidates(
        downbeats: downbeats,
        totalFrames: 100000,
        loopBars: 2,
      );
      expect(segs, isNotEmpty);
      for (final seg in segs) {
        expect(downbeats, contains(seg.startSample));
        // 2-bar loop ends on the downbeat 2 bars later.
        final idx = downbeats.indexOf(seg.startSample);
        expect(seg.endSample, downbeats[idx + 2]);
      }
    });

    test('candidates are monotonic and start on every downbeat', () {
      final downbeats = [for (var i = 0; i < 30; i++) i * 4410];
      final segs = downbeatLoopCandidates(
        downbeats: downbeats,
        totalFrames: 200000,
        loopBars: 2,
      );
      for (var i = 0; i < segs.length; i++) {
        expect(segs[i].startSample, downbeats[i]);
      }
    });

    test('loopBars 1 gives bar-length segments', () {
      final downbeats = [0, 4000, 8000, 12000, 16000];
      final segs = downbeatLoopCandidates(
        downbeats: downbeats,
        totalFrames: 20000,
        loopBars: 1,
      );
      expect(segs.map((s) => s.length), everyElement(4000));
    });

    test('segments that would run past the song are skipped', () {
      final downbeats = [0, 4000, 8000, 12000, 16000];
      final segs = downbeatLoopCandidates(
        downbeats: downbeats,
        totalFrames: 14000,
        loopBars: 2,
      );
      for (final seg in segs) {
        expect(seg.endSample, lessThanOrEqualTo(14000));
      }
      expect(segs.every((s) => s.endSample <= 14000), isTrue);
    });
  });

  group('hitCandidates', () {
    test('end = min(next onset - 10 ms, start + maxHit)', () {
      const onset0 = sr ~/ 2; // 500 ms
      const onset1 = onset0 + sr; // 1 s later
      final segs = hitCandidates(
        onsets: [onset0, onset1],
        totalFrames: 10 * sr,
        sampleRate: sr,
      );
      expect(segs.length, 2);
      final tenMs = sr * 10 ~/ 1000;
      expect(segs[0].endSample, onset1 - tenMs);
      expect(segs[1].endSample, onset1 + (sr * 1.5).round());
    });

    test('onsets closer than 30 ms are deduped', () {
      const start = 2 * sr;
      final segs = hitCandidates(
        onsets: [start, start + 100, start + 4000, start + 9000],
        totalFrames: 30 * sr,
        sampleRate: sr,
      );
      // start+100 is within the 30 ms wait -> dropped.
      expect(segs.length, 3);
      expect(segs.first.startSample, start);
      expect(segs[1].startSample, start + 4000);
    });

    test('onset at the very end is skipped', () {
      final segs = hitCandidates(
        onsets: [30 * sr - 1],
        totalFrames: 30 * sr,
        sampleRate: sr,
      );
      expect(segs, isEmpty);
    });
  });

  group('rmsGatedSegments', () {
    test('quiet segments are rejected by the total-RMS gate', () {
      final src = _burstAt(10 * sr, 0, amp: 0.001);
      final segs = rmsGatedSegments(
        segments: const [PadSegment(0, 5000)],
        left: src.left,
        right: src.right,
        sampleRate: sr,
      );
      expect(segs, isEmpty);
    });

    test('loud onset passes; quiet onset fails the 50 ms local gate', () {
      final loud = _burstAt(10 * sr, 0, amp: 0.5);
      final quietStart = _burstAt(10 * sr, 5000, amp: 0.001);
      // Quiet at 5000 but loud later: total RMS is fine, local gate fails.
      for (var i = 8000; i < 8400; i++) {
        quietStart.left[i] = 0.5;
        quietStart.right[i] = 0.5;
      }
      final segs = rmsGatedSegments(
        segments: const [PadSegment(0, 3000), PadSegment(5000, 8000)],
        left: loud.left,
        right: loud.right,
        sampleRate: sr,
      );
      expect(segs.length, 1);
      expect(segs.single.startSample, 0);
    });
  });

  group('planMusicalPads', () {
    test('LOOP stems anchor on downbeats; drums become onset HITs', () {
      const sr = 4410; // 10x smaller keeps the test buffers tiny
      const bar = 8820; // 1 bar at 120 BPM / sr
      final downbeats = [for (var i = 0; i < 40; i++) i * bar];
      final total = 40 * bar;
      final drumsL = _zeros(total);
      final drumsR = _zeros(total);
      // Drum onsets at 5.2 s, 6.0 s, 12.0 s (loud bursts).
      final drumOnsets = [22932, 26460, 52920];
      for (final at in drumOnsets) {
        for (var i = at; i < at + 200; i++) {
          drumsL[i] = 0.8;
          drumsR[i] = 0.8;
        }
      }
      // Bass: quiet everywhere except a region starting exactly on
      // downbeat #5 (44100) and running through downbeat #8.
      final bassL = _zeros(total);
      final bassR = _zeros(total);
      for (var i = 5 * bar; i < 8 * bar; i++) {
        bassL[i] = 0.4;
        bassR[i] = 0.4;
      }
      final fills = planMusicalPads(
        stemNames: ['drums', 'bass'],
        shares: [8, 8],
        sources: {
          'drums': FillSource(
            name: 'drums',
            left: drumsL,
            right: drumsR,
            sampleRate: sr,
          ),
          'bass': FillSource(
            name: 'bass',
            left: bassL,
            right: bassR,
            sampleRate: sr,
          ),
        },
        bpm: 120,
        downbeats: downbeats,
        onsets: {'drums': drumOnsets},
      );
      expect(fills.length, 16);
      final hits = fills.where((f) => f.stemName == 'drums');
      final loops = fills.where((f) => f.stemName == 'bass');
      // Drums: the 3 usable onsets become HITs.
      expect(hits.where((f) => !f.loop).length, 3);
      for (final f in hits.where((f) => !f.loop)) {
        expect(drumOnsets, contains(f.startSample));
      }
      // Bass loops all start on downbeats.
      for (final f in loops) {
        expect(downbeats, contains(f.startSample));
      }
      // Non-overlapping within each stem.
      for (final name in ['drums', 'bass']) {
        final group = fills.where((f) => f.stemName == name).toList();
        for (var i = 0; i < group.length; i++) {
          for (var j = i + 1; j < group.length; j++) {
            final a = group[i];
            final b = group[j];
            final overlaps =
                a.startSample < b.endSample && b.startSample < a.endSample;
            expect(overlaps, isFalse, reason: '$a overlaps $b');
          }
        }
      }
      // Musical = varied timestamps: not every pad has the same length.
      final lengths = fills.map((f) => f.endSample - f.startSample).toSet();
      expect(lengths.length, greaterThan(1));
    });

    test('HIT stem with no usable onsets falls back to downbeat loops', () {
      const bar = 4000;
      final downbeats = [for (var i = 0; i < 20; i++) i * bar];
      final total = 20 * bar;
      final drumsL = _zeros(total);
      final drumsR = _zeros(total);
      final fills = planMusicalPads(
        stemNames: ['drums'],
        shares: [16],
        sources: {
          'drums': FillSource(
            name: 'drums',
            left: drumsL,
            right: drumsR,
            sampleRate: sr,
          ),
        },
        bpm: 120,
        downbeats: downbeats,
        onsets: {
          'drums': [100], // too quiet -> gated out
        },
      );
      // The onset is gated (all-silent PCM), so downbeat loops fill.
      expect(fills, isNotEmpty);
      expect(fills.every((f) => f.loop), isTrue);
      for (final f in fills) {
        expect(downbeats, contains(f.startSample));
      }
    });

    test('short song: 2-bar loops that do not fit fall back to 1-bar', () {
      const bar = 4000;
      // Only 3 downbeats -> one 2-bar loop fits; the share needs more.
      final downbeats = [0, bar, 2 * bar, 3 * bar];
      final total = 4 * bar;
      final bassL = Float32List(total);
      final bassR = Float32List(total);
      for (var i = 0; i < total; i++) {
        bassL[i] = 0.3;
        bassR[i] = 0.3;
      }
      final fills = planMusicalPads(
        stemNames: ['bass'],
        shares: [16],
        sources: {
          'bass': FillSource(
            name: 'bass',
            left: bassL,
            right: bassR,
            sampleRate: sr,
          ),
        },
        bpm: 120,
        downbeats: downbeats,
      );
      expect(fills, isNotEmpty);
      for (final f in fills) {
        expect(downbeats, contains(f.startSample));
        expect(f.loop, isTrue);
      }
    });

    test('ranking picks the loudest segments first', () {
      const bar = 4000;
      final downbeats = [for (var i = 0; i < 16; i++) i * bar];
      final total = 16 * bar;
      final bassL = Float32List(total);
      final bassR = Float32List(total);
      // Region on downbeat #10 is much louder than the rest.
      for (var i = 10 * bar; i < 12 * bar; i++) {
        bassL[i] = 0.9;
        bassR[i] = 0.9;
      }
      for (var i = 0; i < 6 * bar; i++) {
        bassL[i] = 0.1;
        bassR[i] = 0.1;
      }
      final fills = planMusicalPads(
        stemNames: ['bass'],
        shares: [4],
        sources: {
          'bass': FillSource(
            name: 'bass',
            left: bassL,
            right: bassR,
            sampleRate: sr,
          ),
        },
        bpm: 120,
        downbeats: downbeats,
      );
      expect(fills.length, 4);
      expect(fills.first.startSample, 10 * bar);
    });
  });

  group('nearestDownbeatOffset', () {
    test('exact anchor is 0; mid-bar is the bar distance', () {
      const bar = 4000;
      final downbeats = [0, bar, 2 * bar, 3 * bar];
      expect(nearestDownbeatOffset(downbeats, 2 * bar), 0);
      expect(nearestDownbeatOffset(downbeats, 2 * bar + 500), 500);
      expect(nearestDownbeatOffset([], 100), -1);
    });
  });
}
