/// Phase C: optional built-in starter beat kit.
///
/// Sounds are NOT bundled or synthesized. They are resolved from disk,
/// exactly like the ONNX models: `assets/starter_kit/<name>.wav` next to
/// the executable or in the project working directory. When no files are
/// present the UI shows a setup message - no fake sounds are generated.
///
/// Every asset must be CC0/public-domain or an original made for this
/// app, documented in `assets/licenses/STARTER_KIT_LICENSES.md`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../audio/wav_codec.dart';
import '../models/pad.dart';

/// The starter-kit sounds in pad-fill order: 8 one-shots, then the
/// tempo-matched loops (90/100/120 BPM).
const List<String> starterKitNames = [
  'kick',
  'snare',
  'closed_hat',
  'open_hat',
  'clap',
  'rimshot',
  'perc',
  'shaker',
  'loop_90',
  'loop_100',
  'loop_120',
];

/// Human-readable label for a starter sound.
String starterKitLabel(String name) {
  if (name.startsWith('loop_')) {
    final bpm = name.substring('loop_'.length);
    return 'Starter Kit · Loop $bpm BPM';
  }
  final cap = name.isEmpty
      ? name
      : '${name[0].toUpperCase()}${name.substring(1)}';
  return 'Starter Kit · $cap';
}

/// Whether a starter sound is a tempo-matched loop (defaults to LOOP
/// mode instead of HIT).
bool starterSoundIsLoop(String name) => name.startsWith('loop_');

/// Shown when no starter-kit assets are installed.
const String starterKitSetupMessage =
    'Starter kit not installed. Add CC0 or original WAV files as '
    'assets/starter_kit/{kick, snare, closed_hat, open_hat, clap, '
    'rimshot, perc, shaker, loop_90, loop_100, loop_120}.wav next to '
    'the app, or run tools/make_starter_kit.py to synthesize the '
    'built-in set. See assets/licenses/STARTER_KIT_LICENSES.md.';

/// Candidate directories for the starter kit: next to the exe first,
/// then relative to the working directory (source layout).
List<String> starterKitDirs() {
  final dirs = <String>[];
  final exe = Platform.resolvedExecutable;
  if (exe.isNotEmpty) {
    dirs.add(p.join(p.dirname(exe), 'assets', 'starter_kit'));
  }
  dirs.add(p.join(Directory.current.path, 'assets', 'starter_kit'));
  return dirs;
}

/// Installed starter sounds: name -> absolute WAV path.
Map<String, String> availableStarterSounds() {
  final out = <String, String>{};
  for (final dir in starterKitDirs()) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final name in starterKitNames) {
      if (out.containsKey(name)) continue;
      final f = File(p.join(dir, '$name.wav'));
      if (f.existsSync()) out[name] = f.path;
    }
  }
  return out;
}

/// A decoded starter sound (stereo f32 at 44.1 kHz).
class StarterSound {
  final String name;
  final Float32List left;
  final Float32List right;
  final int sampleRate;

  const StarterSound({
    required this.name,
    required this.left,
    required this.right,
    required this.sampleRate,
  });

  int get frames => left.length < right.length ? left.length : right.length;
}

/// Decode one installed starter sound with the Dart WAV decoder.
/// Throws when the file is missing (callers must check
/// [availableStarterSounds] first) or unsupported.
StarterSound loadStarterSound(String name) {
  final path = availableStarterSounds()[name];
  if (path == null) {
    throw StateError('starter sound "$name" is not installed');
  }
  final bytes = File(path).readAsBytesSync();
  final wav = readWav(bytes);
  return StarterSound(
    name: name,
    left: wav.left,
    right: wav.right,
    sampleRate: wav.sampleRate,
  );
}

/// Pure assignment: fill EMPTY pads only, one sound per pad, in order.
/// Never overwrites a pad that already has a source. Returns the
/// (padIndex, soundName) pairs to fill; empty list = "No empty pads".
List<({int padIndex, String name})> starterKitAssignments(
  List<Pad> pads,
  List<String> names,
) {
  final out = <({int padIndex, String name})>[];
  var n = 0;
  for (var i = 0; i < pads.length && n < names.length; i++) {
    if (pads[i].isEmpty) {
      out.add((padIndex: i, name: names[n]));
      n++;
    }
  }
  return out;
}
