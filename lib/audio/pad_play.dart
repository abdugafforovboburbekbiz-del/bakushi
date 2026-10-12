/// Phase C: pure, unit-testable pad playback logic.
///
/// The C engine plays pad voices with play-time pitch (rate), reverse and
/// loop flags. Gain is baked into the buffer in Dart with a hard clamp,
/// so this file only contains decisions that can be verified without any
/// FFI/engine.
library;

import 'dart:math' as math;

import '../config.dart';
import '../models/pad.dart';

/// Pitch range aliases (single source: AppConfig).
const int padPitchMin = AppConfig.padPitchMin;
const int padPitchMax = AppConfig.padPitchMax;

/// Gain range aliases (single source: AppConfig).
const double padGainMin = AppConfig.padGainMin;
const double padGainMax = AppConfig.padGainMax;

/// Minimum slice length (20 ms), computed from the sample rate.
int minSliceSamples(int sampleRate) =>
    math.max(2, (AppConfig.minSliceMs / 1000 * sampleRate).round());

/// Playback rate for [semitones]: rate = 2^(semitones/12).
double padPlayRate(int semitones) => math.pow(2, semitones / 12).toDouble();

/// Clamp [semitones] into the allowed range.
int clampPadPitch(int semitones) => semitones.clamp(padPitchMin, padPitchMax);

/// Clamp [gain] into the allowed 0..2 range.
double clampPadGain(double gain) => gain.clamp(padGainMin, padGainMax);

/// Clamp [fadeMs] into the allowed 0..50 ms range.
double clampPadFadeMs(double fadeMs) =>
    fadeMs.clamp(AppConfig.padFadeMsMin, AppConfig.padFadeMsMax);

/// Fade length in samples for [pad] at [sampleRate].
int padFadeSamples(double fadeMs, int sampleRate) =>
    (clampPadFadeMs(fadeMs) / 1000 * sampleRate).round().clamp(
      0,
      math.max(0, sampleRate ~/ 2),
    );

/// First EMPTY pad index, or null when all 16 pads are filled.
int? firstEmptyPad(List<Pad> pads) {
  for (var i = 0; i < pads.length; i++) {
    if (pads[i].isEmpty) return i;
  }
  return null;
}

/// Reset Sound defaults (Sampler Polish Task 2): neutral sound settings.
/// Bounds restore is handled by the caller (resetPadSound).
void applyResetSoundDefaults(Pad pad) {
  pad
    ..pitchSemitones = 0
    ..reverse = false
    ..gain = 1.0
    ..fadeMs = AppConfig.padFadeMsDefault;
}

/// Empty-pad trigger message (Sampler Polish Task 7): non-null means the
/// trigger must stop BEFORE any engine/FFI call and show this toast.
String? emptyPadTriggerMessage(Pad pad) =>
    pad.isEmpty ? 'Empty pad - select it, then upload or add a sound.' : null;

/// Phase E (vision): how many LOOP pads are sounding simultaneously -
/// the combo-sparkle threshold is 3+.
int countPlayingLoops(List<Pad> pads, List<bool> playingStates) {
  var n = 0;
  for (var i = 0; i < pads.length && i < playingStates.length; i++) {
    if (pads[i].loop && playingStates[i]) n++;
  }
  return n;
}

/// Clamp slice bounds against the source with a minimum length of
/// [minLen] samples. [start]/[end] are the raw user values; both stay
/// inside [0, frames] and `end - start >= minLen` whenever `frames > 0`.
({int start, int end}) clampSliceBounds(
  int start,
  int end,
  int minLen,
  int frames,
) {
  if (frames <= 0) return (start: 0, end: 0);
  final len = math.min(minLen, frames);
  final s = math.max(0, math.min(start, math.max(0, frames - len)));
  var e = math.min(end, frames);
  if (e < s + len) e = math.min(frames, s + len);
  return (start: s, end: e);
}

/// Move a selection of [start..end) by [delta] samples while preserving
/// its duration and clamping it inside [0, frames].
({int start, int end}) moveSlice(int start, int end, int delta, int frames) {
  final dur = math.max(0, end - start);
  if (dur <= 0 || frames <= 0) return (start: 0, end: dur);
  final s = math.max(0, math.min(start + delta, math.max(0, frames - dur)));
  return (start: s, end: s + dur);
}

/// The play-time parameters the engine receives when a pad is triggered
/// or previewed. Gain is baked into the buffer, so it is not part of the
/// spec (the engine always receives 1.0).
class PadPlaySpec {
  final double pitch;
  final bool reverse;
  final bool loop;

  const PadPlaySpec({
    required this.pitch,
    required this.reverse,
    required this.loop,
  });

  /// Play parameters for the current [pad] settings. [preview] forces a
  /// one-shot (never loops), per the Phase C preview rule.
  factory PadPlaySpec.fromPad(Pad pad, {bool preview = false}) {
    return PadPlaySpec(
      pitch: pad.playRate,
      reverse: pad.reverse,
      loop: preview ? false : pad.loop,
    );
  }
}

/// Phase D (vision): in-memory one-level undo snapshot of a pad.
///
/// Captures everything a destructive action can change (bounds, pitch,
/// reverse, gain, fade, label, source kind) WITHOUT the baked buffers -
/// they are re-baked from the source PCM on restore. Pure data, no
/// engine, so it is unit-testable.
class PadSnapshot {
  final String? stemName;
  final bool custom;
  final String? customSourcePath;
  final double? customBpm;
  final bool starter;
  final String? starterName;
  final bool original;
  final int startSample;
  final int endSample;
  final int origStartSample;
  final int origEndSample;
  final bool loop;
  final int pitchSemitones;
  final bool reverse;
  final double gain;
  final double fadeMs;
  final String label;
  final bool edited;

  const PadSnapshot({
    required this.stemName,
    required this.custom,
    required this.customSourcePath,
    required this.customBpm,
    required this.starter,
    required this.starterName,
    required this.original,
    required this.startSample,
    required this.endSample,
    required this.origStartSample,
    required this.origEndSample,
    required this.loop,
    required this.pitchSemitones,
    required this.reverse,
    required this.gain,
    required this.fadeMs,
    required this.label,
    required this.edited,
  });

  /// Capture the current state of [pad]. Returns null for empty pads
  /// (nothing to undo to).
  static PadSnapshot? of(Pad pad) {
    if (pad.isEmpty) return null;
    return PadSnapshot(
      stemName: pad.stemName,
      custom: pad.custom,
      customSourcePath: pad.customSourcePath,
      customBpm: pad.customBpm,
      starter: pad.starter,
      starterName: pad.starterName,
      original: pad.original,
      startSample: pad.startSample,
      endSample: pad.endSample,
      origStartSample: pad.origStartSample,
      origEndSample: pad.origEndSample,
      loop: pad.loop,
      pitchSemitones: pad.pitchSemitones,
      reverse: pad.reverse,
      gain: pad.gain,
      fadeMs: pad.fadeMs,
      label: pad.label,
      edited: pad.edited,
    );
  }
}
