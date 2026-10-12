/// Resolves the ONNX model file on disk.
///
/// The model is intentionally not bundled into the app. Resolution order:
///   1. persisted user-chosen path (settings file, survives restarts)
///   2. `<working dir>/assets/models/htdemucs_6s.onnx` (flutter run)
///   3. `<exe dir>/assets/models/htdemucs_6s.onnx`
///   4. `<exe dir>/htdemucs_6s.onnx`
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'app_settings.dart';

class ModelLocator {
  ModelLocator._();

  /// User-chosen model path (from "Choose model file").
  static String? userPath;

  static bool _settingsLoaded = false;

  /// Load the persisted model path (if any) from the app support dir.
  static Future<void> loadPersisted() async {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    try {
      final settings = await AppSettings.load();
      final p = settings['model_path'] as String?;
      if (p != null && p.isNotEmpty && File(p).existsSync()) {
        userPath = p;
      }
    } catch (_) {
      // Settings are best-effort; a corrupt file must not block the app.
    }
  }

  /// Remember the user-chosen model path across app restarts.
  static Future<void> persistUserPath(String path) async {
    userPath = path;
    await AppSettings.save({'model_path': path});
  }

  /// The OS application-support directory (shared by settings + library).
  static Future<Directory> appSupportDir() => getApplicationSupportDirectory();

  /// First existing candidate, or null when the model is missing.
  static String? resolve() {
    final candidates = <String>[?userPath, AppConfig.modelPathDefault];
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add(
      '$exeDir${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}models'
      '${Platform.pathSeparator}${AppConfig.modelFileName}',
    );
    candidates.add(
      '$exeDir${Platform.pathSeparator}${AppConfig.modelFileName}',
    );

    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.absolute.path;
    }
    return null;
  }

  /// First existing candidate for the optional 6-stem fp16 model
  /// (guitar + piano), or null. The user-chosen custom path applies to the
  /// default 4-stem model only.
  static String? resolveSixStem() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      AppConfig.sixStemModelPathDefault,
      '$exeDir${Platform.pathSeparator}assets'
          '${Platform.pathSeparator}models'
          '${Platform.pathSeparator}${AppConfig.sixStemModelFileName}',
      '$exeDir${Platform.pathSeparator}${AppConfig.sixStemModelFileName}',
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.absolute.path;
    }
    return null;
  }

  /// Human-readable explanation of where the model is expected.
  static String placementHint() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return 'Place a verified HTDemucs ONNX model at '
        '"${AppConfig.modelPathDefault}" (next to the project root), '
        '"$exeDir${Platform.pathSeparator}${AppConfig.modelFileName}", '
        'or choose it with "Choose model file". See docs/MODEL_SETUP.md.';
  }
}
