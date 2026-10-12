/// Library persistence: save a song (original + stems + settings), list it,
/// load it back and delete it - all on local disk.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/models/audio_models.dart';
import 'package:bakushi/state/library_store.dart';

void main() {
  test('library save/load round-trips audio, stems and settings', () async {
    final dir = await Directory.systemTemp.createTemp('bakushi_lib_');
    addTearDown(() => dir.delete(recursive: true));
    final store = LibraryStore(dir);

    final n = 8192;
    final l = Float32List(n);
    final r = Float32List(n);
    for (int i = 0; i < n; i++) {
      l[i] = (i % 100) / 100.0;
      r[i] = -((i % 50) / 50.0);
    }
    final stem = StemAudio(
      name: 'drums',
      left: l,
      right: r,
      sampleRate: 44100,
      rms: 0.2,
      peak: 0.9,
      duration: n / 44100,
    );

    final id = await store.saveSong(
      name: 'Test Song.mp3',
      sourcePath: 'C:/music/test.mp3',
      sampleRate: 44100,
      origLeft: l,
      origRight: r,
      stems: {'drums': stem},
      settings: {
        'stemVolumes': {'drums': 0.9},
        'mutedStems': <String>[],
        'soloStem': null,
        'masterVolume': 0.7,
      },
    );
    expect(id, isNotEmpty);

    final entries = await store.list();
    expect(entries.length, 1);
    expect(entries.first.name, 'Test Song.mp3');

    final data = await store.loadSong(id);
    expect(data.origLeft.length, n);
    expect(data.stems.keys, {'drums'});
    expect(data.stems['drums']!.rms, greaterThan(0.05));
    expect(data.settings['masterVolume'], 0.7);
    expect(data.settings['stemVolumes'], {'drums': 0.9});

    // Settings-only update survives a reload.
    await store.saveSettings(id, {'masterVolume': 0.3});
    final data2 = await store.loadSong(id);
    expect(data2.settings['masterVolume'], 0.3);

    await store.deleteSong(id);
    expect(await store.list(), isEmpty);
  });

  test('saving the same name again replaces the entry', () async {
    final dir = await Directory.systemTemp.createTemp('bakushi_lib_');
    addTearDown(() => dir.delete(recursive: true));
    final store = LibraryStore(dir);
    final l = Float32List(100);
    final stem = StemAudio(
      name: 'other',
      left: l,
      right: l,
      sampleRate: 44100,
      rms: 0,
      peak: 0,
      duration: 100 / 44100,
    );
    await store.saveSong(
      name: 'Same Name.mp3',
      sourcePath: 'x',
      sampleRate: 44100,
      origLeft: l,
      origRight: l,
      stems: {'other': stem},
      settings: const {},
    );
    await store.saveSong(
      name: 'Same Name.mp3',
      sourcePath: 'x',
      sampleRate: 44100,
      origLeft: l,
      origRight: l,
      stems: {'other': stem},
      settings: const {},
    );
    expect((await store.list()).length, 1);
  });

  test(
    'per-pad settings block round-trips through state.json (Phase C)',
    () async {
      final dir = await Directory.systemTemp.createTemp('bakushi_lib_');
      addTearDown(() => dir.delete(recursive: true));
      final store = LibraryStore(dir);
      final l = Float32List(100);
      final stem = StemAudio(
        name: 'drums',
        left: l,
        right: l,
        sampleRate: 44100,
        rms: 0.1,
        peak: 0.5,
        duration: 100 / 44100,
      );
      final pads = <String, dynamic>{
        '0': {
          'stemName': 'drums',
          'custom': false,
          'starter': false,
          'original': false,
          'start': 100,
          'end': 200,
          'loop': true,
          'pitch': 5,
          'reverse': true,
          'gain': 1.5,
          'fade': 12.5,
          'label': 'drums 1',
          'edited': true,
          'origStart': 0,
          'origEnd': 400,
        },
        '1': {
          'custom': true,
          'customSourcePath': 'C:/data/custom_samples/my.wav',
          'customBpm': 120.0,
          'starter': false,
          'start': 0,
          'end': 100,
          'loop': false,
          'pitch': -3,
          'reverse': false,
          'gain': 0.75,
          'label': 'Custom',
          'edited': false,
          'origStart': 0,
          'origEnd': 100,
        },
        '2': {
          'starter': true,
          'starterName': 'kick',
          'start': 0,
          'end': 50,
          'loop': false,
          'pitch': 0,
          'reverse': false,
          'gain': 1.0,
          'label': 'Starter Kit · Kick',
          'edited': false,
          'origStart': 0,
          'origEnd': 50,
        },
        '3': {
          'original': true,
          'start': 0,
          'end': 22050,
          'loop': false,
          'pitch': 7,
          'reverse': false,
          'gain': 1.0,
          'fade': 5.0,
          'label': 'Original · Test',
          'edited': false,
          'origStart': 0,
          'origEnd': 22050,
        },
      };
      final id = await store.saveSong(
        name: 'Pads Song.mp3',
        sourcePath: 'y',
        sampleRate: 44100,
        origLeft: l,
        origRight: l,
        stems: {'drums': stem},
        settings: {'pads': pads},
      );
      final data = await store.loadSong(id);
      final restored = (data.settings['pads'] as Map?)!;
      expect(restored['0']['pitch'], 5);
      expect(restored['0']['reverse'], isTrue);
      expect(restored['0']['gain'], 1.5);
      expect(restored['0']['fade'], 12.5);
      expect(restored['0']['loop'], isTrue);
      expect(restored['1']['custom'], isTrue);
      expect(restored['1']['pitch'], -3);
      expect(restored['2']['starterName'], 'kick');
      expect(restored['3']['original'], isTrue);
      expect(restored['3']['pitch'], 7);
    },
  );

  test(
    'atomic save: a failed re-save keeps the previous entry intact',
    () async {
      final dir = await Directory.systemTemp.createTemp('bakushi_lib_');
      addTearDown(() => dir.delete(recursive: true));
      final store = LibraryStore(dir);
      final l = Float32List(4096);
      for (var i = 0; i < l.length; i++) {
        l[i] = (i % 7) / 7.0;
      }
      final stem = StemAudio(
        name: 'drums',
        left: l,
        right: l,
        sampleRate: 44100,
        rms: 0.1,
        peak: 0.5,
        duration: l.length / 44100,
      );
      const name = 'Atomic Song.mp3';
      final id = await store.saveSong(
        name: name,
        sourcePath: 'x',
        sampleRate: 44100,
        origLeft: l,
        origRight: l,
        stems: {'drums': stem},
        settings: {'masterVolume': 0.5},
      );
      final songDir = Directory(
        '${store.root.path}${Platform.pathSeparator}$id',
      );
      final metaPath = '${songDir.path}${Platform.pathSeparator}meta.json';
      final statePath = '${songDir.path}${Platform.pathSeparator}state.json';
      expect(File(metaPath).existsSync(), isTrue);
      expect(File(statePath).existsSync(), isTrue);

      // Re-save with a stem whose file path resolves into a subfolder
      // that never gets created: the write into the temp dir fails on
      // every platform (writeAsBytes does not create parent dirs).
      final badStem = StemAudio(
        name: 'sub/dir/bad',
        left: l,
        right: l,
        sampleRate: 44100,
        rms: 0,
        peak: 0,
        duration: 0,
      );
      await expectLater(
        store.saveSong(
          name: name,
          sourcePath: 'x',
          sampleRate: 44100,
          origLeft: l,
          origRight: l,
          stems: {'sub/dir/bad': badStem},
          settings: {'masterVolume': 0.9},
        ),
        throwsA(anything),
      );

      // The previous save must survive: meta + state still on disk, the
      // settings unchanged, and no temp leftovers.
      expect(File(metaPath).existsSync(), isTrue);
      expect(File(statePath).existsSync(), isTrue);
      final data = await store.loadSong(id);
      expect(data.settings['masterVolume'], 0.5);
      final leftovers = store.root.listSync().whereType<Directory>().where((d) {
        final seg = d.uri.pathSegments.last;
        return seg.contains('.tmp-') || seg.contains('.old-');
      }).toList();
      expect(leftovers, isEmpty);

      // A clean re-save afterwards still replaces the entry.
      await store.saveSong(
        name: name,
        sourcePath: 'x',
        sampleRate: 44100,
        origLeft: l,
        origRight: l,
        stems: {'drums': stem},
        settings: {'masterVolume': 0.9},
      );
      expect((await store.loadSong(id)).settings['masterVolume'], 0.9);
    },
  );
}
