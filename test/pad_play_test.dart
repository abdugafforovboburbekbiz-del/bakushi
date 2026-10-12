/// Phase C pure playback logic: pitch rate, gain clamp, slice clamps,
/// preview-never-loops + Sampler Polish helpers.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bakushi/audio/pad_play.dart';
import 'package:bakushi/models/pad.dart';

void main() {
  group('pitch -> playback rate', () {
    test('rate formula at -12, 0 and +12 semitones', () {
      expect(padPlayRate(-12), closeTo(0.5, 1e-9)); // one octave down
      expect(padPlayRate(0), closeTo(1.0, 1e-9));
      expect(padPlayRate(12), closeTo(2.0, 1e-9)); // one octave up
      expect(padPlayRate(5), closeTo(1.334839854, 1e-6));
    });

    test('rate formula at the new -24..+24 range edges', () {
      expect(padPlayRate(-24), closeTo(0.25, 1e-9)); // two octaves down
      expect(padPlayRate(24), closeTo(4.0, 1e-9)); // two octaves up
    });

    test('clampPadPitch keeps values inside -24..+24', () {
      expect(clampPadPitch(0), 0);
      expect(clampPadPitch(5), 5);
      expect(clampPadPitch(-24), -24);
      expect(clampPadPitch(24), 24);
      expect(clampPadPitch(48), 24);
      expect(clampPadPitch(-40), -24);
    });

    test('Pad.playRate matches the formula', () {
      final pad = Pad(id: 0)..pitchSemitones = 5;
      expect(pad.playRate, closeTo(padPlayRate(5), 1e-12));
      pad.pitchSemitones = -12;
      expect(pad.playRate, closeTo(0.5, 1e-9));
    });
  });

  group('gain', () {
    test('clampPadGain keeps values inside 0..2 (0%..200%)', () {
      expect(clampPadGain(0.0), 0.0);
      expect(clampPadGain(1.0), 1.0);
      expect(clampPadGain(2.0), 2.0);
      expect(clampPadGain(-0.5), 0.0);
      expect(clampPadGain(3.0), 2.0);
    });
  });

  group('Sampler Polish helpers', () {
    test('clampPadFadeMs keeps values inside 0..50 ms', () {
      expect(clampPadFadeMs(0), 0);
      expect(clampPadFadeMs(5), 5);
      expect(clampPadFadeMs(50), 50);
      expect(clampPadFadeMs(-3), 0);
      expect(clampPadFadeMs(80), 50);
    });

    test('padFadeSamples converts ms to samples at the sample rate', () {
      expect(padFadeSamples(0, 44100), 0);
      expect(padFadeSamples(5, 44100), 221); // 0.005 * 44100 = 220.5
      expect(padFadeSamples(50, 44100), 2205);
    });

    test('firstEmptyPad finds the first empty index, null when full', () {
      final pads = [for (var i = 0; i < 16; i++) Pad(id: i)];
      expect(firstEmptyPad(pads), 0);
      pads[0].leftChannel = Float32List(1);
      pads[0].rightChannel = Float32List(1);
      pads[1].leftChannel = Float32List(1);
      pads[1].rightChannel = Float32List(1);
      expect(firstEmptyPad(pads), 2);
      for (final p in pads) {
        p.leftChannel = Float32List(1);
        p.rightChannel = Float32List(1);
      }
      expect(firstEmptyPad(pads), isNull);
    });

    test('applyResetSoundDefaults restores neutral settings', () {
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

    test('Pad.customLabel carries the file name', () {
      expect(Pad.customLabel(r'C:\songs\my loop.wav'), 'Custom · my loop.wav');
      expect(Pad.customLabel('kick.mp3'), 'Custom · kick.mp3');
    });

    test('Pad.sourceKind covers original chops', () {
      final pad = Pad(id: 0);
      expect(pad.sourceKind, 'empty');
      pad
        ..original = true
        ..leftChannel = Float32List(1)
        ..rightChannel = Float32List(1);
      expect(pad.sourceKind, 'original');
    });

    test('Pad.clear resets fadeMs and original', () {
      final pad = Pad(id: 0)
        ..original = true
        ..fadeMs = 50
        ..leftChannel = Float32List(1)
        ..rightChannel = Float32List(1);
      pad.clear();
      expect(pad.original, isFalse);
      expect(pad.fadeMs, 5.0);
      expect(pad.isEmpty, isTrue);
    });
  });

  group('slice bounds', () {
    test('min 20 ms slice length is enforced', () {
      const sr = 44100;
      final minLen = minSliceSamples(sr);
      expect(minLen, 882); // 20 ms at 44.1 kHz
      final r = clampSliceBounds(1000, 1001, minLen, sr * 10);
      expect(r.end - r.start, minLen);
    });

    test('start line clamp preserves minimum length and stays in bounds', () {
      const sr = 44100;
      final minLen = minSliceSamples(sr);
      // Start pushed past (end - minLen) clamps there.
      final a = clampSliceBounds(5000, 2000, minLen, 4000);
      expect(a.end - a.start, greaterThanOrEqualTo(minLen));
      expect(a.start, greaterThanOrEqualTo(0));
      expect(a.end, lessThanOrEqualTo(4000));
      // End past the source clamps to the source end.
      final b = clampSliceBounds(0, 999999, minLen, 4000);
      expect(b.end, 4000);
      expect(b.start, greaterThanOrEqualTo(0));
    });

    test('moving a selection preserves its duration', () {
      const frames = 200000;
      final moved = moveSlice(10000, 30000, 25000, frames);
      expect(moved.end - moved.start, 20000); // duration preserved
      expect(moved.start, 35000);
      // Clamped at the source end.
      final clamped = moveSlice(10000, 30000, 190000, frames);
      expect(clamped.end, frames);
      expect(clamped.end - clamped.start, 20000);
      // Clamped at zero.
      final zero = moveSlice(10000, 30000, -50000, frames);
      expect(zero.start, 0);
      expect(zero.end - zero.start, 20000);
    });
  });

  group('PadPlaySpec', () {
    Pad filledPad() {
      final pad = Pad(id: 0)
        ..stemName = 'drums'
        ..loop = true
        ..pitchSemitones = 5
        ..reverse = true
        ..gain = 1.5;
      return pad;
    }

    test('trigger spec carries pitch, reverse and loop', () {
      final spec = PadPlaySpec.fromPad(filledPad());
      expect(spec.pitch, closeTo(padPlayRate(5), 1e-12));
      expect(spec.reverse, isTrue);
      expect(spec.loop, isTrue);
    });

    test('preview never loops - not even for a LOOP pad', () {
      final spec = PadPlaySpec.fromPad(filledPad(), preview: true);
      expect(spec.loop, isFalse);
      expect(spec.pitch, closeTo(padPlayRate(5), 1e-12));
      expect(spec.reverse, isTrue);
    });

    test('HIT pad spec plays once', () {
      final pad = filledPad()..loop = false;
      expect(PadPlaySpec.fromPad(pad).loop, isFalse);
    });
  });

  group('PadSnapshot (Phase D one-level undo)', () {
    Pad snapshotPad() {
      final pad = Pad(id: 0)
        ..stemName = 'drums'
        ..startSample = 4000
        ..endSample = 8000
        ..leftChannel = Float32List(4000)
        ..rightChannel = Float32List(4000);
      return pad;
    }

    test('captures every destructive field of a filled pad', () {
      final pad = snapshotPad()
        ..stemName = 'bass'
        ..loop = true
        ..pitchSemitones = 7
        ..reverse = true
        ..gain = 1.5
        ..fadeMs = 20
        ..label = 'bass 2'
        ..edited = true
        ..origStartSample = 100
        ..origEndSample = 900;
      final snap = PadSnapshot.of(pad)!;
      expect(snap.stemName, 'bass');
      expect(snap.startSample, pad.startSample);
      expect(snap.endSample, pad.endSample);
      expect(snap.loop, isTrue);
      expect(snap.pitchSemitones, 7);
      expect(snap.reverse, isTrue);
      expect(snap.gain, 1.5);
      expect(snap.fadeMs, 20);
      expect(snap.label, 'bass 2');
      expect(snap.edited, isTrue);
      expect(snap.origStartSample, 100);
      expect(snap.origEndSample, 900);
    });

    test('captures the source kind (custom / starter / original)', () {
      final custom = snapshotPad()
        ..custom = true
        ..customSourcePath = r'C:\samples\kick.wav'
        ..customBpm = 120;
      expect(PadSnapshot.of(custom)!.custom, isTrue);
      expect(PadSnapshot.of(custom)!.customSourcePath, r'C:\samples\kick.wav');

      final starter = snapshotPad()..starter = true;
      starter.starterName = 'kick';
      expect(PadSnapshot.of(starter)!.starter, isTrue);
      expect(PadSnapshot.of(starter)!.starterName, 'kick');

      final chop = snapshotPad()..original = true;
      expect(PadSnapshot.of(chop)!.original, isTrue);
    });

    test('returns null for an empty pad (nothing to undo to)', () {
      final pad = Pad(id: 0);
      pad.clear();
      expect(PadSnapshot.of(pad), isNull);
    });
  });

  group('countPlayingLoops (Phase E combo sparkle)', () {
    test('counts only LOOP pads that are sounding', () {
      final pads = [for (var i = 0; i < 4; i++) Pad(id: i)];
      pads[0].loop = true;
      pads[1].loop = true;
      pads[2].loop = false; // HIT does not count
      pads[3].loop = true;
      expect(countPlayingLoops(pads, [true, true, true, true]), 3);
      expect(countPlayingLoops(pads, [true, false, true, true]), 2);
      expect(countPlayingLoops(pads, [false, false, false, false]), 0);
    });

    test('an empty pad never counts even when marked loop', () {
      final pads = [for (var i = 0; i < 3; i++) Pad(id: i)];
      pads[0].loop = true;
      expect(countPlayingLoops(pads, [true, true, true]), 1);
    });
  });
}
