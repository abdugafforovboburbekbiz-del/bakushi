/// Round-trip tests for the little-endian float32 PCM file exchange used
/// between Dart and the Python sidecar.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/pcm_io.dart';

void main() {
  test('float32 PCM round-trips through a temp file', () async {
    final dir = await Directory.systemTemp.createTemp('bakushi_pcm_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}test.f32le';

    final src = Float32List.fromList([
      -1.0,
      -0.5,
      0.0,
      0.25,
      1.0,
      -12345.678,
      3.4e38,
      -3.4e38,
      1e-9,
    ]);
    await writeF32Le(path, src);
    final back = await readF32Le(path);
    expect(back, orderedEquals(src));
  });

  test('read truncates an incomplete trailing sample gracefully', () async {
    final dir = await Directory.systemTemp.createTemp('bakushi_pcm_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}odd.f32le';
    // 10 bytes = 2 full floats + 2 stray bytes.
    await File(path).writeAsBytes(List<int>.generate(10, (i) => i));
    final back = await readF32Le(path);
    expect(back.length, 2);
  });

  test('empty file yields an empty buffer', () async {
    final dir = await Directory.systemTemp.createTemp('bakushi_pcm_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}empty.f32le';
    await File(path).writeAsBytes(const []);
    final back = await readF32Le(path);
    expect(back, isEmpty);
  });
}
