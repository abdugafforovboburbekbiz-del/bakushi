/// Phase C starter kit: pure assignment logic (fills EMPTY pads only,
/// never overwrites existing content).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/models/pad.dart';
import 'package:bakushi/state/starter_kit.dart';

Pad _filled(int id) {
  final pad = Pad(id: id);
  pad
    ..stemName = 'drums'
    ..startSample = 0
    ..endSample = 1000
    ..leftChannel = Float32List(1000)
    ..rightChannel = Float32List(1000);
  return pad;
}

void main() {
  test('starter kit fills EMPTY pads only, in order', () {
    final pads = [for (var i = 0; i < 16; i++) Pad(id: i)];
    // Pad 2 already has stem content; pads 5 and 6 are custom.
    pads[2] = _filled(2);
    pads[5] = _filled(5);
    pads[6] = _filled(6);

    final assignments = starterKitAssignments(pads, starterKitNames);

    expect(assignments.length, 11); // 13 empty pads >= 11 sounds
    // Empty pads only: none of the pre-filled pads are touched.
    for (final a in assignments) {
      expect(a.padIndex, isNot(anyOf(2, 5, 6)));
      expect(pads[a.padIndex].isEmpty, isTrue);
    }
    // Fill order: kick, snare, closed_hat, ... then the loops.
    expect(assignments[0].name, 'kick');
    expect(assignments[1].name, 'snare');
    expect(assignments[8].name, 'loop_90');
    expect(assignments[10].name, 'loop_120');
    expect(assignments.map((a) => a.padIndex).toSet().length, 11);
  });

  test('starter kit never overwrites anything and skips full pads', () {
    // Only 3 empty pads available.
    final pads = [for (var i = 0; i < 16; i++) _filled(i)];
    pads[7].clear();
    pads[11].clear();
    pads[15].clear();

    final assignments = starterKitAssignments(pads, starterKitNames);
    expect(assignments.length, 3); // only the 3 empty pads
    expect(assignments[0].padIndex, 7);
    expect(assignments[1].padIndex, 11);
    expect(assignments[2].padIndex, 15);
    for (final a in assignments) {
      expect(a.name, starterKitNames[assignments.indexOf(a)]);
    }
  });

  test('when every pad is filled there are no assignments '
      '("No empty pads available.")', () {
    final pads = [for (var i = 0; i < 16; i++) _filled(i)];
    expect(starterKitAssignments(pads, starterKitNames), isEmpty);
  });

  test('starterKitLabel reads "Starter Kit · Kick"', () {
    expect(starterKitLabel('kick'), 'Starter Kit · Kick');
    expect(starterKitLabel('closed_hat'), 'Starter Kit · Closed_hat');
    expect(starterKitLabel('loop_120'), 'Starter Kit · Loop 120 BPM');
  });

  test('starterSoundIsLoop flags only the tempo-matched loops', () {
    expect(starterSoundIsLoop('loop_90'), isTrue);
    expect(starterSoundIsLoop('loop_100'), isTrue);
    expect(starterSoundIsLoop('kick'), isFalse);
    expect(starterSoundIsLoop('shaker'), isFalse);
  });

  test('no assignments for an empty sound list', () {
    final pads = [for (var i = 0; i < 16; i++) Pad(id: i)];
    expect(starterKitAssignments(pads, const []), isEmpty);
  });
}
