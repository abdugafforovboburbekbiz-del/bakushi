/// Transport engine facade over the native miniaudio mixer.
///
/// Stems + original form the "transport": play/pause/seek with a
/// frame-accurate playhead polled from the native engine. The C engine's
/// pad voices (0..15) are unused by this UI.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../config.dart';
import 'native_engine.dart';

class TransportEngine extends ChangeNotifier {
  TransportEngine._() {
    _native = NativeEngine.instance;
  }

  static TransportEngine? _instance;
  static TransportEngine get instance => _instance ??= TransportEngine._();

  late final NativeEngine _native;
  bool _initialized = false;
  Timer? _pollTimer;

  bool _transportPlaying = false;
  double _transportPositionSec = 0;
  double _transportDurationSec = 0;
  int _pollTicks = 0;
  final Set<String> _loadedStems = {};
  final Map<String, ({Float32List left, Float32List right})> _stemBuffers = {};
  final Set<String> _stemsInEngine = {};
  bool _originalLoaded = false;

  bool get initialized => _initialized;
  bool get transportPlaying => _transportPlaying;
  double get transportPositionSec => _transportPositionSec;
  double get transportDurationSec => _transportDurationSec;

  /// Whether the original song is loaded into the native engine.
  bool get originalLoaded => _originalLoaded;

  /// Frames position for the shared waveform playhead.
  int get transportFrame =>
      (_transportPositionSec * AppConfig.engineSampleRate).round();

  void init() {
    if (_initialized) return;
    _native.init();
    _initialized = true;
  }

  void disposeEngine() {
    _pollTimer?.cancel();
    if (_initialized) {
      _native.shutdown();
      _initialized = false;
    }
  }

  // -------------------------------------------------------------------------
  // Buffers
  // -------------------------------------------------------------------------

  /// Register a stem's PCM. The native copy is deferred until the first
  /// transport play (avoids big native allocations during separation and
  /// keeps memory pressure for the inference process).
  void loadStem(String name, Float32List left, Float32List right) {
    _stemBuffers[name] = (left: left, right: right);
    _loadedStems.add(name);
  }

  void unloadStem(String name) {
    if (_stemsInEngine.remove(name)) {
      _native.unloadBuffer(_stemVoiceId(name));
    }
    _stemBuffers.remove(name);
    _loadedStems.remove(name);
  }

  void _ensureStemsInEngine() {
    for (final name in _loadedStems) {
      if (_stemsInEngine.contains(name)) continue;
      final b = _stemBuffers[name];
      if (b == null) continue;
      _native.loadBuffer(_stemVoiceId(name), b.left, b.right);
      _stemsInEngine.add(name);
    }
  }

  void loadOriginal(Float32List left, Float32List right) {
    _native.loadBuffer(AppConfig.originalVoiceId, left, right);
    _originalLoaded = true;
  }

  static int _stemVoiceId(String name) {
    switch (name) {
      case 'vocals':
        return AppConfig.stemVoiceIdVocals;
      case 'drums':
        return AppConfig.stemVoiceIdDrums;
      case 'bass':
        return AppConfig.stemVoiceIdBass;
      case 'other':
        return AppConfig.stemVoiceIdOther;
      case 'guitar':
        return AppConfig.stemVoiceIdGuitar;
      case 'piano':
        return AppConfig.stemVoiceIdPiano;
      default:
        throw ArgumentError('unknown stem: $name');
    }
  }

  // -------------------------------------------------------------------------
  // Pads (16-pad auto-cut sampler)
  // -------------------------------------------------------------------------

  /// Load a pad segment's PCM into the engine under its voice id.
  void loadPad(int padIndex, Float32List left, Float32List right) {
    if (!_initialized) return;
    _native.loadBuffer(AppConfig.padVoiceIdBase + padIndex, left, right);
  }

  /// Start a pad voice: one-shot or loop. The C engine re-arms the
  /// fade-in on loop wrap, so beat-locked loops are seamless.
  /// [pitch] is the playback rate (2^(semitones/12)); [reverse] plays
  /// the buffer backwards. Gain is baked into the buffer in Dart.
  void playPad(
    int padIndex, {
    required bool loop,
    double pitch = 1.0,
    bool reverse = false,
  }) {
    if (!_initialized) return;
    _native.play(
      AppConfig.padVoiceIdBase + padIndex,
      gain: 1.0,
      pitch: pitch,
      reverse: reverse,
      loop: loop,
      chokeGroup: '',
      fadeFrames: AppConfig.padFadeFrames,
    );
  }

  void stopPad(int padIndex) {
    if (!_initialized) return;
    _native.stop(AppConfig.padVoiceIdBase + padIndex);
  }

  void stopAllPads() {
    if (!_initialized) return;
    for (var i = 0; i < 16; i++) {
      _native.stop(AppConfig.padVoiceIdBase + i);
    }
  }

  bool isPadPlaying(int padIndex) =>
      _native.isPlaying(AppConfig.padVoiceIdBase + padIndex);

  // -------------------------------------------------------------------------
  // Generic voice playback (rendered performances + chop previews, voice
  // id AppConfig.recordingPreviewVoiceId = 210 - free and < BA_MAX_BUFFERS).
  // -------------------------------------------------------------------------

