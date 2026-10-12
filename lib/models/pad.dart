/// A pad in the 16-pad auto-cut sampler: a beat-locked segment of a stem.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class Pad {
  final int id; // 0..15 = engine voice id

  String? stemName;
  int startSample = 0;
  int endSample = 0;
  Float32List? leftChannel;
  Float32List? rightChannel;
  int sampleRate = 44100;

  /// HIT pad (plays once) or LOOP pad (click toggles).
  bool loop = false;

  /// Phase B: this pad holds a user-uploaded sample instead of a stem
  /// segment.
  bool custom = false;

  /// Path of the stored copy of the uploaded sample.
  String? customSourcePath;

  /// Detected BPM of the custom sample (null = one long sample).
  double? customBpm;

  /// Phase C: this pad holds a built-in starter-kit sample.
  bool starter = false;

  /// Starter-kit sound name ('kick', 'snare', ...) when [starter].
  String? starterName;

  /// Phase C: pitch in semitones (-24..+24). Playback rate =
  /// 2^(semitones/12).
  int pitchSemitones = 0;

  /// Phase C: play the slice backwards when true.
  bool reverse = false;

  /// Phase C: linear gain 0..2 (0%..200%). Baked into the pad buffer
  /// with a hard clamp at [-1, 1] when the slice is (re)created.
  double gain = 1.0;

  /// Sampler Polish: edge micro-fade in milliseconds (0..50, default
  /// 5). Baked into the slice at every (re)creation.
  double fadeMs = 5.0;

  /// Sampler Polish: this pad chops the ORIGINAL full mix (no
  /// separation). Bounds only; the source is the shared original PCM.
  bool original = false;

  /// The slice range the pad was originally assigned (auto-fill, upload
  /// or starter kit). "Reset Slice" returns to this range.
  int origStartSample = 0;
  int origEndSample = 0;

  /// True once the user changed this pad's slice manually in the editor.
  bool edited = false;

  /// Human-readable label ('drums 3', 'Custom', 'Starter Kit · Kick').
  String label = '';

  Pad({required this.id});

  bool get isEmpty => leftChannel == null || rightChannel == null;

  double get durationSeconds =>
      sampleRate == 0 ? 0 : (endSample - startSample) / sampleRate;

  /// Playback rate for the current pitch (2^(semitones/12)).
  double get playRate => math.pow(2, pitchSemitones / 12).toDouble();

  /// High-level source kind: 'stem', 'custom', 'starter', 'original'
  /// or 'empty'.
  String get sourceKind {
    if (isEmpty) return 'empty';
    if (custom) return 'custom';
    if (starter) return 'starter';
    if (original) return 'original';
    return 'stem';
  }

  /// Label for an uploaded custom sample (Sampler Polish Task 4).
  static String customLabel(String sourcePath) {
    final seg = sourcePath.split(RegExp(r'[\\/]'));
    final name = seg.isEmpty ? sourcePath : seg.last;
    return 'Custom · $name';
  }

  void clear() {
    stemName = null;
    startSample = 0;
    endSample = 0;
    leftChannel = null;
    rightChannel = null;
    loop = false;
    custom = false;
    customSourcePath = null;
    customBpm = null;
    starter = false;
    starterName = null;
    pitchSemitones = 0;
    reverse = false;
    gain = 1.0;
    fadeMs = 5.0;
    original = false;
    origStartSample = 0;
    origEndSample = 0;
    edited = false;
    label = '';
  }
}
