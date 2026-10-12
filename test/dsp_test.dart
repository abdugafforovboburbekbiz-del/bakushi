import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/dsp.dart';

Float32List _sine(double freq, int sr, int n, {double amp = 0.5}) {
  final out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = amp * math.sin(2 * math.pi * freq * i / sr);
  }
  return out;
}

void main() {
  test('calculateRMS of a 0.5 sine is ~0.3535', () {
    final s = _sine(440, 44100, 44100);
    expect(calculateRMS(s), closeTo(0.5 / math.sqrt2, 0.01));
  });

  test('calculateRMS of silence is 0', () {
    expect(calculateRMS(Float32List(1000)), 0);
  });

  test('calculatePeak finds the max amplitude', () {
    final s = Float32List.fromList([0.1, -0.4, 0.9, -0.2]);
    expect(calculatePeak(s), closeTo(0.9, 1e-7));
  });

  test('toDb: -45 dB threshold is respected', () {
    final tiny = toDb(1e-3); // ~ -60 dB
    final loud = toDb(0.5); // ~ -6 dB
    expect(tiny < -45, isTrue);
    expect(loud > -45, isTrue);
  });

  test('monoDownmix averages channels', () {
    final l = Float32List.fromList([1, 0.5, 0]);
    final r = Float32List.fromList([0, 0.5, 1]);
    final m = monoDownmix(l, r);
    expect(m[0], closeTo(0.5, 1e-7));
    expect(m[1], closeTo(0.5, 1e-7));
    expect(m[2], closeTo(0.5, 1e-7));
  });

  test('createSliceBuffer copies range and applies fades', () {
    final src = Float32List.fromList(List.generate(1000, (i) => 0.5));
    final buf = createSliceBuffer(src, 100, 500, 50);
    expect(buf.length, 400);
    expect(buf[0], 0); // fade-in start
    expect(buf[buf.length - 1], 0); // fade-out end
    expect(buf[200], closeTo(0.5, 1e-6)); // untouched middle
  });

  test('createSliceBuffer bakes gain and clamps at 200% (Phase C)', () {
    final src = Float32List.fromList(List.generate(1000, (i) => 0.8));
    final buf = createSliceBuffer(src, 100, 500, 0, gain: 2.0);
    // 0.8 * 2.0 = 1.6 -> clamped to 1.0 (no clipping).
    expect(buf[200], closeTo(1.0, 1e-6));
    expect(calculatePeak(buf), lessThanOrEqualTo(1.0 + 1e-6));
    // 100% gain is identity in the middle.
    final buf1 = createSliceBuffer(src, 100, 500, 0, gain: 1.0);
    expect(buf1[200], closeTo(0.8, 1e-6));
    // 50% halves the amplitude.
    final bufHalf = createSliceBuffer(src, 100, 500, 0, gain: 0.5);
    expect(bufHalf[200], closeTo(0.4, 1e-6));
    // 0% gain produces silence.
    final bufZero = createSliceBuffer(src, 100, 500, 0, gain: 0.0);
    expect(calculatePeak(bufZero), 0.0);
  });

  test('applyMicroFades is symmetric', () {
    final s = Float32List.fromList(List.generate(200, (i) => 0.8));
    applyMicroFades(s, 20);
    expect(s[0], 0);
    expect(s[199], 0);
    expect(s[100], closeTo(0.8, 1e-6));
  });

  test('hasBadValues detects NaN and Infinity', () {
    expect(hasBadValues(Float32List.fromList([double.nan])), isTrue);
    expect(hasBadValues(Float32List.fromList([double.infinity])), isTrue);
    expect(hasBadValues(Float32List.fromList([1.0, -1.0])), isFalse);
  });

  test('hanningWindow starts/ends at zero and peaks in the middle', () {
    final w = hanningWindow(100);
    expect(w[0], closeTo(0, 1e-6));
    expect(w[99], closeTo(0, 1e-6));
    expect(w[50], closeTo(1.0, 1e-3));
  });

  test('frameRMS windows a region only', () {
    final s = Float32List(1000);
    s.setRange(100, 200, Float32List.fromList(List.filled(100, 0.5)));
    expect(frameRMS(s, 100, 100), closeTo(0.5, 1e-6));
    expect(frameRMS(s, 300, 100), closeTo(0, 1e-6));
  });
}
