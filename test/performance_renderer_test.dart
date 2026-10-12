/// Sampler Polish: offline performance renderer tests (Task 5/6).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/dsp.dart';
import 'package:bakushi/audio/render/performance_renderer.dart';
import 'package:bakushi/audio/wav_codec.dart';
import 'package:bakushi/models/pad.dart';

Float32List _sine(int n, {double amp = 0.5, double freq = 440}) {
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amp * math.sin(2 * math.pi * freq * i / 44100);
  }
  return out;
}

PadRenderSpec _spec({
  required Float32List left,
  required Float32List right,
  int pitch = 0,
  bool reverse = false,
  bool loop = false,
  double fadeMs = 5,
}) {
  return PadRenderSpec(
    left: Float32List.fromList(left),
    right: Float32List.fromList(right),
    sampleRate: 44100,
    pitchSemitones: pitch,
    reverse: reverse,
    loop: loop,
    gain: 1.0,
    fadeMs: fadeMs,
    label: 'test',
  );
}

void main() {
  const sr = 44100;

  group('rendering basics', () {
    test('overlapping hits mix (sum)', () {
      final a = _sine(sr ~/ 2, amp: 0.4);
      final z = Float32List(a.length);
      final r = renderPerformanceSync(
        [
          const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0),
          const PadEvent(padIndex: 1, kind: 'trigger', timeMs: 0),
        ],
        {0: _spec(left: a, right: z), 1: _spec(left: a, right: z)},
        sr,
      );
      // Two identical sines sum: peak approaches 2x the single one.
      final single = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {0: _spec(left: a, right: z)},
        sr,
      );
      expect(r.peak, greaterThan(single.peak * 1.5));
      expect(r.left.length, greaterThan(0));
    });

    test('loop sustains until its stop event', () {
      final a = _sine(sr, amp: 0.3);
      final z = Float32List(a.length);
      final r = renderPerformanceSync(
        [
          const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0),
          const PadEvent(padIndex: 0, kind: 'stop', timeMs: 500),
        ],
        {0: _spec(left: a, right: z, loop: true)},
        sr,
      );
      // 500 ms of looping + small tail = ~0.5-0.6 s total.
      expect(r.durationSeconds, greaterThan(0.49));
      expect(r.durationSeconds, lessThan(0.75));
    });

    test('one-shot hit length matches slice duration', () {
      final frames = 4410; // 100 ms
      final a = _sine(frames, amp: 0.3);
      final z = Float32List(frames);
      final r = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {0: _spec(left: a, right: z)},
        sr,
      );
      expect(r.durationSeconds, closeTo(0.1, 0.01));
    });

    test('pitch +12 halves the duration (varispeed)', () {
      final frames = 4410; // 100 ms at rate 1.0
      final a = _sine(frames, amp: 0.3);
      final z = Float32List(frames);
      final r = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {0: _spec(left: a, right: z, pitch: 12)},
        sr,
      );
      expect(r.durationSeconds, closeTo(0.05, 0.01));
    });

    test('reverse plays the buffer backward', () {
      final n = 4410;
      final a = Float32List(n);
      for (var i = 0; i < n; i++) {
        a[i] = (i < n ~/ 2) ? -0.5 : 0.5; // step function
      }
      final z = Float32List(n);
      final fwd = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {0: _spec(left: a, right: z)},
        sr,
      );
      final rev = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {0: _spec(left: a, right: z, reverse: true)},
        sr,
      );
      // First few forward samples are negative; reversed are positive.
      expect(fwd.left[10], lessThan(0));
      expect(rev.left[10], greaterThan(0));
    });

    test('gain baked into the snapshot is applied (clamp keeps 1.0)', () {
      final n = 4410;
      final a = _sine(n, amp: 0.8);
      final z = Float32List(n);
      final baked = createSliceBuffer(a, 0, n, 0, gain: 2.0);
      final r = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {
          0: PadRenderSpec(
            left: baked,
            right: z,
            sampleRate: sr,
            pitchSemitones: 0,
            reverse: false,
            loop: false,
            gain: 2.0,
            fadeMs: 0,
            label: 'g',
          ),
        },
        sr,
      );
      expect(r.peak, closeTo(1.0, 0.02)); // 0.8 * 2 -> clamped at 1.0
    });

    test('baked micro-fades keep edges at zero', () {
      final n = 4410;
      final a = _sine(n, amp: 0.5);
      final z = Float32List(n);
      final baked = createSliceBuffer(a, 0, n, 220);
      final r = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {
          0: PadRenderSpec(
            left: baked,
            right: z,
            sampleRate: sr,
            pitchSemitones: 0,
            reverse: false,
            loop: false,
            gain: 1.0,
            fadeMs: 5,
            label: 'f',
          ),
        },
        sr,
      );
      expect(r.left[0], closeTo(0, 1e-6));
    });

    test('stereo output renders both channels independently', () {
      final n = 4410;
      final l = _sine(n, amp: 0.5);
      final r = Float32List(n); // silent right channel
      final res = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {0: _spec(left: l, right: r)},
        sr,
      );
      var lPeak = 0.0;
      var rPeak = 0.0;
      for (var i = 0; i < res.left.length; i++) {
        if (res.left[i].abs() > lPeak) lPeak = res.left[i].abs();
        if (res.right[i].abs() > rPeak) rPeak = res.right[i].abs();
      }
      expect(lPeak, greaterThan(0.3));
      expect(rPeak, closeTo(0, 1e-6));
    });

    test('safe peak: overlapping loud hits clamp to [-1, 1]', () {
      final n = 4410;
      final a = _sine(n, amp: 0.9);
      final z = Float32List(n);
      final r = renderPerformanceSync(
        [
          const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0),
          const PadEvent(padIndex: 1, kind: 'trigger', timeMs: 0),
          const PadEvent(padIndex: 2, kind: 'trigger', timeMs: 0),
        ],
        {
          0: _spec(left: a, right: z),
          1: _spec(left: a, right: z),
          2: _spec(left: a, right: z),
        },
        sr,
      );
      expect(r.peak, greaterThan(1.0)); // pre-clamp peak proves summing
      for (var i = 0; i < r.left.length; i++) {
        expect(r.left[i].abs(), lessThanOrEqualTo(1.0 + 1e-6));
        expect(r.right[i].abs(), lessThanOrEqualTo(1.0 + 1e-6));
      }
    });

    test('renderSinglePad uses pad settings (Export Played Pad)', () {
      final n = 4410;
      final pad = Pad(id: 3)
        ..leftChannel = createSliceBuffer(_sine(n, amp: 0.5), 0, n, 220)
        ..rightChannel = Float32List(n)
        ..sampleRate = 44100
        ..startSample = 0
        ..endSample = n
        ..pitchSemitones = 12
        ..reverse = false
        ..gain = 1.0
        ..fadeMs = 5;
      final r = renderSinglePad(pad, sampleRate: 44100);
      expect(r.durationSeconds, closeTo(0.05, 0.01)); // +12 halves 100ms
      expect(r.left.length, greaterThan(0));
    });

    test('rendered performance survives a WAV round-trip', () {
      final n = 4410;
      final a = _sine(n, amp: 0.4);
      final z = Float32List(n);
      final r = renderPerformanceSync(
        [const PadEvent(padIndex: 0, kind: 'trigger', timeMs: 0)],
        {0: _spec(left: a, right: z)},
        sr,
      );
      final wav = encodeWavPcm16(r.left, r.right, sr);
      final decoded = readWav(wav);
      expect(decoded.left.length, r.left.length);
      expect(decoded.sampleRate, sr);
      // PCM16 quantizes: peak stays audible.
      var peak = 0.0;
      for (var i = 0; i < decoded.left.length; i++) {
        if (decoded.left[i].abs() > peak) peak = decoded.left[i].abs();
      }
      expect(peak, greaterThan(0.3));
    });
  });
}
