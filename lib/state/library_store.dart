/// Local song library: persists the original audio, the separated stems and
/// the user's MPC setup (slices, pads, mixer) so a song can be reopened
/// instantly without re-running separation. Everything stays on this machine.
///
/// Audio is stored as raw little-endian float32 (zero-cost read/write, no
/// encoding loops): `<song>/original_{l,r}.f32le` and
/// `<song>/stems/<name>_{l,r}.f32le`. Older PCM16-WAV entries still load.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm_io.dart';
import '../audio/wav_codec.dart';
import '../models/audio_models.dart';

class LibraryEntry {
  final String id;
  final String name;
  final String sourcePath;
  final double durationSec;
  final int sampleRate;
  final int sizeBytes;
  final DateTime savedAt;

  const LibraryEntry({
    required this.id,
    required this.name,
    required this.sourcePath,
    required this.durationSec,
    required this.sampleRate,
    required this.sizeBytes,
    required this.savedAt,
  });

  factory LibraryEntry.fromJson(String id, Map<String, dynamic> j) {
    return LibraryEntry(
      id: id,
      name: j['name'] as String? ?? id,
      sourcePath: j['sourcePath'] as String? ?? '',
      durationSec: (j['durationSec'] as num?)?.toDouble() ?? 0,
      sampleRate: (j['sampleRate'] as num?)?.toInt() ?? 44100,
      sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      savedAt:
          DateTime.tryParse(j['savedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Everything needed to restore a song in the app.
class LibraryLoadData {
  final LibraryEntry entry;
  final Float32List origLeft;
  final Float32List origRight;
  final Map<String, StemAudio> stems;
  final Map<String, dynamic> settings;

  const LibraryLoadData({
    required this.entry,
    required this.origLeft,
    required this.origRight,
    required this.stems,
    required this.settings,
  });
}

class LibraryStore {
  final Directory root;

  /// [appSupportDir] is the OS application-support directory; entries are
  /// stored under `<appSupport>/library/<songId>/`.
  LibraryStore(Directory appSupportDir)
    : root = Directory('${appSupportDir.path}${Platform.pathSeparator}library');

  // ------------------------------------------------------------------ listing

  Future<List<LibraryEntry>> list() async {
    await root.create(recursive: true);
    final out = <LibraryEntry>[];
    if (!root.existsSync()) return out;
    for (final d in root.listSync().whereType<Directory>()) {
      final seg = d.uri.pathSegments.last;
      // Skip in-progress atomic-save dirs and old-entry backups.
      if (seg.contains('.tmp-') || seg.contains('.old-')) continue;
      final metaFile = File('${d.path}${Platform.pathSeparator}meta.json');
      if (!metaFile.existsSync()) continue;
      try {
        final j =
            jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        out.add(LibraryEntry.fromJson(d.uri.pathSegments.last, j));
      } catch (_) {
        // Skip corrupt entries; they must not break the library list.
      }
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }

  // ------------------------------------------------------------------- saving

  /// Save the original + all stems as raw float32 PCM (one file per
  /// channel; O(1) typed-data views - no encoding loops) and the session
  /// settings. Returns the song id (deterministic per name: re-saving the
  /// same song overwrites the previous entry).
  ///
  /// ATOMIC REPLACE: everything is written into a sibling temp dir
  /// `<slug>.tmp-<pid>-<millis>` first. Only when every file is on disk
  /// is the old entry moved aside (`.old-<ts>`) and the temp dir renamed
  /// to `<slug>`. On any failure the temp dir is removed and the previous
  /// save survives intact.
  Future<String> saveSong({
    required String name,
    required String sourcePath,
    required int sampleRate,
    required Float32List origLeft,
    required Float32List origRight,
    required Map<String, StemAudio> stems,
    required Map<String, dynamic> settings,
  }) async {
    final id = _slug(name);
    final dir = Directory('${root.path}${Platform.pathSeparator}$id');
    await root.create(recursive: true);
    final stamp = '$pid-${DateTime.now().millisecondsSinceEpoch}';
    final temp = Directory(
      '${root.path}${Platform.pathSeparator}$id.tmp-$stamp',
    );
    await temp.create(recursive: true);
    final stemDir = Directory('${temp.path}${Platform.pathSeparator}stems');
    await stemDir.create(recursive: true);
    Directory? oldBackup;
    try {
      var totalBytes = origLeft.lengthInBytes + origRight.lengthInBytes;
      for (final stem in stems.values) {
        totalBytes += stem.left.lengthInBytes + stem.right.lengthInBytes;
      }

      // Each file is tens of MB; the actual write runs in a worker isolate
      // so auto-saving after separation never freezes the UI.
      Future<void> writeRaw(String rel, Float32List samples) {
        final bytes = Uint8List.view(
          samples.buffer,
          samples.offsetInBytes,
          samples.lengthInBytes,
        );
        return Isolate.run(
          () =>
              File('${temp.path}${Platform.pathSeparator}$rel')
                  .writeAsBytes(bytes, flush: true),
        );
      }

      Future<void> writePair(
        String prefix,
        Float32List l,
        Float32List r,
      ) async {
        await writeRaw('${prefix}_l.f32le', l);
        await writeRaw('${prefix}_r.f32le', r);
      }

      await writePair('original', origLeft, origRight);
      for (final stem in stems.values) {
        await writePair('stems/${stem.name}', stem.left, stem.right);
      }

      final meta = {
        'name': name,
        'sourcePath': sourcePath,
        'durationSec': origLeft.length / sampleRate,
        'sampleRate': sampleRate,
        'sizeBytes': totalBytes,
        'savedAt': DateTime.now().toIso8601String(),
        'stemFrames': origLeft.length,
      };
      await File('${temp.path}${Platform.pathSeparator}meta.json')
          .writeAsString(jsonEncode(meta), flush: true);
      await File('${temp.path}${Platform.pathSeparator}state.json')
          .writeAsString(jsonEncode(settings), flush: true);

      // Commit: move the old entry aside (it survives any later failure),
      // then swap the new one in.
      if (dir.existsSync()) {
        oldBackup = Directory(
          '${root.path}${Platform.pathSeparator}$id.old-$stamp',
        );
        await dir.rename(oldBackup.path);
      }
      await temp.rename(dir.path);

      // Best-effort cleanup of the previous entry. If it cannot be
      // deleted right now it stays as `<slug>.old-*` and is skipped by
      // list(); the new entry is already live.
      final backup = oldBackup;
      if (backup != null && backup.existsSync()) {
        try {
          await backup.delete(recursive: true);
        } catch (_) {}
      }
      return id;
    } catch (e) {
      if (temp.existsSync()) {
        try {
          await temp.delete(recursive: true);
        } catch (_) {}
      }
      // If the old entry was moved aside but the swap never happened,
      // put it back - the previous save must survive.
      final backup = oldBackup;
      if (backup != null && backup.existsSync() && !dir.existsSync()) {
        try {
          await backup.rename(dir.path);
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Persist only the session settings (slices/pads/mixer) for an entry.
  Future<void> saveSettings(String id, Map<String, dynamic> settings) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$id');
    if (!dir.existsSync()) return;
    await File('${dir.path}${Platform.pathSeparator}state.json')
        .writeAsString(jsonEncode(settings), flush: true);
  }

  // ------------------------------------------------------------ performances

  /// Where rendered performances of a library song live (D1).
  Directory performanceDir(String id) => Directory(
    '${root.path}${Platform.pathSeparator}$id'
    '${Platform.pathSeparator}performances',
  );

  /// Save a rendered performance: `performance-<ts>.wav` + `.json` with
  /// exactly {name, createdAt, durationSeconds, sampleRate, channels,
  /// peak, eventCount, sourceSong}. Returns the WAV path.
  Future<String> savePerformance(
    String id,
    Uint8List wavBytes,
    Map<String, dynamic> meta,
  ) async {
    final dir = performanceDir(id);
    await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final base = 'performance-$stamp';
    await File('${dir.path}${Platform.pathSeparator}$base.wav')
        .writeAsBytes(wavBytes, flush: true);
    await File('${dir.path}${Platform.pathSeparator}$base.json')
        .writeAsString(jsonEncode(meta), flush: true);
    return '${dir.path}${Platform.pathSeparator}$base.wav';
  }

  /// List saved performance metadata (newest first); each entry also
  /// carries its 'wavPath'.
  Future<List<Map<String, dynamic>>> listPerformances(String id) async {
    final dir = performanceDir(id);
    final out = <Map<String, dynamic>>[];
    if (!dir.existsSync()) return out;
    for (final f in dir.listSync().whereType<File>()) {
      final seg = f.uri.pathSegments.last;
      if (!seg.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final base = seg.substring(0, seg.length - '.json'.length);
        out.add({
          ...j,
          'wavPath': '${dir.path}${Platform.pathSeparator}$base.wav',
        });
      } catch (_) {
        // Skip corrupt performance metadata.
      }
    }
    out.sort(
      (a, b) => '${b['createdAt'] ?? ''}'.compareTo('${a['createdAt'] ?? ''}'),
    );
    return out;
  }

  /// Delete one performance (WAV + its JSON metadata).
  Future<void> deletePerformance(String id, String wavPath) async {
    final w = File(wavPath);
    if (w.existsSync()) await w.delete();
    final j = File('${wavPath.substring(0, wavPath.length - 4)}.json');
    if (j.existsSync()) await j.delete();
  }

  // ------------------------------------------------------------------ loading

  Future<LibraryLoadData> loadSong(String id) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$id');
    final metaFile = File('${dir.path}${Platform.pathSeparator}meta.json');
    if (!metaFile.existsSync()) {
      throw StateError('Library entry "$id" not found.');
    }
    final meta =
        jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final entry = LibraryEntry.fromJson(id, meta);

    final origPathL = '${dir.path}${Platform.pathSeparator}original_l.f32le';
    final origPathR = '${dir.path}${Platform.pathSeparator}original_r.f32le';
    final origWav = '${dir.path}${Platform.pathSeparator}original.wav';
    Float32List origLeft;
    Float32List origRight;
    if (File(origPathL).existsSync() && File(origPathR).existsSync()) {
      origLeft = await readF32Le(origPathL);
      origRight = await readF32Le(origPathR);
    } else if (File(origWav).existsSync()) {
      // Legacy PCM16 WAV entry.
      final w = readWav(File(origWav).readAsBytesSync());
      origLeft = w.left;
      origRight = w.right;
    } else {
      throw StateError('Library entry "$id" has no audio data.');
    }

    final loaded = <String, StemAudio>{};
    final stemDir = Directory('${dir.path}${Platform.pathSeparator}stems');
    if (stemDir.existsSync()) {
      final names = <String>{};
      for (final f in stemDir.listSync().whereType<File>()) {
        final n = f.uri.pathSegments.last;
        if (n.endsWith('_l.f32le')) {
          names.add(n.substring(0, n.length - '_l.f32le'.length));
        } else if (n.endsWith('.wav')) {
          names.add(n.substring(0, n.length - 4));
        }
      }
      for (final name in names) {
        final lPath = '${stemDir.path}${Platform.pathSeparator}${name}_l.f32le';
        final rPath = '${stemDir.path}${Platform.pathSeparator}${name}_r.f32le';
        final wavPath = '${stemDir.path}${Platform.pathSeparator}$name.wav';
        Float32List l;
        Float32List r;
        if (File(lPath).existsSync() && File(rPath).existsSync()) {
          l = await readF32Le(lPath);
          r = await readF32Le(rPath);
        } else if (File(wavPath).existsSync()) {
          // Legacy PCM16 WAV stem.
          final w = readWav(File(wavPath).readAsBytesSync());
          l = w.left;
          r = w.right;
        } else {
          continue;
        }
        loaded[name] = StemAudio(
          name: name,
          left: l,
          right: r,
          sampleRate: entry.sampleRate,
          rms: _rms(l, r),
          peak: _peak(l, r),
          duration: l.length / entry.sampleRate,
        );
      }
    }

    Map<String, dynamic> settings = const {};
    final st = File('${dir.path}${Platform.pathSeparator}state.json');
    if (st.existsSync()) {
      try {
        settings = jsonDecode(await st.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
    }

    return LibraryLoadData(
      entry: entry,
      origLeft: origLeft,
      origRight: origRight,
      stems: loaded,
      settings: settings,
    );
  }

  Future<void> deleteSong(String id) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$id');
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  static double _rms(Float32List l, Float32List r) {
    double sum = 0;
    final n = math.min(l.length, r.length);
    for (int i = 0; i < n; i++) {
      final v = (l[i] + r[i]) * 0.5;
      sum += v * v;
    }
    return math.sqrt(sum / math.max(1, n));
  }

  static double _peak(Float32List l, Float32List r) {
    double p = 0;
    final n = math.min(l.length, r.length);
    for (int i = 0; i < n; i++) {
      final a = l[i].abs();
      if (a > p) p = a;
      final b = r[i].abs();
      if (b > p) p = b;
    }
    return p;
  }

  static String _slug(String name) {
    var s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.isEmpty) s = 'song';
    return s;
  }
}
