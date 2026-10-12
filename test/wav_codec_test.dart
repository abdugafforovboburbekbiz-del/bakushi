import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/wav_codec.dart';

Float32List _sine(double freq, int sr, int n) {
  final out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = 0.8 * math.sin(2 * math.pi * freq * i / sr);
  }
  return out;
}

void main() {
  test('float32 WAV round-trips through the reader', () {
    const sr = 44100;
    final l = _sine(440, sr, sr ~/ 4);
    final r = _sine(220, sr, sr ~/ 4);
    final bytes = encodeWavFloat32(l, r, sr);
    expect(bytes.length, 44 + l.length * 8);

    final decoded = readWav(bytes);
    expect(decoded.sampleRate, sr);
    expect(decoded.left.length, l.length);
    for (int i = 0; i < l.length; i += 997) {
      expect(decoded.left[i], closeTo(l[i], 1e-6));
      expect(decoded.right[i], closeTo(r[i], 1e-6));
    }
  });

  test('PCM16 WAV quantizes within 1/32768', () {
    const sr = 44100;
    final l = _sine(330, sr, 8000);
    final r = _sine(165, sr, 8000);
    final decoded = readWav(encodeWavPcm16(l, r, sr));
    expect(decoded.sampleRate, sr);
    for (int i = 0; i < l.length; i += 313) {
      expect(decoded.left[i], closeTo(l[i], 1 / 32768 + 1e-4));
    }
  });

  test('PCM16 clamps instead of overflowing', () {
    final l = Float32List.fromList([5.0, -5.0, 0.5]);
    final r = Float32List.fromList([-5.0, 5.0, -0.5]);
    final decoded = readWav(encodeWavPcm16(l, r, 44100));
    expect(decoded.left[0], closeTo(1.0, 1e-3));
    expect(decoded.left[1], closeTo(-1.0, 1e-3));
    expect(decoded.left[2], closeTo(0.5, 1e-3));
  });

  test('reader rejects non-WAV data', () {
    expect(() => readWav(Uint8List(64)), throwsFormatException);
    expect(() => readWav(Uint8List(10)), throwsFormatException);
  });
}
