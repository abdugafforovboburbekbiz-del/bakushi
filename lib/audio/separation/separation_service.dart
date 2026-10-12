/// AI stem separation orchestration.
///
/// The actual ONNX inference + chunked overlap-add runs in the Python
/// sidecar (onnxruntime with the native OpenVINO runtime as the primary
/// backend and the ORT CPU EP as fallback; DirectML was removed). This
/// service:
///   1. writes the decoded PCM to temp files,
///   2. invokes the sidecar `separate` command with progress + cancel,
///   3. loads the resulting stem PCM,
///   4. validates every stem (length, RMS, peak, NaN/Inf, silence).
library;

import 'dart:io';
import 'dart:typed_data';

import '../../config.dart';
import '../../models/audio_models.dart';
import '../../sidecar/sidecar_client.dart';
import '../dsp.dart';
import '../pcm_io.dart';

class SeparationException implements Exception {
  final String message;
  final String hint;
  const SeparationException(this.message, this.hint);

  @override
  String toString() => message;
}

class SeparationMeta {
  final String provider;
  final String inputName;
  final List<int> inputShape;
  final List<String> outputNames;
  final bool inputFp16;
  final int segment;
  final int modelSizeBytes;
  final int chunks;
  final List<String> stemOrder;

  const SeparationMeta({
    required this.provider,
    required this.inputName,
    required this.inputShape,
    required this.outputNames,
    required this.inputFp16,
    required this.segment,
    required this.modelSizeBytes,
    required this.chunks,
    required this.stemOrder,
  });
}

class SeparationResult {
  final List<StemAudio> stems;
  final SeparationMeta meta;
  const SeparationResult(this.stems, this.meta);

  StemAudio stem(String name) =>
      stems.firstWhere((s) => s.name == name, orElse: () => stems.first);
}

class SeparationService {
  final SidecarClient client;
  final Directory workDir;

  SeparationService(this.client, this.workDir);

