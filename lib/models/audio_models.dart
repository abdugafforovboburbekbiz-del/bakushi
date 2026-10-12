/// Core audio data structures used across the app.
library;

import 'dart:typed_data';

import '../config.dart';

/// Stereo PCM decoded from the uploaded file. Always 44100 Hz float32.
class StereoAudio {
  final Float32List left;
  final Float32List right;
  final int sampleRate; // always 44100
  final double duration;

  const StereoAudio({
    required this.left,
    required this.right,
    required this.sampleRate,
    required this.duration,
  });

  int get frames => left.length;

  bool get isEmpty => left.isEmpty && right.isEmpty;
}

/// One AI-separated stem. Buffers are copies derived from the model output.
class StemAudio {
  final String
  name; // "vocals" | "drums" | "bass" | "other" | "guitar" | "piano"
  final Float32List left;
  final Float32List right;
  final int sampleRate;
  final double rms;
  final double peak;
  final double duration;

  const StemAudio({
    required this.name,
    required this.left,
    required this.right,
    required this.sampleRate,
    required this.rms,
    required this.peak,
    required this.duration,
  });

  int get frames => left.length;

  bool get isSilent => rms < AppConfig.silentStemRms;
}

/// One chunk of separated output. In this app the chunked inference runs in
/// the Python sidecar (`infer_chunk`); this type documents the shape contract.
class SeparatedChunk {
  final Float32List vocalsL;
  final Float32List vocalsR;
  final Float32List drumsL;
  final Float32List drumsR;
  final Float32List bassL;
  final Float32List bassR;
  final Float32List otherL;
  final Float32List otherR;
  final Float32List guitarL;
  final Float32List guitarR;
  final Float32List pianoL;
  final Float32List pianoR;

  const SeparatedChunk({
    required this.vocalsL,
    required this.vocalsR,
    required this.drumsL,
    required this.drumsR,
    required this.bassL,
    required this.bassR,
    required this.otherL,
    required this.otherR,
    required this.guitarL,
    required this.guitarR,
    required this.pianoL,
    required this.pianoR,
  });
}
