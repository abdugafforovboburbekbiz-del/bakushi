/// Pure DSP helpers. All functions operate on Float32List and are safe to run
/// inside Dart isolates.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// RMS of a window of samples (spec formula).
double frameRMS(Float32List samples, int start, int frameSize) {
  double sum = 0;
  int end = math.min(samples.length, start + frameSize);
  for (int i = start; i < end; i++) {
    sum += samples[i] * samples[i];
  }
  return math.sqrt(sum / math.max(1, end - start));
}

/// RMS of the whole buffer (spec formula).
double calculateRMS(Float32List samples) {
  double sum = 0;
  for (int i = 0; i < samples.length; i++) {
    sum += samples[i] * samples[i];
  }
  return math.sqrt(sum / math.max(1, samples.length));
}

/// Peak absolute amplitude of the buffer.
double calculatePeak(Float32List samples) {
  double peak = 0;
  for (int i = 0; i < samples.length; i++) {
    final a = samples[i].abs();
    if (a > peak) peak = a;
  }
  return peak;
}

/// Linear -> dB, guarded against log(0).
double toDb(double linear) => 20 * math.log(math.max(linear, 1e-9)) / math.ln10;

/// Copy `[start, end)` samples out of a stem channel into a new buffer.
Float32List copyRange(Float32List source, int start, int end) {
  final out = Float32List(end - start);
  out.setRange(0, out.length, source, start);
  return out;
}

/// Apply a short linear fade-in and fade-out to avoid clicks.
void applyMicroFades(Float32List samples, int fadeSamples) {
  if (samples.isEmpty || fadeSamples <= 0) return;
  final n = math.min(fadeSamples, samples.length ~/ 2);
  if (n <= 0) return;
  for (int i = 0; i < n; i++) {
    final g = i / n;
    samples[i] *= g;
    samples[samples.length - 1 - i] *= g;
  }
}

/// Create a pad segment buffer from a stem channel: copy + micro-fades.
/// [gain] (Phase C, 0..2 linear) is baked in with a hard clamp at
/// [-1, 1] so 200% gain can never clip inside the engine.
Float32List createSliceBuffer(
  Float32List stemSamples,
  int startSample,
  int endSample,
  int fadeSamples, {
  double gain = 1.0,
}) {
  final out = copyRange(stemSamples, startSample, endSample);
  applyMicroFades(out, fadeSamples);
  if (gain != 1.0) {
    for (var i = 0; i < out.length; i++) {
      out[i] = (out[i] * gain).clamp(-1.0, 1.0);
    }
  }
  return out;
}

/// Stereo -> mono analysis mix.
Float32List monoDownmix(Float32List left, Float32List right) {
  final n = math.min(left.length, right.length);
  final out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = (left[i] + right[i]) * 0.5;
  }
  return out;
}

/// Hanning window of length n (used by the sidecar for overlap-add; kept here
/// for reference and tests).
Float32List hanningWindow(int n) {
  final w = Float32List(n);
  for (int i = 0; i < n; i++) {
    w[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
  }
  return w;
}

/// True when any sample is NaN or +-Infinity.
bool hasBadValues(Float32List samples) {
  for (int i = 0; i < samples.length; i++) {
    final v = samples[i];
    if (v.isNaN || v.isInfinite) return true;
  }
  return false;
}
