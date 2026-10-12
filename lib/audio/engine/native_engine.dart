/// dart:ffi bindings for the native miniaudio engine (bakushi_engine.dll).
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef _BaInitNative = ffi.Int32 Function();
typedef _BaInitDart = int Function();

typedef _BaShutdownNative = ffi.Void Function();
typedef _BaShutdownDart = void Function();

typedef _BaLoadBufferNative = ffi.Int32 Function(
  ffi.Int32,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  ffi.Uint64,
);
typedef _BaLoadBufferDart = int Function(
  int,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  int,
);

typedef _BaUnloadBufferNative = ffi.Void Function(ffi.Int32);
typedef _BaUnloadBufferDart = void Function(int);

typedef _BaPlayNative = ffi.Int32 Function(
  ffi.Int32,
  ffi.Double,
  ffi.Double,
  ffi.Int32,
  ffi.Int32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef _BaPlayDart = int Function(
  int,
  double,
  double,
  int,
  int,
  ffi.Pointer<Utf8>,
  int,
);

typedef _BaPlayAtNative = ffi.Int32 Function(
  ffi.Int32,
  ffi.Uint64,
  ffi.Double,
  ffi.Double,
  ffi.Int32,
  ffi.Int32,
  ffi.Pointer<Utf8>,
  ffi.Uint32,
);
typedef _BaPlayAtDart = int Function(
  int,
  int,
  double,
  double,
  int,
  int,
  ffi.Pointer<Utf8>,
  int,
);

typedef _BaStopNative = ffi.Void Function(ffi.Int32);
typedef _BaStopDart = void Function(int);

typedef _BaStopGroupNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _BaStopGroupDart = void Function(ffi.Pointer<Utf8>);

typedef _BaStopAllNative = ffi.Void Function();
typedef _BaStopAllDart = void Function();

typedef _BaSetVoiceGainNative = ffi.Void Function(ffi.Int32, ffi.Double);
typedef _BaSetVoiceGainDart = void Function(int, double);

typedef _BaSetMasterGainNative = ffi.Void Function(ffi.Double);
typedef _BaSetMasterGainDart = void Function(double);

typedef _BaSetFxNative = ffi.Void Function(
  ffi.Double,
  ffi.Double,
  ffi.Double,
);
typedef _BaSetFxDart = void Function(double, double, double);

typedef _BaGetPositionNative = ffi.Int64 Function(ffi.Int32);
typedef _BaGetPositionDart = int Function(int);

typedef _BaIsPlayingNative = ffi.Int32 Function(ffi.Int32);
typedef _BaIsPlayingDart = int Function(int);

typedef _BaDeviceSampleRateNative = ffi.Int32 Function();
typedef _BaDeviceSampleRateDart = int Function();

/// Thrown when the native engine cannot be initialized.
class EngineException implements Exception {
  final String message;
  final String hint;
  const EngineException(this.message, this.hint);

  @override
  String toString() => message;
}

class NativeEngine {
  NativeEngine._() {
    final libPath = _resolveDllPath();
    if (libPath == null) {
      throw EngineException(
        'Native audio engine not found (bakushi_engine.dll).',
        'Rebuild the Windows runner so CMake produces and copies the DLL.',
      );
    }
    _lib = ffi.DynamicLibrary.open(libPath);

    _init = _lib.lookupFunction<_BaInitNative, _BaInitDart>('ba_init');
    _shutdown = _lib.lookupFunction<_BaShutdownNative, _BaShutdownDart>(
      'ba_shutdown',
    );
    _loadBuffer = _lib.lookupFunction<_BaLoadBufferNative, _BaLoadBufferDart>(
      'ba_load_buffer',
    );
    _unloadBuffer = _lib
        .lookupFunction<_BaUnloadBufferNative, _BaUnloadBufferDart>(
          'ba_unload_buffer',
        );
    _play = _lib.lookupFunction<_BaPlayNative, _BaPlayDart>('ba_play');
    _playAt = _lib.lookupFunction<_BaPlayAtNative, _BaPlayAtDart>('ba_play_at');
    _stop = _lib.lookupFunction<_BaStopNative, _BaStopDart>('ba_stop');
    _stopGroup = _lib.lookupFunction<_BaStopGroupNative, _BaStopGroupDart>(
      'ba_stop_group',
    );
    _stopAll = _lib.lookupFunction<_BaStopAllNative, _BaStopAllDart>(
      'ba_stop_all',
    );
    _setVoiceGain = _lib
        .lookupFunction<_BaSetVoiceGainNative, _BaSetVoiceGainDart>(
          'ba_set_voice_gain',
        );
    _setMasterGain = _lib
        .lookupFunction<_BaSetMasterGainNative, _BaSetMasterGainDart>(
          'ba_set_master_gain',
        );
    _setFx = _lib.lookupFunction<_BaSetFxNative, _BaSetFxDart>('ba_set_fx');
    _getPosition = _lib
        .lookupFunction<_BaGetPositionNative, _BaGetPositionDart>(
          'ba_get_position',
        );
    _isPlaying = _lib.lookupFunction<_BaIsPlayingNative, _BaIsPlayingDart>(
      'ba_is_playing',
    );
    _deviceSampleRate = _lib
        .lookupFunction<_BaDeviceSampleRateNative, _BaDeviceSampleRateDart>(
          'ba_device_sample_rate',
        );
  }

  static NativeEngine? _instance;
  static NativeEngine get instance => _instance ??= NativeEngine._();

  static String? _resolveDllPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir\\bakushi_engine.dll',
      '$exeDir\\..\\..\\..\\..\\build\\windows\\x64\\runner\\Debug\\bakushi_engine.dll',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  late final ffi.DynamicLibrary _lib;

  late final _BaInitDart _init;
  late final _BaShutdownDart _shutdown;
  late final _BaLoadBufferDart _loadBuffer;
  late final _BaUnloadBufferDart _unloadBuffer;
  late final _BaPlayDart _play;
  late final _BaPlayAtDart _playAt;
  late final _BaStopDart _stop;
  late final _BaStopGroupDart _stopGroup;
  late final _BaStopAllDart _stopAll;
  late final _BaSetVoiceGainDart _setVoiceGain;
  late final _BaSetMasterGainDart _setMasterGain;
  late final _BaSetFxDart _setFx;
  late final _BaGetPositionDart _getPosition;
  late final _BaIsPlayingDart _isPlaying;
  late final _BaDeviceSampleRateDart _deviceSampleRate;

  /// Initialize the device. Throws [EngineException] on failure.
  void init() {
    final rc = _init();
    if (rc != 0) {
      throw EngineException(
        'Audio device failed to initialize (error $rc).',
        'Check that the default Windows audio output device is available.',
      );
    }
  }

  void shutdown() => _shutdown();

  int deviceSampleRate() => _deviceSampleRate();

  /// Copy a stereo buffer into the engine under [id].
  void loadBuffer(int id, Float32List left, Float32List right) {
    final l = _toNative(left);
    final r = _toNative(right);
    try {
      final rc = _loadBuffer(id, l, r, left.length);
      if (rc != 0) {
        debugPrint(
          '[BAKUSHI] loadBuffer(id=$id, frames=${left.length}) rc=$rc',
        );
        throw EngineException(
          'Failed to load audio buffer into the engine (error $rc).',
          'Free memory and try again.',
        );
      }
    } finally {
      calloc.free(l);
      calloc.free(r);
    }
  }

  void unloadBuffer(int id) => _unloadBuffer(id);

  int play(
    int id, {
    required double gain,
    required double pitch,
    required bool reverse,
    required bool loop,
    required String chokeGroup,
    required int fadeFrames,
  }) {
    final choke = chokeGroup.toNativeUtf8();
    try {
      return _play(
        id,
        gain,
        pitch,
        reverse ? 1 : 0,
        loop ? 1 : 0,
        choke,
        fadeFrames,
      );
    } finally {
      calloc.free(choke);
    }
  }

  int playAt(
    int id,
    int startFrame, {
    required double gain,
    required double pitch,
    required bool reverse,
    required bool loop,
    required String chokeGroup,
    required int fadeFrames,
  }) {
    final choke = chokeGroup.toNativeUtf8();
    try {
      final rc = _playAt(
        id,
        startFrame,
        gain,
        pitch,
        reverse ? 1 : 0,
        loop ? 1 : 0,
        choke,
        fadeFrames,
      );
      if (rc != 0) {
        debugPrint('[BAKUSHI] playAt(id=$id, start=$startFrame) rc=$rc');
      }
      return rc;
    } finally {
      calloc.free(choke);
    }
  }

  void stop(int id) => _stop(id);

  void stopGroup(String chokeGroup) {
    final choke = chokeGroup.toNativeUtf8();
    try {
      _stopGroup(choke);
    } finally {
      calloc.free(choke);
    }
  }

  void stopAll() => _stopAll();

  void setVoiceGain(int id, double gain) => _setVoiceGain(id, gain);

  void setMasterGain(double gain) => _setMasterGain(gain);

  /// Phase E: global master FX. cutoff_hz <= 0 = filter off; echo_ms <= 0
  /// or wet <= 0 = echo off. All zero = exact passthrough.
  void setFx(double cutoffHz, double echoMs, double wet) =>
      _setFx(cutoffHz, echoMs, wet);

  int getPosition(int id) => _getPosition(id);

  bool isPlaying(int id) => _isPlaying(id) != 0;

  /// Trim this process's working set: pages unused memory out so the OS
  /// stops swapping after heavy separation/save runs.
  static void trimWorkingSet() {
    try {
      final k32 = ffi.DynamicLibrary.open('kernel32.dll');
      final getProc = k32.lookupFunction<ffi.IntPtr Function(), int Function()>(
        'GetCurrentProcess',
      );
      final setWs = k32
          .lookupFunction<
            ffi.Int32 Function(ffi.IntPtr, ffi.Uint64, ffi.Uint64),
            int Function(int, int, int)
          >('SetProcessWorkingSetSize');
      setWs(getProc(), -1, -1);
    } catch (_) {
      // Best effort only.
    }
  }

  static ffi.Pointer<ffi.Float> _toNative(Float32List list) {
    final ptr = calloc<ffi.Float>(list.length);
    ptr.asTypedList(list.length).setAll(0, list);
    return ptr;
  }
}