  /// Full pipeline. [shouldCancel] is polled every ~400 ms; when it returns
  /// true the sidecar is asked to stop between chunks. [maxSeconds] limits
  /// separation to the first N seconds (0 = full song): for MPC sampling the
  /// hits are almost always in the first ~90 s, and this cuts the work
  /// dramatically on low-end machines.
  Future<SeparationResult> separate({
    required StereoAudio audio,
    required String modelPath,
    double maxSeconds = 0,
    String? provider,
    bool drumPunch = true,
    void Function(SidecarProgress)? onProgress,
    void Function(Map<String, dynamic>)? onMeta,
    void Function(Map<String, dynamic>)? onPunch,
    Future<bool> Function()? shouldCancel,
  }) async {
    if (audio.isEmpty) {
      throw const SeparationException(
        'No audio to separate.',
        'Upload and load an audio file first.',
      );
    }
    final duration = audio.left.length / AppConfig.modelSampleRate;
    if (duration > AppConfig.maxInputSeconds + 0.5) {
      throw SeparationException(
        'Input is too long for the prototype (${duration.toStringAsFixed(1)}s '
            '> ${AppConfig.maxInputSeconds}s cap).',
        'Trim the file to ${AppConfig.maxInputSeconds}s or raise '
            'AppConfig.maxInputSeconds on a machine with enough RAM.',
      );
    }

    var left = audio.left;
    var right = audio.right;
    if (maxSeconds > 0 && duration > maxSeconds) {
      final frames = (maxSeconds * AppConfig.modelSampleRate).round();
      left = Float32List.sublistView(audio.left, 0, frames);
      right = Float32List.sublistView(audio.right, 0, frames);
    }
    // Longer hop for long inputs: far fewer chunks, ~1.5x faster.
    final hopSamples = duration > 120
        ? AppConfig.modelHopSamplesLong
        : AppConfig.modelHopSamples;

    // 1. Write PCM for the sidecar.
    final leftPath = '${workDir.path}${Platform.pathSeparator}input_l.f32le';
    final rightPath = '${workDir.path}${Platform.pathSeparator}input_r.f32le';
    await writeF32Le(leftPath, left);
    await writeF32Le(rightPath, right);

    // 2. Run separation.
    Map<String, dynamic> res;
    Map<String, dynamic>? lastMeta;
    try {
      res = await client.runSeparate(
        {
          'model_path': modelPath,
          'left_path': leftPath,
          'right_path': rightPath,
          'out_dir': workDir.path,
          'hop_samples': hopSamples,
          'provider': ?provider,
        },
        onProgress: onProgress,
        onMeta: (e) {
          lastMeta = e;
          onMeta?.call(e);
        },
        shouldCancel: shouldCancel,
      );
    } on SidecarException catch (e) {
      throw SeparationException(e.message, e.hint);
    } catch (e) {
      throw SeparationException(
        'Stem separation failed: $e',
        'Check the ONNX model path, input shape, and backend.',
      );
    }

    // 2.5. Drum punch: post-process ONLY the drums stem (HPF, transient
    // shaper, punch EQ, NY parallel compression, normalize). Non-fatal -
    // a failure keeps the clean drums instead of losing the separation.
    if (drumPunch) {
      try {
        final punchRes = await client.request('drum_punch', {
          'left_path': '${workDir.path}${Platform.pathSeparator}drums_l.f32le',
          'right_path': '${workDir.path}${Platform.pathSeparator}drums_r.f32le',
          'enabled': true,
        }, timeout: const Duration(minutes: 4));
        onPunch?.call(punchRes);
      } on SidecarException catch (e) {
        onPunch?.call({'applied': false, 'error': e.message});
      } catch (e) {
        onPunch?.call({'applied': false, 'error': '$e'});
      }
    }

    // 3. Load + validate each stem (the model's own stem order: 4 stems
    // for the default model, 6 for the six-stem model).
    final stemsData = res['stems'] as Map<String, dynamic>? ?? const {};
    final stemOrder =
        (res['stem_order'] as List? ?? const []).cast<String>().isNotEmpty
        ? (res['stem_order'] as List).cast<String>()
        : AppConfig.stemNames;
    final stems = <StemAudio>[];
    final silentStems = <String>[];
    for (final name in stemOrder) {
      final d = stemsData[name] as Map<String, dynamic>?;
      if (d == null) {
        throw SeparationException(
          'Model output is missing stem "$name".',
          'The app expects a 4-stem (drums/bass/other/vocals) or 6-stem '
              '(+ guitar/piano) HTDemucs export. Use '
              'htdemucs_fp16weights.onnx or htdemucs_6s_fp16weights.onnx.',
        );
      }
      final lPath = d['left_path'] as String?;
      final rPath = d['right_path'] as String?;
      if (lPath == null || rPath == null) {
        throw SeparationException(
          'Sidecar returned no PCM for stem "$name".',
          'Check the diagnostics log.',
        );
      }
      final left = await readF32Le(lPath);
      final right = await readF32Le(rPath);
      if (left.isEmpty || right.isEmpty) {
        throw SeparationException(
          'Stem "$name" is empty.',
          'The model produced no audio for this stem.',
        );
      }
      if (hasBadValues(left) || hasBadValues(right)) {
        throw SeparationException(
          'Stem "$name" contains NaN/Infinity values.',
          'Model inference produced invalid numbers. Check the model format '
              'and output indexing.',
        );
      }
      final rms =
          (d['rms'] as num?)?.toDouble() ??
          calculateRMS(monoDownmix(left, right));
      final peak =
          (d['peak'] as num?)?.toDouble() ??
          calculatePeak(monoDownmix(left, right));
      if (rms < 1e-6) silentStems.add(name);

      stems.add(
        StemAudio(
          name: name,
          left: left,
          right: right,
          sampleRate: AppConfig.modelSampleRate,
          rms: rms,
          peak: peak,
          duration: left.length / AppConfig.modelSampleRate,
        ),
      );
    }

    // 4. Silent-output hard stop (spec requirement - no fake audio).
    if (stems.every((s) => s.isSilent)) {
      throw const SeparationException(
        'Model inference returned silent output. Check the model format, '
            'tensor shape, output indexing, and backend.',
        'Try a different HTDemucs ONNX export or backend.',
      );
    }

    final metaEvent = lastMeta;
    final metaData = (metaEvent?['data'] as Map<String, dynamic>?) ?? const {};
    final meta = SeparationMeta(
      provider: metaData['provider'] as String? ?? 'unknown',
      inputName: metaData['input_name'] as String? ?? 'unknown',
      inputShape: (metaData['input_shape'] as List? ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
      outputNames: (metaData['output_names'] as List? ?? const [])
          .cast<String>(),
      inputFp16: metaData['input_fp16'] as bool? ?? false,
      segment: (metaData['segment'] as num?)?.toInt() ?? 0,
      modelSizeBytes: (metaData['model_size'] as num?)?.toInt() ?? 0,
      chunks: (res['chunks'] as num?)?.toInt() ?? 0,
      stemOrder: (metaData['stem_order'] as List? ?? const []).cast<String>(),
    );

    return SeparationResult(stems, meta);
  }
}
