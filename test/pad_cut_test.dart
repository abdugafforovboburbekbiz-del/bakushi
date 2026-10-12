// Auto-cut math + live pad-bounds editing (Tasks 2-3).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/pad_cut.dart';
import 'package:bakushi/config.dart';
import 'package:bakushi/models/pad.dart';

void main() {
  const sr = 44100;
  const bpm = 100.0; // beat = 0.6 s = 26460 samples; bar = 105840

  test('1 Beat division cuts 1-beat segments on exact beat lines', () {
    final segs = computePadSegments(
      bpm: bpm,
      sampleRate: sr,
      totalFrames: 20 * 26460,
      division: Division.beat,
    );
    expect(segs.length, 16); // capped at 16 pads
    for (var i = 0; i < segs.length; i++) {
      expect(segs[i].startSample, i * 26460);
      expect(segs[i].length, 26460);
    }
  });

  test('1 Bar division cuts 1-bar segments on exact bar lines', () {
    final segs = computePadSegments(
      bpm: bpm,
      sampleRate: sr,
      totalFrames: 6 * 105840,
      division: Division.bar,
    );
    expect(segs.length, 6);
    for (var i = 0; i < segs.length; i++) {
      expect(segs[i].startSample, i * 105840);
      expect(segs[i].length, 105840);
    }
  });

  test('2 Bars division cuts 2-bar segments on exact bar lines', () {
    final segs = computePadSegments(
      bpm: bpm,
      sampleRate: sr,
      totalFrames: 4 * 211680,
      division: Division.twoBars,
    );
    expect(segs.length, 4);
    for (var i = 0; i < segs.length; i++) {
      expect(segs[i].startSample, i * 211680);
      expect(segs[i].length, 211680);
    }
  });

  test('last segment is clamped to the song end', () {
    final segs = computePadSegments(
      bpm: bpm,
      sampleRate: sr,
      totalFrames: (3 * 26460) + 1000,
      division: Division.beat,
    );
    expect(segs.length, 4);
    expect(segs.last.startSample, 3 * 26460);
    expect(segs.last.endSample, (3 * 26460) + 1000);
  });

  test('short songs yield fewer than 16 segments', () {
    final segs = computePadSegments(
      bpm: bpm,
      sampleRate: sr,
      totalFrames: 3 * 26460,
      division: Division.beat,
    );
    expect(segs.length, 3);
  });

  test('division defaults: 1 Beat -> HIT, bars -> LOOP', () {
    expect(Division.beat.defaultLoop, isFalse);
    expect(Division.bar.defaultLoop, isTrue);
    expect(Division.twoBars.defaultLoop, isTrue);
  });

  test('proportionalPadShares splits 16 pads across stems', () {
    expect(proportionalPadShares(1), [16]);
    expect(proportionalPadShares(2), [8, 8]);
    expect(proportionalPadShares(3), [6, 5, 5]);
    expect(proportionalPadShares(4), [4, 4, 4, 4]);
    expect(proportionalPadShares(5), [4, 3, 3, 3, 3]);
    expect(proportionalPadShares(6), [3, 3, 3, 3, 2, 2]);
    for (var n = 1; n <= 6; n++) {
      final shares = proportionalPadShares(n);
      expect(shares.length, n);
      expect(shares.fold(0, (a, b) => a + b), 16);
    }
  });

  test('segmentRms ranks loud regions above quiet ones', () {
    final left = Float32List(100);
    final right = Float32List(100);
    for (var i = 0; i < 100; i++) {
      left[i] = 0.01;
      right[i] = 0.01;
    }
    for (var i = 40; i < 60; i++) {
      left[i] = 0.5;
      right[i] = 0.5;
    }
    final quiet = segmentRms(left, right, 0, 30);
    final loud = segmentRms(left, right, 40, 60);
    expect(quiet, lessThan(0.02));
    expect(loud, greaterThan(0.4));
    expect(segmentRms(left, right, 50, 50), 0.0); // empty region
  });

  test('applyPadBounds shrinks a pad live and re-bakes buffers (Task 3)', () {
    final stem = Float32List(200000); // long enough for a 1-bar segment
    for (var i = 0; i < stem.length; i++) {
      stem[i] = (i % 11 == 0) ? 0.8 : 0.05;
    }
    final pad = Pad(id: 0)
      ..stemName = 'drums'
      ..loop = true
      ..sampleRate = 44100;
    // Fill as a 1-bar segment.
    applyPadBounds(
      pad,
      stemLeft: stem,
      stemRight: stem,
      sampleRate: 44100,
      startSample: 0,
      endSample: 105840,
    );
    expect(pad.startSample, 0);
    expect(pad.endSample, 105840);
    expect(pad.leftChannel!.length, 105840);

    // Drag the end handle shorter: 105840 -> 50000 samples.
    applyPadBounds(
      pad,
      stemLeft: stem,
      stemRight: stem,
      sampleRate: 44100,
      startSample: 0,
      endSample: 50000,
    );
    expect(pad.startSample, 0);
    expect(pad.endSample, 50000);
    expect(pad.leftChannel!.length, 50000);
    expect(pad.leftChannel![0], closeTo(0.0, 1e-6)); // fade-in start
    expect(pad.leftChannel![49999], closeTo(0.0, 1e-6)); // fade-out end

    // Drag the start handle later: 0 -> 10000.
    applyPadBounds(
      pad,
      stemLeft: stem,
      stemRight: stem,
      sampleRate: 44100,
      startSample: 10000,
      endSample: 50000,
    );
    expect(pad.startSample, 10000);
    expect(pad.endSample, 50000);
    expect(pad.leftChannel!.length, 40000);

    // Bounds clamp at the stem edges.
    applyPadBounds(
      pad,
      stemLeft: stem,
      stemRight: stem,
      sampleRate: 44100,
      startSample: -500,
      endSample: 999999,
    );
    expect(pad.startSample, 0);
    expect(pad.endSample, 200000);
  });

  test('applyPadBounds bakes gain with a hard clamp (Phase C)', () {
    final stem = Float32List(10000);
    for (var i = 0; i < stem.length; i++) {
      stem[i] = 0.8;
    }
    final pad = Pad(id: 1)
      ..stemName = 'drums'
      ..sampleRate = 44100;
    applyPadBounds(
      pad,
      stemLeft: stem,
      stemRight: stem,
      sampleRate: 44100,
      startSample: 0,
      endSample: 8000,
      fadeSamples: 0,
      gain: 2.0,
    );
    expect(pad.gain, 1.0); // gain lives on the Pad, not inside apply
    expect(pad.leftChannel![100], closeTo(1.0, 1e-6)); // 0.8*2 clamped
    expect(pad.rightChannel![100], closeTo(1.0, 1e-6));
    // Neutral gain leaves the samples untouched.
    applyPadBounds(
      pad,
      stemLeft: stem,
      stemRight: stem,
      sampleRate: 44100,
      startSample: 0,
      endSample: 8000,
      fadeSamples: 0,
      gain: 1.0,
    );
    expect(pad.leftChannel![100], closeTo(0.8, 1e-6));
  });
}
