/// Small persisted app settings (bakushi_settings.json in the app
/// support dir). Best-effort: corrupt/missing files never block the app.
///
/// Phase C/D: first-launch flags (starter-kit auto-load, onboarding).
/// ModelLocator's model_path lives in the same file - saves here MERGE
/// with the existing content.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  AppSettings._();

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}bakushi_settings.json');
  }

  /// All settings as a map ({} when missing/corrupt).
  static Future<Map<String, dynamic>> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return {};
      final decoded = jsonDecode(await f.readAsString());
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  /// Merge [values] into the settings file.
  static Future<void> save(Map<String, dynamic> values) async {
    try {
      final cur = await load();
      cur.addAll(values);
      final f = await _file();
      await f.writeAsString(jsonEncode(cur), flush: true);
    } catch (_) {}
  }
}
