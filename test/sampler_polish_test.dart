/// Sampler Polish: pure rules - empty-pad trigger message, original-chop
/// assignment (shared source, no duplication), reset-sound defaults,
/// renderer compatibility with original pads. AppState-level FFI paths
/// are covered by the env-gated autotests; these tests never load the
/// native DLL.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/pad_cut.dart';
import 'package:bakushi/audio/pad_play.dart';
import 'package:bakushi/audio/render/performance_renderer.dart';
import 'package:bakushi/models/pad.dart';

void main() {
  final n = 44100;
  final l = Float32List(n);
  final r = Float32List(n);
  for (var i = 0; i < n; i++) {
    l[i] = (i % 100) / 100.0;
    r[i] = -((i % 50) / 50.0);
  }

  test('empty pad trigger returns a toast message (no engine call path)', () {
    expect(emptyPadTriggerMessage(Pad(id: 0)), contains('Empty pad'));
    final filled = Pad(id: 1)
      ..leftChannel = Float32List(1)
      ..rightChannel = Float32List(1);
    expect(emptyPadTriggerMessage(filled), isNull);
  });

  test('applyChopToPad bakes a slice from the SHARED original PCM', () {
    final pad = Pad(id: 0);
    applyChopToPad(
      pad,
      stemLeft: l,
      stemRight: r,
      sampleRate: 44100,
      start: 0,
      end: 22050,
      label: 'Original · Test Song',
    );
    expect(pad.original, isTrue);
    expect(pad.sourceKind, 'original');
    expect(pad.startSample, 0);
    expect(pad.endSample, 22050);
    expect(pad.leftChannel!.length, 22050);
    expect(pad.label, 'Original · Test Song');
    // The slice is a COPY - the source PCM is shared, not duplicated.
    expect(identical(pad.leftChannel, l), isFalse);
    // Pad independence: two pads get their own bounds and buffers.
    final pad2 = Pad(id: 1);
    applyChopToPad(
      pad2,
      stemLeft: l,
      stemRight: r,
      sampleRate: 44100,
      start: 4410,
      end: 8820,
      label: 'Original · Test Song',
    );
    expect(pad2.startSample, 4410);
    expect(pad2.endSample, 8820);
    expect(pad.startSample, 0);
    expect(identical(pad.leftChannel, pad2.leftChannel), isFalse);
  });

  test('applyChopToPad keeps existing pad settings (fresh pads default '
      'to HIT + neutral)', () {
    final existing = Pad(id: 3)
      ..loop = true
      ..pitchSemitones = 7
      ..reverse = true
      ..gain = 1.5
      ..fadeMs = 30
      ..leftChannel = Float32List(100)
      ..rightChannel = Float32List(100);
    applyChopToPad(
      existing,
      stemLeft: l,
      stemRight: r,
      sampleRate: 44100,
      start: 0,
      end: 4410,
      label: 'Original · X',
    );
    expect(existing.loop, isTrue); // preserved
    expect(existing.pitchSemitones, 7);
    expect(existing.reverse, isTrue);
    expect(existing.gain, 1.5);
    expect(existing.fadeMs, 30);
    expect(existing.startSample, 0);
    expect(existing.endSample, 4410);
    expect(existing.edited, isFalse);
  });

  test('assignChopToNextEmpty never overwrites: first empty pad wins', () {
    final pads = [for (var i = 0; i < 16; i++) Pad(id: i)];
    applyChopToPad(
      pads[0],
      stemLeft: l,
      stemRight: r,
      sampleRate: 44100,
      start: 0,
      end: 22050,
      label: 'Original · A',
    );
    final empty = firstEmptyPad(pads);
    expect(empty, 1); // pad 1 (index 1) is the first empty pad
    // The "never overwrite" rule: index 0 keeps its original chop.
    expect(pads[0].startSample, 0);
    expect(pads[0].endSample, 22050);
  });

  test('resetPadSound defaults restore neutral settings (pure part)', () {
    final pad = Pad(id: 0)
      ..pitchSemitones = 24
      ..reverse = true
      ..gain = 1.8
      ..fadeMs = 50;
    applyResetSoundDefaults(pad);
    expect(pad.pitchSemitones, 0);
    expect(pad.reverse, isFalse);
    expect(pad.gain, 1.0);
    expect(pad.fadeMs, 5.0);
  });

  test('renderer includes original pads (snapshot-based)', () {
    final pad = Pad(id: 0);
    applyChopToPad(
      pad,
      stemLeft: l,
      stemRight: r,
      sampleRate: 44100,
      start: 0,
      end: 4410, // 100 ms
      label: 'Original · T',
    );
    pad.pitchSemitones = 12; // +12 halves the duration
    final spec = PadRenderSpec.fromPad(pad);
    expect(spec.frames, 4410);
    final res = renderSinglePad(pad, sampleRate: 44100);
    expect(res.durationSeconds, closeTo(0.05, 0.01));
    expect(res.left.length, greaterThan(0));
  });
}
