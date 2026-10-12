/// Uploaded-file decoding: validates the extension, decodes via the sidecar
/// (PyAV) into stereo 44.1 kHz float32 PCM.
library;

import 'dart:async';
import 'dart:io';

import '../../config.dart';
import '../../models/audio_models.dart';
import '../../sidecar/sidecar_client.dart';
import '../pcm_io.dart';

class DecodeException implements Exception {
  final String message;
  final String hint;
  const DecodeException(this.message, this.hint);

  @override
  String toString() => message;
}

class DecoderService {
  final SidecarClient client;
  final Directory workDir;

  DecoderService(this.client, this.workDir);

  /// Validate + decode. Throws [DecodeException] with recovery hints.
  Future<StereoAudio> decode(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw DecodeException(
        'File not found: $filePath',
        'Pick the file again.',
      );
    }
    final ext = filePath
        .split('.')
        .last
        .toLowerCase()
        .replaceAll(RegExp(r'\s'), '');
    if (!AppConfig.supportedExtensions.contains(ext)) {
      throw DecodeException(
        'Unsupported file type: .$ext',
        'Supported formats: ${AppConfig.supportedExtensions.join(', ')}',
      );
    }
    if (file.lengthSync() == 0) {
      throw const DecodeException(
        'The file is empty (0 bytes).',
        'Pick a different audio file.',
      );
    }

    Map<String, dynamic> res;
    try {
      res = await client.request('decode', {
        'path': filePath,
        'out_dir': workDir.path,
      }, timeout: const Duration(minutes: 5));
    } on SidecarException catch (e) {
      throw DecodeException(e.message, e.hint);
    } on TimeoutException {
      throw const DecodeException(
        'Decode timed out - the local Python engine appears stuck.',
        'Restart the app and check the diagnostics log for sidecar errors.',
      );
    }

    final leftPath = res['left_path'] as String?;
    final rightPath = res['right_path'] as String?;
    final frames = (res['frames'] as num?)?.toInt() ?? 0;
    if (leftPath == null || rightPath == null || frames <= 0) {
      throw const DecodeException(
        'Decode produced no PCM data.',
        'The file may be corrupted or contain no audio stream.',
      );
    }
    final left = await readF32Le(leftPath);
    final right = await readF32Le(rightPath);
    if (left.isEmpty || right.isEmpty) {
      throw const DecodeException(
        'Decoded audio is empty.',
        'The file may be corrupted; try another file.',
      );
    }

    final sr =
        (res['sample_rate'] as num?)?.toInt() ?? AppConfig.modelSampleRate;
    final duration = left.length / sr;
    return StereoAudio(
      left: left,
      right: right,
      sampleRate: sr,
      duration: duration,
    );
  }
}
