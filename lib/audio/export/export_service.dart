/// WAV export for stems (fully local, no backend).
library;

import 'dart:typed_data';

import '../../models/audio_models.dart';
import '../wav_codec.dart';

class ExportService {
  const ExportService();

  /// WAV bytes for a full stem.
  Uint8List encodeStemWav(StemAudio stem) =>
      encodeWavFloat32(stem.left, stem.right, stem.sampleRate);

  Future<void> exportStem(StemAudio stem, String path) =>
      writeWavFloat32File(path, stem.left, stem.right, stem.sampleRate);
}
