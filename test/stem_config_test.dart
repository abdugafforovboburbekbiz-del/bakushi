/// Config-level sanity checks: display order, engine voice ids and colors.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/config.dart';
import 'package:bakushi/theme/app_theme.dart';

void main() {
  test('four stems in the display order (4-stem model)', () {
    expect(AppConfig.stemNames, ['drums', 'bass', 'other', 'vocals']);
  });

  test('stem voice ids are unique and do not collide with original', () {
    final ids = [
      AppConfig.stemVoiceIdVocals,
      AppConfig.stemVoiceIdDrums,
      AppConfig.stemVoiceIdBass,
      AppConfig.stemVoiceIdOther,
      AppConfig.stemVoiceIdGuitar,
      AppConfig.stemVoiceIdPiano,
    ];
    expect(ids.toSet().length, ids.length);
    for (final id in ids) {
      expect(id, isNot(AppConfig.originalVoiceId));
    }
  });

  test('every stem has a distinct color', () {
    for (final n in AppConfig.stemNames) {
      expect(
        StemColors.forStem(n),
        isNot(StemColors.original),
        reason: 'stem "$n" must have its own color',
      );
    }
  });

  test('near-silent threshold hides stems below RMS 0.01', () {
    expect(AppConfig.silentStemRms, 0.01);
    expect(AppConfig.isSilentRms(0.005), isTrue);
    expect(AppConfig.isSilentRms(0.0008), isTrue);
    expect(AppConfig.isSilentRms(0.012), isFalse);
    expect(AppConfig.isSilentRms(0.023), isFalse);
    expect(AppConfig.isSilentRms(0.1), isFalse);
  });

  test('pad divisions are defined (1 Beat / 1 Bar / 2 Bars)', () {
    expect(Division.values.map((d) => d.label).toList(), [
      '1 Beat',
      '1 Bar',
      '2 Bars',
    ]);
    expect(Division.beat.beats, 1);
    expect(Division.bar.beats, 4);
    expect(Division.twoBars.beats, 8);
  });

  test('fixed pad key layout: QWER / ASDF / ZXCV / 1234', () {
    expect(AppConfig.padAutoKeyOrder, [
      'Q',
      'W',
      'E',
      'R',
      'A',
      'S',
      'D',
      'F',
      'Z',
      'X',
      'C',
      'V',
      '1',
      '2',
      '3',
      '4',
    ]);
    // Pad 1-4 -> QWER, 5-8 -> ASDF, 9-12 -> ZXCV, 13-16 -> 1234.
    String key(int pad) => AppConfig.padAutoKeyOrder[pad];
    expect([for (var p = 0; p < 4; p++) key(p)], ['Q', 'W', 'E', 'R']);
    expect([for (var p = 4; p < 8; p++) key(p)], ['A', 'S', 'D', 'F']);
    expect([for (var p = 8; p < 12; p++) key(p)], ['Z', 'X', 'C', 'V']);
    expect([for (var p = 12; p < 16; p++) key(p)], ['1', '2', '3', '4']);
  });

  test('5-minute cap and 2 s hop are in place for long songs', () {
    expect(AppConfig.maxInputSeconds, 300);
    expect(AppConfig.modelHopSamples, 88200);
    expect(AppConfig.modelSegmentSamples, 343980);
    expect(AppConfig.modelFileName, 'htdemucs_fp16weights.onnx');
  });
}