  /// Load rendered PCM under [voiceId].
  void loadVoice(int voiceId, Float32List left, Float32List right) {
    if (!_initialized) return;
    _native.loadBuffer(voiceId, left, right);
  }

  /// Playback of [voiceId]. [loop] makes the C engine wrap seamlessly
  /// (used by the sequencer loop voice).
  void playVoice(int voiceId, {double pitch = 1.0, bool loop = false}) {
    if (!_initialized) return;
    _native.play(
      voiceId,
      gain: 1.0,
      pitch: pitch,
      reverse: false,
      loop: loop,
      chokeGroup: '',
      fadeFrames: AppConfig.transportFadeFrames,
    );
  }

  void stopVoice(int voiceId) {
    if (!_initialized) return;
    _native.stop(voiceId);
  }

  bool isVoicePlaying(int voiceId) => _native.isPlaying(voiceId);

  // -------------------------------------------------------------------------
  // Transport (original + stems together)
  // -------------------------------------------------------------------------

  void startTransport({
    double startSec = 0,
    double durationSec = 0,
    Map<String, double> stemGains = const {},
  }) {
    if (!_initialized) return;
    final startFrame = (startSec * AppConfig.engineSampleRate).round();
    _transportDurationSec = durationSec;
    _ensureStemsInEngine();
    for (final name in _loadedStems) {
      _native.playAt(
        _stemVoiceId(name),
        startFrame,
        gain: stemGains[name] ?? 1.0,
        pitch: 1.0,
        reverse: false,
        loop: false,
        chokeGroup: '',
        fadeFrames: AppConfig.transportFadeFrames,
      );
    }
    if (_originalLoaded) {
      _native.playAt(
        AppConfig.originalVoiceId,
        startFrame,
        gain: stemGains['original'] ?? 1.0,
        pitch: 1.0,
        reverse: false,
        loop: false,
        chokeGroup: '',
        fadeFrames: AppConfig.transportFadeFrames,
      );
    }
    _transportPlaying = true;
    _transportPositionSec = startSec;
    _startPolling();
    notifyListeners();
  }

  void pauseTransport() {
    if (!_initialized) return;
    for (final name in _loadedStems) {
      _native.stop(_stemVoiceId(name));
    }
    if (_originalLoaded) _native.stop(AppConfig.originalVoiceId);
    _transportPlaying = false;
    _stopPolling();
    notifyListeners();
  }

  void stopTransport() {
    pauseTransport();
    _transportPositionSec = 0;
    notifyListeners();
  }

  void seekTransport(double sec) {
    _transportPositionSec = sec;
    if (_transportPlaying) {
      _ensureStemsInEngine();
      final startFrame = (sec * AppConfig.engineSampleRate).round();
      for (final name in _loadedStems) {
        _native.playAt(
          _stemVoiceId(name),
          startFrame,
          gain: 1.0,
          pitch: 1.0,
          reverse: false,
          loop: false,
          chokeGroup: '',
          fadeFrames: AppConfig.transportFadeFrames,
        );
      }
      if (_originalLoaded) {
        _native.playAt(
          AppConfig.originalVoiceId,
          startFrame,
          gain: 1.0,
          pitch: 1.0,
          reverse: false,
          loop: false,
          chokeGroup: '',
          fadeFrames: AppConfig.transportFadeFrames,
        );
      }
    }
    notifyListeners();
  }

  /// Live stem gain (mixer volume/mute/solo).
  void setStemGain(String name, double gain) {
    if (!_initialized) return;
    _native.setVoiceGain(_stemVoiceId(name), gain);
  }

  void setMasterGain(double gain) {
    if (!_initialized) return;
    _native.setMasterGain(gain);
  }

  /// Phase E: global master FX (low-pass + feedback echo, post-mix).
  /// cutoff_hz <= 0 = filter off; echo_ms <= 0 or wet <= 0 = echo off.
  /// All zero = exact passthrough.
  void setFx(double cutoffHz, double echoMs, double wet) {
    if (!_initialized) return;
    _native.setFx(cutoffHz, echoMs, wet);
  }

  // -------------------------------------------------------------------------

  void _startPolling() {
    _pollTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      int pollId;
      if (_loadedStems.contains('vocals')) {
        pollId = AppConfig.stemVoiceIdVocals;
      } else if (_loadedStems.isNotEmpty) {
        pollId = _stemVoiceId(_loadedStems.first);
      } else {
        pollId = AppConfig.originalVoiceId;
      }
      final pos = _native.getPosition(pollId);
      _pollTicks++;
      if (_pollTicks % 30 == 0) {
        debugPrint('[BAKUSHI] poll id=$pollId pos=$pos');
      }
      if (pos >= 0) {
        final sec = pos / AppConfig.engineSampleRate;
        if (sec != _transportPositionSec) {
          _transportPositionSec = sec;
          notifyListeners();
        }
        if (_transportDurationSec > 0 && sec >= _transportDurationSec - 0.01) {
          pauseTransport();
          notifyListeners();
        }
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}
