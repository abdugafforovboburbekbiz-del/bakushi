/// Raw little-endian float32 PCM file exchange with the Python sidecar.
///
/// The Dart VM runs little-endian on every supported Bakushi platform
/// (Windows x64 / ARM64), so the per-sample byte swaps are replaced with
/// O(1) typed-data views - important for multi-minute stereo files.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

Future<Float32List> readF32Le(String path) async {
  final bytes = await Isolate.run(() => File(path).readAsBytes());
  final n = bytes.length ~/ 4;
  return Float32List.view(bytes.buffer, bytes.offsetInBytes, n);
}

Future<void> writeF32Le(String path, Float32List samples) async {
  final bytes = Uint8List.view(
    samples.buffer,
    samples.offsetInBytes,
    samples.lengthInBytes,
  );
  // Large writes (tens of MB per channel) run in a worker isolate so the
  // UI thread is never blocked while the sidecar input is prepared.
  await Isolate.run(() => File(path).writeAsBytes(bytes, flush: true));
}
