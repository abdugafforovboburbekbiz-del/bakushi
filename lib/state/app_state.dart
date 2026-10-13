/// Central application state: pipeline, stems, mixer, diagnostics.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../audio/decoder/decoder_service.dart';
import '../audio/dsp.dart';
import '../audio/engine/native_engine.dart';
import '../audio/engine/transport_engine.dart';
import '../audio/export/export_service.dart';
import '../audio/pad_cut.dart';
import '../audio/pad_play.dart';
import '../audio/pcm_io.dart';
import '../audio/render/performance_renderer.dart';
import '../audio/separation/separation_service.dart';
import '../audio/wav_codec.dart';
import '../config.dart';
import '../models/audio_models.dart';
import '../models/pad.dart';
import '../models/pattern.dart';
import '../sidecar/sidecar_client.dart';
import 'library_store.dart';
import 'model_locator.dart';
import 'starter_kit.dart';
import 'app_settings.dart';

enum PipelineStage { idle, decoding, separating, analyzing, ready, error }

/// Sampler Polish: performance recording state machine.
enum RecState { ready, recording, stopped }

class LogEntry {
  final DateTime time;
  final String message;
  final bool isError;
  const LogEntry(this.time, this.message, this.isError);
}

/// Phase B: a decoded custom sample assigned to a pad.
class _CustomSample {
  final Float32List left;
  final Float32List right;
  final int sampleRate;
  final String sourcePath;
  final double? bpm;
  const _CustomSample({
    required this.left,
    required this.right,
    required this.sampleRate,
    required this.sourcePath,
    this.bpm,
  });
}

class AppState extends ChangeNotifier {
  AppState() {
    decoder = DecoderService(sidecar, workDir);
    separation = SeparationService(sidecar, workDir);
  }

  final TransportEngine engine = TransportEngine.instance;
  final SidecarClient sidecar = SidecarClient();
  final ExportService exporter = const ExportService();

  /// Recent stderr lines from the Python sidecar (capped 300 by the
  /// client) - shown in the diagnostics panel.
  List<String> get sidecarLogLines => sidecar.logLines;

  late final Directory workDir = Directory.systemTemp.createTempSync(
    'bakushi_',
  );

  late final DecoderService decoder;
  late final SeparationService separation;

  // ------------------------------------------------------------------ upload
  String? filePath;
  String? fileName;
  int fileSizeBytes = 0;
  StereoAudio? original;

  // ---------------------------------------------------------------- pipeline
  PipelineStage stage = PipelineStage.idle;
  String stageText = '';
  double progress = 0;
  bool busy = false;
  bool cancelRequested = false;

  String backend = 'not detected';
  String modelStatus = 'not loaded';
  String? resolvedModelPath;
  SeparationMode modelMode = SeparationMode.fourStem;
  bool sixStemAvailable = false;
  String? _qualityModelPath;
  String? _sixStemPath;

  /// Compute device the user picked in Step 2 (forces the backend: the
  /// sidecar does NOT fall back when a forced provider fails).
  SeparationBackend backendChoice = SeparationBackend.cpu;
  SeparationMeta? sepMeta;
  DateTime? _separationStartedAt;
  Timer? _uiHeartbeat;
  Timer? _watchdog;
  DateTime? _lastWatchdogTick;

  // ------------------------------------------------------------------- stems
  Map<String, StemAudio> stems = {};

  /// Stem names of the last separation (4 for the default model, 6 for
  /// the six-stem model) - drives the mixer, waveform rows and exports.
  List<String> activeStemNames = List.of(AppConfig.stemNames);

  final Map<String, double> stemVolumes = {
    for (final n in AppConfig.stemNames) n: 1.0,
  };
  final Set<String> mutedStems = {};
  String? soloStem;
  double masterVolume = 0.9;

  // -------------------------------------------------------------------- pads
  /// 16-pad auto-cut sampler (Phase A): proportional automatic fill.
  final List<Pad> pads = List.generate(16, (i) => Pad(id: i));
  double? detectedBpm;

  /// Phase A (vision): beat/downbeat timestamps in SAMPLES, cached from
  /// the sidecar beat analysis. LOOP pads anchor on the real downbeats;
  /// [detectedOnsets] are the drums one-shots for HIT pads.
  List<int> detectedBeats = [];
  List<int> detectedDownbeats = [];
  List<int> detectedOnsets = [];

  // ------------------------------------------------- step-grid sequencer

  /// The active pattern (default: empty, 100 BPM; adopts the analyzed
  /// tempo when a song's BPM becomes known and no steps are set).
  Pattern _pattern = Pattern(bpm: 100, bars: 2);
  Pattern get activePattern => _pattern;

  bool _patternPlaying = false;
  bool get isPatternPlaying => _patternPlaying;
  Timer? _patternRerender;

  /// Lanes muted in the sequencer (skipped when rendering).
  final Set<int> mutedPatternLanes = {};

  /// Pad currently open in the slice editor (Task 3), null = grid view.
  int? editingPadIndex;

  /// Phase C: pad selected in the grid (settings icon), shown in the pad
  /// inspector below the grid. Null = no selection.
  int? selectedPadIndex;

  /// Pad -> keyboard key. Fixed layout by default (QWER/ASDF/ZXCV/1234);
  /// reassignable per pad, persisted with the library settings.
  Map<int, String> padKeys = {};

  /// Pad currently waiting for the user to press its new key (reassign
  /// mode). The keycap tap starts this; any allowed key finishes it.
  int? assigningKeyPad;

  void _resetPadKeys() {
    padKeys
      ..clear()
      ..addAll({for (var i = 0; i < 16; i++) i: AppConfig.padAutoKeyOrder[i]});
  }

  /// Cached pad playing states, refreshed by [_startPadPlayMonitor].
  final List<bool> _padPlayStates = List<bool>.filled(16, false);
  Timer? _padPlayTimer;

  /// Phase B: custom uploaded samples, one per pad (index -> source).
  final Map<int, _CustomSample> _customSamples = {};

  // ---------------------------------------------------- Phase E: master FX

  /// Fixed echo time (a musical dotted-eighth feel).
  static const double fxEchoMs = 300.0;

  /// Global low-pass cutoff in Hz (0 = off, knob range 200..8000).
  double fxFilterHz = 0;

  /// Echo wet amount 0..0.5 (0 = off).
  double fxEchoWet = 0;

  void setFxFilter(double hz) {
    fxFilterHz = hz <= 0 ? 0 : hz;
    _applyFx();
    _action(
      'fx.filter',
      detail: fxFilterHz > 0 ? 'cutoff ${fxFilterHz.round()} Hz' : 'off',
    );
    notifyListeners();
  }

  void setFxEcho(double wet) {
    fxEchoWet = wet <= 0 ? 0 : wet;
    _applyFx();
    _action(
      'fx.echo',
      detail: fxEchoWet > 0
          ? '${fxEchoWet.toStringAsFixed(2)} wet @ ${fxEchoMs.round()} ms'
          : 'off',
    );
    notifyListeners();
  }

  void _applyFx() {
    if (!engineOk) return;
    try {
      engine.setFx(
        fxFilterHz,
        fxEchoWet > 0 ? fxEchoMs : 0,
        fxEchoWet,
      );
    } catch (e) {
      debugPrint('[BAKUSHI] setFx failed: $e');
    }
  }

  /// Combo sparkle (Phase E): 3+ loop pads sounding at once.
  bool get comboActive =>
      countPlayingLoops(pads, _padPlayStates) >= 3 && !chopEditorOpen;

  // --------------------------------------- Sampler Polish: recording + chop

  /// Performance recording state (Task 5).
  RecState recState = RecState.ready;
  final List<PadEvent> _recEvents = [];
  final Map<int, PadRenderSpec> _recSpecs = {};
  DateTime? _recStartAt;
  RenderedPerformance? _lastRender;

  /// Saved performances of the active library song (list UI, read-only).
  List<Map<String, dynamic>> performanceList = [];

  /// The most recent rendered recording (UI shows duration etc.).
  RenderedPerformance? get lastRender => _lastRender;

  /// Task 4B: the chop-original editor is open (replaces the pad grid).
  bool chopEditorOpen = false;

  // ------------------------------------------------------------------ slices
  // (Removed with the strip-down: no slicing, no pads, no beat tracking.)

  /// Drum punch DSP chain (HPF, transient shaper, punch EQ, NY parallel
  /// compression, -1 dBFS normalize) applied to the drums stem after
  /// separation. Default ON.
  bool drumPunch = true;

  // ------------------------------------------------------------- diagnostics
  final List<LogEntry> logs = [];
  bool engineOk = false;
  String? engineError;

  /// Debug hook: HomePage jumps the page scroll to this offset (used by
  /// autotest hold hooks to bring bottom panels into a screenshot).
  final ValueNotifier<double?> debugScrollRequest = ValueNotifier<double?>(null);

  // ----------------------------------------------------------------- library
  late LibraryStore library;
  List<LibraryEntry> librarySongs = [];
  String? activeLibraryId;
  Timer? _librarySaveDebounce;

  // ===================================================================== init

  Future<void> init() async {
    _action('init.begin');
    setStage(PipelineStage.decoding, 'Starting app ...');
    await ModelLocator.loadPersisted();
    _action('init.settingsLoaded');
    refreshModelAvailability();
    await _initLibrary();
    _action('init.libraryLoaded', detail: '${librarySongs.length} songs');
    await _bootEngine();
    log('Bakushi ready. Upload a song to begin.');
    _ensureSidecar();
    _action('init.done', detail: 'engineOk=$engineOk');
    // Phase C: on a brand-new install, auto-load the starter kit into
    // the empty pads once the app has finished booting - the user can
    // make sound within seconds WITHOUT any separation. The flag is
    // persisted so this only happens on the very first launch; the
    // button remains the manual path afterwards. Fill-EMPTY-only, so
    // nothing is ever overwritten.
    final settings = await AppSettings.load();
    if (settings['starter_kit_auto_loaded'] != true) {
      await AppSettings.save({'starter_kit_auto_loaded': true});
      unawaited(loadStarterKit());
    }
    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now();
      final last = _lastWatchdogTick;
      _lastWatchdogTick = now;
      if (last != null && now.difference(last) > const Duration(seconds: 8)) {
        debugPrint(
          '[BAKUSHI] UI STALL DETECTED: '
          '${now.difference(last).inMilliseconds}ms without a timer tick',
        );
      }
    });
    _startPadPlayMonitor();
    final autoMode = Platform.environment['BAKUSHI_AUTOTEST'];
    if (autoMode == '1' || autoMode == 'full') {
      unawaited(_runAutoTest(full: autoMode == 'full'));
    }
  }

  /// Env-gated end-to-end self-test that exercises the exact button code
  /// paths (load audio -> play original -> stop -> optionally separate +
  /// play all stems) without a human. Launch the exe with
  /// BAKUSHI_AUTOTEST=1 (basic) or BAKUSHI_AUTOTEST=full (also separates
  /// using BAKUSHI_MODEL) and watch the console log.
  /// BAKUSHI_AUTOTEST_FILE overrides the input file;
  /// BAKUSHI_AUTOTEST_LIBRARY_ID loads a saved library song instead of
  /// separating; BAKUSHI_BACKEND=gpu selects the GPU device.
  Future<void> _runAutoTest({bool full = false}) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    _action('autoTest.begin');
    final f = File(
      Platform.environment['BAKUSHI_AUTOTEST_FILE'] ?? 'test_song.wav',
    );
    if (!f.existsSync()) {
      _action('autoTest.abort', detail: 'input missing: ${f.path}');
      return;
    }
    _setUpload(f.absolute.path);
    await loadAudio();
    _action('autoTest.playOriginal');
    playOriginal();
    await Future<void>.delayed(const Duration(seconds: 5));
    _action('autoTest.stopAll');
    stopAll();
    if (full) {
      final libId = Platform.environment['BAKUSHI_AUTOTEST_LIBRARY_ID'];
      if (libId != null && libId.isNotEmpty) {
        _action('autoTest.loadLibrary', detail: libId);
        await loadFromLibrary(libId);
      } else {
        final model =
            Platform.environment['BAKUSHI_MODEL'] ??
            'assets${Platform.pathSeparator}models'
            '${Platform.pathSeparator}htdemucs_fp16weights.onnx';
        if (!File(model).existsSync()) {
          _action('autoTest.abort', detail: 'model missing: $model');
          return;
        }
        ModelLocator.userPath = model;
        if (Platform.environment['BAKUSHI_BACKEND'] == 'gpu') {
          selectBackend(SeparationBackend.gpu);
          _action('autoTest.backend', detail: 'gpu');
        }
        _action('autoTest.separate', detail: model);
        await separateStems();
      }
      _action('autoTest.playAllStems');
      playAllStems();
      await Future<void>.delayed(const Duration(seconds: 5));
      _action('autoTest.stopAll');
      stopAll();
    }
    if (Platform.environment['BAKUSHI_AUTOTEST_PADS'] == '1') {
      _action('autoTest.pads.begin');
      await autoFillPads(); // idempotent; BPM is cached
      // Task 1 (Phase B): toggle always stops playback - all 4 cases.
      if (!pads[0].isEmpty) {
        var was = engine.isPadPlaying(0);
        togglePadMode(0); // A: LOOP stopped -> HIT
        _action(
          'toggleCaseA',
          detail:
              'LOOP stopped -> HIT; playing $was -> '
              '${engine.isPadPlaying(0)}; mode=${pads[0].loop ? 'LOOP' : 'HIT'}',
        );
        togglePadMode(0); // B: HIT idle -> LOOP
        _action(
          'toggleCaseB',
          detail:
              'HIT idle -> LOOP; playing ${engine.isPadPlaying(0)}; '
              'mode=LOOP',
        );
        triggerPad(0);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        was = engine.isPadPlaying(0);
        togglePadMode(0); // C: LOOP playing -> HIT
        _action(
          'toggleCaseC',
          detail:
              'LOOP playing -> HIT; playing $was -> '
              '${engine.isPadPlaying(0)}',
        );
        triggerPad(0);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        was = engine.isPadPlaying(0);
        togglePadMode(0); // D: HIT playing -> LOOP
        _action(
          'toggleCaseD',
          detail:
              'HIT playing -> LOOP; playing $was -> '
              '${engine.isPadPlaying(0)}; mode=LOOP',
        );
        engine.stopPad(0);
      }
      for (var i = 0; i < 16; i++) {
        if (pads[i].isEmpty) continue;
        triggerPad(i);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (pads[i].loop) {
          triggerPad(i); // second click stops a looping pad
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      // Acceptance: toggle pad 9 to HIT -> plays once -> toggle back.
      if (!pads[8].isEmpty) {
        togglePadMode(8);
        triggerPad(8);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        togglePadMode(8);
        engine.stopPad(8);
      }
      // Key reassignment proof: assign Q to pad 2 -> swaps with pad 1
      // (Q -> pad 2, W -> pad 1), then swap back.
      _action(
        'padKeys.before',
        detail: [for (var i = 0; i < 16; i++) '${i + 1}=${padKeys[i]}']
            .join(' '),
      );
      assignPadKey(1, 'Q');
      assignPadKey(0, 'Q');
      _action(
        'padKeys.after',
        detail: [for (var i = 0; i < 16; i++) '${i + 1}=${padKeys[i]}']
            .join(' '),
      );
      // Task 3 proof: slice-edit pad 1 (drag start +6000, shrink to
      // 20000 samples), live apply, one-shot preview, then close.
      if (!pads[0].isEmpty) {
        final beforeStart = pads[0].startSample;
        final beforeEnd = pads[0].endSample;
        startPadEdit(0);
        updatePadBounds(0, beforeStart + 6000, beforeStart + 6000 + 20000);
        _action(
          'sliceEdit',
          detail:
              'pad 1 $beforeStart..$beforeEnd -> '
              '${pads[0].startSample}..${pads[0].endSample} (live apply)',
        );
        previewPad(0);
        await Future<void>.delayed(const Duration(milliseconds: 4000));
        engine.stopPad(0);
        endPadEdit();
        _action(
          'sliceEdit.done',
          detail:
              'pad 1 ${pads[0].startSample}..${pads[0].endSample} '
              'previewed',
        );
      }
      // Task 2 (Phase B): custom sample to pad 5, play + cut proof.
      if (Platform.environment['BAKUSHI_AUTOTEST_SAMPLE'] == '1') {
        final samplePath =
            Platform.environment['BAKUSHI_AUTOTEST_SAMPLE_PATH'] ??
            'test_song.wav';
        await assignCustomSampleToPad(4, samplePath);
        _action(
          'uploadVerify',
          detail:
              'pad 5 label=${pads[4].label} custom=${pads[4].custom} '
              'src=${pads[4].customSourcePath} '
              'bounds=${pads[4].startSample}..${pads[4].endSample} '
              'mode=${pads[4].loop ? 'LOOP' : 'HIT'}',
        );
        triggerPad(4);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _action(
          'uploadVerify.play',
          detail:
              'pad 5 playing=${engine.isPadPlaying(4)} '
              '(loop started)',
        );
        triggerPad(4); // click again: loop stops
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _action(
          'uploadVerify.stop',
          detail:
              'pad 5 playing=${engine.isPadPlaying(4)} '
              '(loop stopped)',
        );
        // Cut proof: shrink pad 5's slice to its first half.
        final before5 = '${pads[4].startSample}..${pads[4].endSample}';
        updatePadBounds(
          4,
          pads[4].startSample,
          pads[4].startSample + (pads[4].endSample - pads[4].startSample) ~/ 2,
        );
        _action(
          'uploadVerify.cut',
          detail:
              'pad 5 $before5 -> '
              '${pads[4].startSample}..${pads[4].endSample}',
        );
        previewPad(4);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        engine.stopPad(4);
      }
      // Phase C proof: pitch/reverse/gain on pad 1 + persistence
      // round-trip through the library settings.
      if (Platform.environment['BAKUSHI_AUTOTEST_PADFX'] == '1' &&
          !pads[0].isEmpty) {
        _action('autoTest.padfx.begin');
        setPadPitch(0, 5);
        _action(
          'padfx.pitch',
          detail:
              'pad 1 pitch=${pads[0].pitchSemitones} '
              'rate=${pads[0].playRate.toStringAsFixed(4)}',
        );
        setPadReverse(0, true);
        _action('padfx.reverse', detail: 'pad 1 reverse=${pads[0].reverse}');
        setPadGain(0, 1.5);
        _action(
          'padfx.gain',
          detail:
              'pad 1 gain=${pads[0].gain} '
              'peak=${calculatePeak(pads[0].leftChannel ?? Float32List(0)).toStringAsFixed(3)}',
        );
        triggerPad(0);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        _action(
          'padfx.playing',
          detail:
              'pad 1 playing=${engine.isPadPlaying(0)} '
              '(loop=${pads[0].loop})',
        );
        engine.stopPad(0);
        // Back to neutral, then prove the settings survive a save/restore.
        setPadReverse(0, false);
        setPadPitch(0, 0);
        setPadGain(0, 1.0);
        if (activeLibraryId != null) {
          final snap = _librarySettings();
          await library.saveSettings(activeLibraryId!, snap);
          for (final p in pads) {
            p.clear();
          }
          _applyLibrarySettings(snap);
          await _restoreLibraryPads(snap);
          _action(
            'padfx.restored',
            detail:
                'pad 1 ${pads[0].label} '
                '${pads[0].startSample}..${pads[0].endSample} '
                'pitch=${pads[0].pitchSemitones} '
                'reverse=${pads[0].reverse} '
                'gain=${pads[0].gain.toStringAsFixed(2)}',
          );
        }
        _action('autoTest.padfx.done');
      }
      // Sampler Polish proof: performance recording (Task 5).
      if (Platform.environment['BAKUSHI_AUTOTEST_RECORDING'] == '1' &&
          !pads[0].isEmpty) {
        _action('autoTest.recording.begin');
        selectPad(0);
        setPadPitch(0, -24);
        _action(
          'recording.pitch',
          detail:
              'pad 1 pitch=${pads[0].pitchSemitones} '
              'rate=${pads[0].playRate.toStringAsFixed(4)}',
        );
        startRecording();
        triggerPad(0);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        triggerPad(1);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (pads[2].loop) triggerPad(2); // LOOP on (recorded trigger)
        await Future<void>.delayed(const Duration(milliseconds: 400));
        triggerPad(2); // LOOP off (recorded stop)
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await stopRecording();
        _action(
          'recording.list',
          detail: '${performanceList.length} performance(s)',
        );
        if (performanceList.isNotEmpty) {
          final m = performanceList.first;
          _action(
            'recording.meta',
            detail:
                '${m['name']} ${m['durationSeconds']}s '
                'peak=${m['peak']} events=${m['eventCount']} '
                'path=${m['wavPath']}',
          );
        }
        discardPerformance();
        setPadPitch(0, 0);
        _action('autoTest.recording.done');
      }
      // Screenshot hooks for the selected-pad slider + recording state.
      if (Platform.environment['BAKUSHI_AUTOTEST_HOLD_SELECT'] == '1' &&
          !pads[0].isEmpty) {
        selectPad(0);
        final holdSec =
            int.tryParse(
              Platform.environment['BAKUSHI_AUTOTEST_HOLD_SECONDS'] ?? '60',
            ) ??
            60;
        _action(
          'autoTest.holdSelect',
          detail: 'selected pad slider visible ($holdSec s)',
        );
        await Future<void>.delayed(Duration(seconds: holdSec));
      }
      if (Platform.environment['BAKUSHI_AUTOTEST_HOLD_RECORDING'] == '1') {
        startRecording();
        triggerPad(0);
        final holdSec =
            int.tryParse(
              Platform.environment['BAKUSHI_AUTOTEST_HOLD_SECONDS'] ?? '60',
            ) ??
            60;
        _action(
          'autoTest.holdRecording',
          detail: 'recording state visible ($holdSec s)',
        );
        await Future<void>.delayed(Duration(seconds: holdSec));
        await stopRecording();
        discardPerformance();
      }
      // Sampler Polish proof: original chops (Task 4B). Zero separation
      // inference calls happen in this block - grep the log for
      // 'separateStems' to confirm its absence.
      if (Platform.environment['BAKUSHI_AUTOTEST_CHOP'] == '1') {
        _action('autoTest.chop.begin');
        startChopEditor();
        const sr = 44100;
        assignChopToPad(0, (8.20 * sr).round(), (10.80 * sr).round());
        setPadLoop(0, true); // Pad 1 LOOP
        assignChopToPad(1, (12.40 * sr).round(), (12.85 * sr).round());
        setPadLoop(1, false); // Pad 2 HIT (acceptance)
        setPadPitch(1, 7); // Pad 2 pitch +7
        assignChopToPad(2, (31.10 * sr).round(), (31.45 * sr).round());
        setPadLoop(2, false); // Pad 3 HIT
        setPadReverse(2, true); // Pad 3 reverse
        if (Platform.environment['BAKUSHI_AUTOTEST_HOLD_CHOP'] == '1') {
          final holdSec =
              int.tryParse(
                Platform.environment['BAKUSHI_AUTOTEST_HOLD_SECONDS'] ?? '60',
              ) ??
              60;
          _action(
            'autoTest.holdChop',
            detail: 'chop editor open for screenshot ($holdSec s)',
          );
          await Future<void>.delayed(Duration(seconds: holdSec));
        }
        for (var i = 0; i < 3; i++) {
          _action(
            'chop.verify',
            detail:
                'pad ${i + 1} label=${pads[i].label} '
                'bounds=${pads[i].startSample}..${pads[i].endSample} '
                'loop=${pads[i].loop} pitch=${pads[i].pitchSemitones} '
                'reverse=${pads[i].reverse} gain=${pads[i].gain} '
                'fade=${pads[i].fadeMs}',
          );
          triggerPad(i);
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (pads[i].loop) triggerPad(i); // stop the loop
        }
        final keyPad = padForKey('Q');
        if (keyPad != null) {
          triggerPad(keyPad); // key trigger proof
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        engine.stopAllPads();
        // Record a performance from the 3 chops, then export everything.
        startRecording();
        triggerPad(0);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        triggerPad(1);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        triggerPad(2);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        stopAllPads();
        await stopRecording();
        final outDir = Directory(
          '${workDir.path}${Platform.pathSeparator}chop_export',
        );
        outDir.createSync(recursive: true);
        await exportPlayedPadTo(
          0,
          '${outDir.path}${Platform.pathSeparator}pad1.wav',
        );
        await exportPlayedPadTo(
          1,
          '${outDir.path}${Platform.pathSeparator}pad2.wav',
        );
        await exportPlayedPadTo(
          2,
          '${outDir.path}${Platform.pathSeparator}pad3.wav',
        );
        if (_lastRender != null) {
          await exportPerformanceTo(
            '${outDir.path}${Platform.pathSeparator}performance.wav',
          );
        }
        // Persistence proof: save pads + reload -> 3 chops restored.
        if (activeLibraryId != null) {
          final snap = _librarySettings();
          await library.saveSettings(activeLibraryId!, snap);
          for (final p in pads) {
            p.clear();
          }
          _applyLibrarySettings(snap);
          await _restoreLibraryPads(snap);
          for (var i = 0; i < 3; i++) {
            _action(
              'chop.restored',
              detail:
                  'pad ${i + 1} label=${pads[i].label} '
                  'bounds=${pads[i].startSample}..${pads[i].endSample} '
                  'loop=${pads[i].loop} pitch=${pads[i].pitchSemitones} '
                  'reverse=${pads[i].reverse} fade=${pads[i].fadeMs}',
            );
          }
        }
        endChopEditor();
        _action('autoTest.chop.done');
      }
      // Visual check hook: keep the slice editor open so a screenshot
      // can capture the new Canva-style waveform (optional).
      if (Platform.environment['BAKUSHI_AUTOTEST_HOLD_EDIT'] == '1' &&
          !pads[0].isEmpty) {
        final holdSec =
            int.tryParse(
              Platform.environment['BAKUSHI_AUTOTEST_HOLD_SECONDS'] ?? '60',
            ) ??
            60;
        startPadEdit(0);
        _action(
          'autoTest.holdEdit',
          detail: 'editor open for screenshot ($holdSec s)',
        );
        await Future<void>.delayed(Duration(seconds: holdSec));
        endPadEdit();
      }
      // Phase B visual hook: keep a LOOP pad sounding so the playing
      // glow can be captured.
      if (Platform.environment['BAKUSHI_AUTOTEST_HOLD_GLOW'] == '1' &&
          !pads[0].isEmpty) {
        final loopPad = pads.indexWhere((p) => !p.isEmpty && p.loop);
        if (loopPad >= 0) {
          final holdSec =
              int.tryParse(
                Platform.environment['BAKUSHI_AUTOTEST_HOLD_SECONDS'] ?? '60',
              ) ??
              60;
          triggerPad(loopPad);
          _action(
            'autoTest.holdGlow',
            detail: 'loop pad ${loopPad + 1} playing for screenshot '
                '($holdSec s)',
          );
          await Future<void>.delayed(Duration(seconds: holdSec));
          stopAllPads();
        } else {
          _action('autoTest.holdGlow', detail: 'no LOOP pad to play');
        }
      }
      // Phase D proof: one-level undo (clear -> undo -> bounds restored).
      if (Platform.environment['BAKUSHI_AUTOTEST_UNDO'] == '1' &&
          !pads[0].isEmpty) {
        _action('autoTest.undo.begin');
        final beforeStart = pads[0].startSample;
        final beforeEnd = pads[0].endSample;
        final beforeLabel = pads[0].label;
        selectPad(0);
        clearPad(0);
        _action(
          'autoTest.undo.cleared',
          detail:
              'pad 1 empty=${pads[0].isEmpty} '
              'hasUndo=${padHasUndo(0)}',
        );
        await undoPad(0);
        _action(
          'autoTest.undo.restored',
          detail:
              'pad 1 ${pads[0].startSample}..${pads[0].endSample} '
              '(was $beforeStart..$beforeEnd) label="${pads[0].label}" '
              'match=${pads[0].startSample == beforeStart && pads[0].endSample == beforeEnd && pads[0].label == beforeLabel}',
        );
        if (Platform.environment['BAKUSHI_AUTOTEST_HOLD_UNDO'] == '1') {
          final holdSec =
              int.tryParse(
                Platform.environment['BAKUSHI_AUTOTEST_HOLD_SECONDS'] ?? '60',
              ) ??
              60;
          _action(
            'autoTest.holdUndo',
            detail: 'inspector with undo visible ($holdSec s)',
          );
          await Future<void>.delayed(Duration(seconds: holdSec));
        }
        _action('autoTest.undo.done');
      }
      // Phase E proof: master FX setters (filter + echo) and the combo
      // sparkle (3+ loop pads sounding at once).
      if (Platform.environment['BAKUSHI_AUTOTEST_FX'] == '1' &&
          !pads[0].isEmpty) {
        _action('autoTest.fx.begin');
        setFxFilter(1200);
        setFxEcho(0.3);
        _action(
          'autoTest.fx.applied',
          detail:
              'filter=$fxFilterHz echo=$fxEchoWet '
              'comboBefore=$comboActive',
        );
        triggerPad(0);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _action(
          'autoTest.fx.playing',
          detail: 'pad 1 playing=${engine.isPadPlaying(0)}',
        );
        engine.stopPad(0);
        // Combo: three loop pads at once -> comboActive flips true.
        final loopPads = [
          for (var i = 0; i < 16; i++)
            if (!pads[i].isEmpty && pads[i].loop) i,
        ];
        if (loopPads.length >= 3) {
          for (var i = 0; i < 3; i++) {
            triggerPad(loopPads[i]);
          }
          await Future<void>.delayed(const Duration(milliseconds: 600));
          _action(
            'autoTest.fx.combo',
            detail:
                '3 loops (pads ${loopPads.take(3).map((p) => p + 1).join(',')}) '
                '-> comboActive=$comboActive',
          );
          stopAllPads();
        }
        setFxFilter(0);
        setFxEcho(0);
        _action(
          'autoTest.fx.reset',
          detail: 'filter=$fxFilterHz echo=$fxEchoWet (off)',
        );
        _action('autoTest.fx.done');
      }
      // Step-grid sequencer proof: place steps, play the loop through
      // voice 211, stop, print seq.done.
      if (Platform.environment['BAKUSHI_AUTOTEST_SEQ'] == '1' &&
          !pads[0].isEmpty) {
        _action('autoTest.seq.begin');
        // Idempotent: start from an empty pattern (a previous run may
        // have persisted steps into the library).
        clearPattern();
        // Pad 1 (drums hit) on every quarter; pad 5 (bass loop) offbeats.
        for (final s in [0, 4, 8, 12]) {
          toggleStep(0, s);
        }
        for (final s in [2, 6, 10, 14]) {
          toggleStep(4, s);
        }
        await playPattern();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        _action(
          'autoTest.seq.playing',
          detail:
              'voice ${AppConfig.sequencerVoiceId} '
              'playing=${engine.isVoicePlaying(AppConfig.sequencerVoiceId)} '
              'patternPlaying=$_patternPlaying',
        );
        if (Platform.environment['BAKUSHI_AUTOTEST_HOLD_SEQ'] == '1') {
          final holdSec =
              int.tryParse(
                Platform.environment['BAKUSHI_AUTOTEST_HOLD_SECONDS'] ?? '60',
              ) ??
              60;
          // Bring the sequencer grid into the visible area.
          debugScrollRequest.value = 1200.0;
          _action(
            'autoTest.holdSeq',
            detail: 'sequencer playing for screenshot ($holdSec s)',
          );
          await Future<void>.delayed(Duration(seconds: holdSec));
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        stopPattern();
        final lit = _pattern.lanes.values
            .fold<int>(0, (sum, l) => sum + l.where((v) => v).length);
        _action(
          'seq.done',
          detail:
              'bars=${_pattern.bars} bpm=${_pattern.bpm.toStringAsFixed(1)} '
              'steps=$lit playing=$_patternPlaying',
        );
        _action('autoTest.seq.done');
      }
      engine.stopAllPads();
      _action('autoTest.pads.done');
    }
    _action('autoTest.done');
  }

  /// True when BAKUSHI_AUTO_ADVANCE=1: the wizard advances itself so a
  /// headless run reaches the stems view exactly like a human clicking
  /// through.
  bool get autoAdvanceSteps => _autoAdvanceSteps;
  final bool _autoAdvanceSteps =
      Platform.environment['BAKUSHI_AUTO_ADVANCE'] == '1';

  /// Boot the native audio engine. Runs [bootEngineInIsolate] in a worker
  /// isolate with a timeout so a stalled WASAPI device enumeration can
  /// never freeze the UI. The main isolate then re-runs
  /// [TransportEngine.init] (a no-op in C because the device is already
  /// up) to mark Dart ready.
  Future<void> _bootEngine() async {
    _action('init.engineInitBegin');
    setStage(PipelineStage.decoding, 'Starting audio engine ...');
    try {
      final rate = await Isolate.run(bootEngineInIsolate)
          .timeout(const Duration(seconds: 10));
      if (rate <= 0) {
        throw StateError('ba_init returned $rate');
      }
      engine.init();
      engine.setMasterGain(masterVolume);
      engineOk = true;
      engineError = null;
      _action('init.engineReady', detail: '$rate Hz');
      log('Audio engine ready. Device sample rate: $rate Hz');
      setStage(PipelineStage.idle, '');
    } catch (e) {
      engineOk = false;
      engineError = 'Engine init failed or timed out: $e';
      _action('init.engineFailed', detail: '$e');
      log(engineError!, error: true);
      setStage(PipelineStage.error, 'Audio engine unavailable');
    }
    notifyListeners();
  }

  /// Manual retry for the audio engine (Diagnostics panel).
  Future<void> retryEngineInit() async {
    _action('retryEngineInit');
    await _bootEngine();
  }

  Future<void> _ensureSidecar() async {
    if (sidecar.running) return;
    try {
      final info = await sidecar.start();
      final provs = info.providers.join(', ');
      backend = _pickPreferredBackend(info.providers);
      log('Python sidecar ready (${info.pythonVersion}). Providers: $provs');
    } catch (e) {
      log('Sidecar unavailable: $e', error: true);
    }
  }

  static String _pickPreferredBackend(List<String> providers) {
    for (final p in providers) {
      if (p.toLowerCase().contains('openvino')) return 'OpenVINO';
    }
    if (providers.any((p) => p.toLowerCase().contains('cpu'))) return 'CPU';
    return 'Unsupported';
  }

  Future<void> _initLibrary() async {
    try {
      library = LibraryStore(await ModelLocator.appSupportDir());
      librarySongs = await library.list();
      _action(
        'library.ready',
        detail: '${librarySongs.length} songs',
        quiet: true,
      );
    } catch (e) {
      log('Library unavailable: $e', error: true);
      library = LibraryStore(Directory.systemTemp);
      librarySongs = [];
    }
  }

  /// Debug tracing for every button: one line on the console (flutter run)
  /// and one in the on-screen Diagnostics console. [quiet] skips the
  /// on-screen log (used by sliders that fire continuously).
  void _action(String name, {String? detail, bool quiet = false}) {
    final msg = '[action] $name${detail == null ? '' : ' ($detail)'}';
    debugPrint('[BAKUSHI] $msg');
    if (!quiet) log(msg);
  }

  // =================================================================== upload

  Future<void> pickFile() async {
    _action('pickFile.begin');
    try {
      final f = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Audio', extensions: ['wav', 'mp3', 'ogg', 'm4a']),
        ],
      );
      final path = f?.path;
      if (path == null) {
        _action('pickFile.cancelled');
        return;
      }
      _action('pickFile.done', detail: path);
      _setUpload(path);
      // Step 1 spec: upload automatically decodes and advances.
      await loadAudio();
    } catch (e) {
      log('File picker failed: $e', error: true);
    }
  }

  void _setUpload(String path) {
    if (path.trim().isEmpty) return;
    if (busy) {
      log(
        'Wait for the current task to finish before loading a new song.',
        error: true,
      );
      return;
    }
    final f = File(path);
    if (!f.existsSync()) {
      log('Selected file does not exist: $path', error: true);
      return;
    }
    filePath = path;
    fileName = f.uri.pathSegments.last;
    fileSizeBytes = f.lengthSync();
    _action('upload.picked', detail: '$fileName (${_fmtBytes(fileSizeBytes)})');
    log('Selected: $fileName (${_fmtBytes(fileSizeBytes)})');
    notifyListeners();
  }

  /// Drag-and-drop entry point (also auto-decodes).
  void onFileDropped(String path) {
    _action('upload.dropped', detail: path);
    _setUpload(path);
    unawaited(loadAudio());
  }

  Future<void> loadAudio() async {
    _action('loadAudio.begin', detail: filePath);
    final path = filePath;
    if (path == null) {
      log('No file selected. Pick an audio file first.', error: true);
      return;
    }
    if (!engineOk) {
      log('Audio engine unavailable; playback will not work.', error: true);
    }
    // A new upload replaces the decoded original (old stems stay until a
    // new separation finishes).
    original = null;
    setStage(PipelineStage.decoding, 'Starting local decoder ...');
    await _ensureSidecar();
    _action('loadAudio.sidecarReady', detail: '${sidecar.running}');
    if (!sidecar.running) {
      setStage(PipelineStage.error, 'Sidecar unavailable. See diagnostics.');
      log('Cannot decode: Python sidecar is not running.', error: true);
      return;
    }
    setStage(PipelineStage.decoding, 'Decoding $fileName ...');
    try {
      _action('loadAudio.decodeBegin');
      final audio = await decoder.decode(path);
      _action(
        'loadAudio.decoded',
        detail: '${audio.duration.toStringAsFixed(2)}s',
      );
      original = audio;
      _action('loadAudio.engineLoadBegin', detail: '${audio.frames} frames');
      if (engineOk) {
        try {
          engine.loadOriginal(audio.left, audio.right);
          _action('loadAudio.engineLoaded');
        } catch (e) {
          _action('loadAudio.engineLoadFailed', detail: '$e');
          log(
            'Could not load audio into the audio engine (low memory?): $e',
            error: true,
          );
        }
      }
      log(
        'Decoded: ${audio.duration.toStringAsFixed(2)}s, '
        '${audio.sampleRate} Hz, stereo, '
        '${(audio.left.length * 4 * 2 / 1024 / 1024).toStringAsFixed(1)} MB '
        'PCM in memory',
      );
      if (audio.duration > AppConfig.maxInputSeconds) {
        log(
          'Warning: ${audio.duration.toStringAsFixed(1)}s exceeds the '
          '${AppConfig.maxInputSeconds}s cap; separation will refuse it. '
          'Trim the file or raise AppConfig.maxInputSeconds.',
          error: true,
        );
      } else if (audio.duration > 120) {
        log(
          'Heads-up: ${audio.duration.toStringAsFixed(1)}s separation '
          'keeps ~2 GB of audio in memory. Close memory-hungry apps if '
          'separation stalls.',
        );
      }
      setStage(PipelineStage.idle, '');
      _action('loadAudio.done');
    } catch (e) {
      _action('loadAudio.error', detail: '$e');
      setStage(PipelineStage.error, 'Decode failed');
      log('Decode failed: $e', error: true);
    }
  }

  // =============================================================== transport

  void playOriginal() {
    _action('playOriginal');
    try {
      final o = original;
      if (o == null) {
        log('No audio loaded. Click "Load Audio" first.', error: true);
        return;
      }
      if (!engine.originalLoaded) {
        _action('playOriginal.noEngineBuffer');
        log(
          'Audio is not loaded into the audio engine (low memory?). '
          'Restart the app and try again.',
          error: true,
        );
        return;
      }
      engine.stopTransport();
      _action('playOriginal.stopDone');
      engine.startTransport(
        startSec: 0,
        durationSec: o.duration,
        stemGains: _originalOnlyGains(),
      );
      _action(
        'playOriginal.started',
        detail: 'dur=${o.duration.toStringAsFixed(1)}s',
      );
    } catch (e) {
      _action('playOriginal.error', detail: '$e');
      log('Play failed: $e', error: true);
    }
  }

  /// Play every stem together from the start (the full mix, no original).
  void playAllStems() {
    _action('playAllStems');
    if (stems.isEmpty) {
      log('Separate stems first.', error: true);
      return;
    }
    engine.stopTransport();
    engine.startTransport(
      startSec: 0,
      durationSec: _transportDuration,
      stemGains: _stemOnlyGains(),
    );
  }

  /// Play one stem alone (solo audition), respecting mute/volume.
  void playSingleStem(String name) {
    _action('playSingleStem', detail: name);
    final stem = stems[name];
    if (stem == null) return;
    engine.stopTransport();
    final gains = <String, double>{
      for (final n in activeStemNames) n: 0.0,
      'original': 0.0,
    };
    final g = effectiveStemGain(name);
    gains[name] = g == 0 ? 1.0 : g;
    engine.startTransport(
      startSec: 0,
      durationSec: _transportDuration,
      stemGains: gains,
    );
  }

  /// Longest available duration (original or the longest stem).
  double get _transportDuration {
    final o = original;
    if (o != null) return o.duration;
    if (stems.isEmpty) return 0;
    return stems.values.map((s) => s.duration).reduce(math.max);
  }

  Map<String, double> _originalOnlyGains() => {
    for (final n in activeStemNames) n: 0.0,
    'original': 1.0,
  };

  Map<String, double> _stemOnlyGains() => {
    ..._effectiveStemGains(),
    'original': 0.0,
  };

  /// Mixer play: resume from the current position.
  void playMix() {
    _action('playMix');
    final o = original;
    if (o == null) return;
    if (!engine.originalLoaded) {
      log(
        'Audio is not loaded into the audio engine (low memory?). '
        'Restart the app and try again.',
        error: true,
      );
      return;
    }
    engine.startTransport(
      startSec: engine.transportPositionSec.clamp(0, o.duration).toDouble(),
      durationSec: o.duration,
      stemGains: _stemOnlyGains(),
    );
  }

  void pauseMix() {
    _action('pauseMix');
    engine.pauseTransport();
  }

  void stopMix() {
    _action('stopMix');
    engine.stopTransport();
  }

  void stopAll() {
    _action('stopAll');
    engine.stopTransport();
    log('Stopped.');
  }

  /// Task 1: near-silent stems (RMS < [AppConfig.silentStemRms]) are
  /// hidden from the default Step 3 view; the data stays for export.
  /// (Phase D: the old show-silent toggle was unwired - REMOVED.)
  bool isStemSilent(String name) =>
      AppConfig.isSilentRms(stems[name]?.rms ?? 1.0);

  /// Reset to a clean session (back to Step 1). The saved library entry
  /// on disk is untouched.
  void newSong() {
    _action('newSong');
    engine.stopTransport();
    for (final n in stems.keys) {
      engine.unloadStem(n);
    }
    stems.clear();
    activeStemNames = List.of(AppConfig.stemNames);
    stemVolumes
      ..clear()
      ..addAll({for (final n in AppConfig.stemNames) n: 1.0});
    mutedStems.clear();
    soloStem = null;
    original = null;
    filePath = null;
    fileName = null;
    fileSizeBytes = 0;
    progress = 0;
    sepMeta = null;
    activeLibraryId = null;
    engine.stopAllPads();
    for (final p in pads) {
      p.clear();
    }
    _resetPadKeys();
    detectedBpm = null;
    detectedBeats = [];
    detectedDownbeats = [];
    detectedOnsets = [];
    editingPadIndex = null;
    selectedPadIndex = null;
    _customSamples.clear();
    _clearPadUndo();
    chopEditorOpen = false;
    recState = RecState.ready;
    _recEvents.clear();
    _recSpecs.clear();
    _lastRender = null;
    performanceList = [];
    engine.stopVoice(AppConfig.recordingPreviewVoiceId);
    // Sequencer: back to an empty default pattern.
    _patternRerender?.cancel();
    _patternPlaying = false;
    engine.stopVoice(AppConfig.sequencerVoiceId);
    _pattern = Pattern(bpm: detectedBpm ?? 100, bars: 2);
    mutedPatternLanes.clear();
    setStage(PipelineStage.idle, '');
    notifyListeners();
  }

  void seek(double sec) {
    _action('seek', detail: sec.toStringAsFixed(2), quiet: true);
    final o = original;
    if (o == null) return;
    engine.seekTransport(sec.clamp(0, o.duration).toDouble());
  }

  Map<String, double> _effectiveStemGains() {
    final out = <String, double>{};
    for (final name in activeStemNames) {
      var g = stemVolumes[name] ?? 1.0;
      if (mutedStems.contains(name)) g = 0;
      if (soloStem != null && soloStem != name) g = 0;
      out[name] = g;
    }
    return out;
  }

  void setStemVolume(String name, double v) {
    _action(
      'setStemVolume',
      detail: '$name=${v.toStringAsFixed(2)}',
      quiet: true,
    );
    stemVolumes[name] = v;
    engine.setStemGain(name, effectiveStemGain(name));
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  double effectiveStemGain(String name) {
    var g = stemVolumes[name] ?? 1.0;
    if (mutedStems.contains(name)) return 0;
    if (soloStem != null && soloStem != name) return 0;
    return g;
  }

  void toggleMute(String name) {
    _action('toggleMute', detail: name);
    if (mutedStems.contains(name)) {
      mutedStems.remove(name);
    } else {
      mutedStems.add(name);
    }
    engine.setStemGain(name, effectiveStemGain(name));
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  void toggleSolo(String name) {
    _action('toggleSolo', detail: name);
    soloStem = soloStem == name ? null : name;
    for (final n in activeStemNames) {
      engine.setStemGain(n, effectiveStemGain(n));
    }
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  void setMasterVolume(double v) {
    _action('setMasterVolume', detail: v.toStringAsFixed(2), quiet: true);
    masterVolume = v;
    engine.setMasterGain(v);
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  // ==================================================================== pads

  /// Detect tempo + beats/downbeats/onsets via the sidecar (cached for
  /// the session). Phase A (vision): the result feeds the musical pad
  /// planner - LOOP pads anchor on real downbeats, HIT pads use onset
  /// one-shots. Runs on long songs take minutes; a progress stage is
  /// shown the whole time.
  Future<bool> analyzeBpm() async {
    _action('analyzeBpm.begin');
    if (stems.isEmpty) {
      showToast('Separate stems first.');
      return false;
    }
    setStage(
      PipelineStage.analyzing,
      'Finding the beat ... (long songs take a minute or two)',
    );
    try {
      await _ensureSidecar();
      await _ensureStemWorkFiles();
      final payload = <String, dynamic>{'stems': <String, dynamic>{}};
      for (final name in activeStemNames) {
        final l = '${workDir.path}${Platform.pathSeparator}${name}_l.f32le';
        final r = '${workDir.path}${Platform.pathSeparator}${name}_r.f32le';
        if (File(l).existsSync() && File(r).existsSync()) {
          (payload['stems'] as Map<String, dynamic>)[name] = {
            'left': l,
            'right': r,
          };
        }
      }
      if ((payload['stems'] as Map).isEmpty) {
        throw StateError('separated stem PCM files are missing');
      }
      final res = await sidecar.request(
        'beat_analyze',
        payload,
        timeout: const Duration(minutes: 6),
      );
      final bpm = (res['bpm'] as num?)?.toDouble();
      if (bpm == null || bpm <= 0) {
        throw StateError('sidecar returned no BPM');
      }
      detectedBpm = bpm;
      detectedBeats = ((res['beats'] as List?) ?? const [])
          .map((v) => (v as num).toInt())
          .where((v) => v >= 0)
          .toList();
      detectedDownbeats = ((res['downbeats'] as List?) ?? const [])
          .map((v) => (v as num).toInt())
          .where((v) => v >= 0)
          .toList();
      detectedOnsets = ((res['onsets'] as List?) ?? const [])
          .map((v) => (v as num).toInt())
          .where((v) => v >= 0)
          .toList();
      detectedBeats.sort();
      detectedDownbeats.sort();
      detectedOnsets.sort();
      log(
        'Tempo: ${bpm.toStringAsFixed(1)} BPM, '
        '${detectedBeats.length} beats, '
        '${detectedDownbeats.length} downbeats, '
        '${detectedOnsets.length} drum onsets.',
      );
      setStage(PipelineStage.ready, '');
      notifyListeners();
      _action(
        'analyzeBpm.done',
        detail:
            '$bpm beats=${detectedBeats.length} '
            'downbeats=${detectedDownbeats.length} '
            'onsets=${detectedOnsets.length}',
      );
      // Persist the beats with the library entry so the next load of
      // this song skips the re-analysis entirely.
      _scheduleLibrarySettingsSave();
      return true;
    } catch (e, st) {
      debugPrint('[BAKUSHI] analyzeBpm failed: $e\n$st');
      setStage(PipelineStage.ready, '');
      log('Beat detection failed: $e', error: true);
      showToast('Beat detection failed: $e');
      return false;
    }
  }

  /// Make sure every active stem has an f32le pair in the work dir so the
  /// sidecar can analyze it. Fresh separations already have them; songs
  /// loaded from the library do not.
  Future<void> _ensureStemWorkFiles() async {
    for (final name in activeStemNames) {
      final stem = stems[name];
      if (stem == null) continue;
      final l = '${workDir.path}${Platform.pathSeparator}${name}_l.f32le';
      final r = '${workDir.path}${Platform.pathSeparator}${name}_r.f32le';
      if (!File(l).existsSync()) await writeF32Le(l, stem.left);
      if (!File(r).existsSync()) await writeF32Le(r, stem.right);
    }
  }

  /// Auto-Fill (AUTOMATIC): every non-silent stem shares the 16 pads
  /// proportionally. Phase A (vision): pads are MUSICAL - LOOP pads
  /// start on real downbeats (2-bar preferred, 1-bar fallback) and HIT
  /// pads are onset one-shots from the drums stem; each group ranks by
  /// RMS energy, loudest first. The old uniform grid remains only as
  /// the fallback when no downbeats are available.
  Future<void> autoFillPads() async {
    _action('autoFillPads.begin');
    if (stems.isEmpty) {
      showToast('Separate stems first.');
      return;
    }
    final audible = activeStemNames
        .where((n) => stems.containsKey(n) && !isStemSilent(n))
        .toList();
    final skipped = activeStemNames
        .where((n) => stems.containsKey(n) && isStemSilent(n))
        .toList();
    final parts = audible
        .map((n) => '$n (RMS ${stems[n]!.rms.toStringAsFixed(4)})')
        .toList();
    _action(
      'stem.audioSummary',
      detail:
          'Stems with audio: ${parts.join(', ')}.'
          '${skipped.isEmpty ? '' : ' ${skipped.join('/')} silent - skipped.'}',
    );
    if (audible.isEmpty) {
      showToast('No stems with audio (all silent).');
      notifyListeners();
      return;
    }
    var bpm = detectedBpm;
    if (bpm == null) {
      final ok = await analyzeBpm();
      if (!ok) return;
      bpm = detectedBpm;
    }
    if (bpm == null) return;
    // Sequencer default tempo follows the analyzed BPM while the pattern
    // is untouched (the user's own tempo wins once steps exist).
    if (_pattern.isEmpty) {
      _pattern.bpm = bpm;
    }
    engine.stopAllPads();
    engine.stopVoice(AppConfig.sequencerVoiceId);
    for (final p in pads) {
      p.clear();
    }
    _clearPadUndo();
    _resetPadKeys();
    editingPadIndex = null;
    selectedPadIndex = null;
    // Pads changed under the pattern: stop the loop; the user can replay
    // it (edits re-render).
    _patternRerender?.cancel();
    _patternPlaying = false;
    final fade = padFadeSamples(AppConfig.padFadeMsDefault, 44100);
    final shares = proportionalPadShares(audible.length);
    final sr = 44100;
    final useMusical =
        detectedDownbeats.length >= 2 &&
        detectedBpm != null &&
        detectedBpm! > 0;
    var padIndex = 0;
    var filled = 0;
    final fills = useMusical
        ? planMusicalPads(
            stemNames: audible,
            shares: shares,
            sources: {
              for (final n in audible)
                n: FillSource(
                  name: n,
                  left: stems[n]!.left,
                  right: stems[n]!.right,
                  sampleRate: stems[n]!.sampleRate,
                ),
            },
            bpm: bpm,
            downbeats: detectedDownbeats,
            onsets: {'drums': detectedOnsets},
          )
        : <PlannedFill>[];
    if (useMusical && fills.length >= audible.length) {
      // Musical path: apply the planned fills to the pads.
      final counts = <String, int>{};
      for (final f in fills) {
        if (padIndex >= 16) break;
        final stem = stems[f.stemName];
        if (stem == null) continue;
        final s0 = f.startSample.clamp(0, stem.frames - 2);
        final e0 = f.endSample.clamp(s0 + 2, stem.frames);
        final l = createSliceBuffer(stem.left, s0, e0, fade);
        final r = createSliceBuffer(stem.right, s0, e0, fade);
        final n = (counts[f.stemName] ?? 0) + 1;
        counts[f.stemName] = n;
        final pad = pads[padIndex++];
        pad
          ..stemName = stem.name
          ..startSample = s0
          ..endSample = e0
          ..leftChannel = l
          ..rightChannel = r
          ..sampleRate = stem.sampleRate
          ..label = '${stem.name} $n'
          ..loop = f.loop
          ..origStartSample = s0
          ..origEndSample = e0;
        filled++;
        final dbOff = nearestDownbeatOffset(detectedDownbeats, s0);
        _action(
          'fill',
          detail:
              'pad $padIndex: ${pad.stemName} '
              '${(s0 / stem.sampleRate).toStringAsFixed(3)}s..'
              '${(e0 / stem.sampleRate).toStringAsFixed(3)}s '
              '${pad.loop ? 'LOOP' : 'HIT'} '
              '(len ${(e0 - s0) / stem.sampleRate}s, '
              'downbeat-offset ${dbOff < 0 ? 'n/a' : '$dbOff samples'})',
        );
      }
      // Acceptance proof: timestamps must be VARIED and downbeat-aligned.
      var maxLoopOff = 0;
      var maxHitOff = 0;
      for (final f in fills) {
        final off = nearestDownbeatOffset(detectedDownbeats, f.startSample);
        if (f.loop) {
          if (off > maxLoopOff) maxLoopOff = off;
        } else {
          if (off > maxHitOff) maxHitOff = off;
        }
      }
      _action(
        'fill.musical',
        detail:
            'downbeat-anchored fill: ${fills.length} pad(s), '
            'LOOP pads max downbeat offset $maxLoopOff samples '
            '(${(maxLoopOff / sr * 1000).toStringAsFixed(1)} ms), '
            'HIT pads max offset $maxHitOff samples '
            '(${(maxHitOff / sr * 1000).toStringAsFixed(1)} ms), '
            'hits=${fills.where((f) => !f.loop).length}, '
            'loops=${fills.where((f) => f.loop).length}',
      );
    } else {
      // Uniform fallback (no downbeats or not enough musical fills):
      // the old beat-locked grid anchored at sample 0.
      _action(
        'fill.uniformFallback',
        detail:
            'downbeats=${detectedDownbeats.length} - using the uniform '
            'beat grid (samples anchored at 0).',
      );
      for (var si = 0; si < audible.length; si++) {
        final stem = stems[audible[si]]!;
        final needed = shares[si];
        final barSamples = (4 * 60.0 / bpm * stem.sampleRate).round().clamp(
          1,
          stem.frames,
        );
        final twoBarSamples = barSamples * 2;
        // Short song: 1-bar segments when 2-bar ones cannot cover the
        // group.
        final useBar = stem.frames < needed * twoBarSamples;
        final division = useBar ? Division.bar : Division.twoBars;
        final segments = computePadSegments(
          bpm: bpm,
          sampleRate: stem.sampleRate,
          totalFrames: stem.frames,
          division: division,
          maxSegments: 1 << 30,
        );
        final ranked = [
          for (final seg in segments)
            (
              seg: seg,
              rms: segmentRms(
                stem.left,
                stem.right,
                seg.startSample,
                seg.endSample,
              ),
            ),
        ]..sort((a, b) => b.rms.compareTo(a.rms));
        for (var p = 0; p < needed; p++) {
          final entry = ranked[p % ranked.length];
          final seg = entry.seg;
          final l = createSliceBuffer(
            stem.left,
            seg.startSample,
            seg.endSample,
            fade,
          );
          final r = createSliceBuffer(
            stem.right,
            seg.startSample,
            seg.endSample,
            fade,
          );
          final pad = pads[padIndex++];
          pad
            ..stemName = stem.name
            ..startSample = seg.startSample
            ..endSample = seg.endSample
            ..leftChannel = l
            ..rightChannel = r
            ..sampleRate = stem.sampleRate
            ..label = '${stem.name} ${p + 1}'
            ..loop =
                true // LOOP default; user toggles to HIT
            ..origStartSample = seg.startSample
            ..origEndSample = seg.endSample;
          filled++;
          _action(
            'fill',
            detail:
                'pad $padIndex: ${pad.stemName} '
                '${(pad.startSample / stem.sampleRate).toStringAsFixed(3)}s..'
                '${(pad.endSample / stem.sampleRate).toStringAsFixed(3)}s '
                '${pad.loop ? 'LOOP' : 'HIT'} '
                '(rms ${entry.rms.toStringAsFixed(4)}, '
                '${useBar ? '1-bar' : '2-bar'})',
          );
        }
      }
    }
    _action(
      'fill',
      detail:
          'Filled $filled/16 pads (${audible.join(', ')}, '
          '${bpm.toStringAsFixed(1)} BPM, proportional split, '
          'best energy first).',
    );
    _action(
      'padKeys',
      detail: [for (var i = 0; i < 16; i++) '${i + 1}=${padKeys[i]}'].join(' '),
    );
    showToast('Filled $filled pad(s) from the best moments.');
    notifyListeners();
    _action('autoFillPads.done', detail: '$filled pads');
  }

  /// Trigger pad [index]: HIT plays once; LOOP toggles start/stop.
  /// Empty pads never touch the engine - a toast explains what to do.
  void triggerPad(int index) {
    final pad = pads[index];
    _action(
      'triggerPad',
      detail:
          'pad ${index + 1} '
          '(${pad.isEmpty ? 'empty' : '${pad.stemName} ${pad.loop ? 'loop' : 'hit'}'})',
    );
    final msg = emptyPadTriggerMessage(pad);
    if (msg != null) {
      showToast(msg);
      return; // BEFORE any engine/FFI call.
    }
    try {
      if (pad.loop && engine.isPadPlaying(index)) {
        _stopPadNow(index); // records 'stop' while recording
      } else {
        _recordPadEvent(index, 'trigger');
        final spec = PadPlaySpec.fromPad(pad);
        engine.loadPad(index, pad.leftChannel!, pad.rightChannel!);
        engine.playPad(
          index,
          loop: spec.loop,
          pitch: spec.pitch,
          reverse: spec.reverse,
        );
      }
    } catch (e) {
      debugPrint('[BAKUSHI] pad engine error: $e');
      log('Pad playback failed: $e', error: true);
    }
    notifyListeners();
  }

  /// Stop every sounding pad.
  void stopAllPads() {
    _action('stopAllPads');
    for (var i = 0; i < 16; i++) {
      if (_padPlayStates[i]) _recordPadEvent(i, 'stop');
    }
    engine.stopAllPads();
    for (var i = 0; i < 16; i++) {
      _padPlayStates[i] = false;
    }
    notifyListeners();
  }

  /// Toggle ONE pad between HIT and LOOP (per-pad mode).
  /// Task 1 rule (Phase B): the toggle ALWAYS stops that pad's playback
  /// immediately - predictable, no dangling loops.
  void togglePadMode(int index) {
    final pad = pads[index];
    if (pad.isEmpty) return;
    final wasPlaying = engine.isPadPlaying(index);
    final wasLoop = pad.loop;
    pad.loop = !pad.loop;
    _stopPadNow(index); // records 'stop' while recording
    _action(
      'togglePadMode',
      detail:
          'pad ${index + 1} ${wasLoop ? 'LOOP' : 'HIT'} -> '
          '${pad.loop ? 'LOOP' : 'HIT'} '
          '(playing $wasPlaying -> stopped)',
    );
    notifyListeners();
  }

  // --------------------------------------------------------- Phase C: pads

  /// Set pad [index] mode directly (inspector HIT/LOOP pills). Switching
  /// always stops the pad immediately - no dangling loops.
  void setPadLoop(int index, bool loop) {
    final pad = pads[index];
    if (pad.isEmpty || pad.loop == loop) return;
    _stopPadNow(index);
    pad.loop = loop;
    _action(
      'setPadLoop',
      detail: 'pad ${index + 1} -> ${loop ? 'LOOP' : 'HIT'} (stopped)',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Stop pad [index] immediately (public wrapper for the inspector).
  void stopPadNow(int index) {
    _stopPadNow(index);
    _action('stopPadNow', detail: 'pad ${index + 1}', quiet: true);
    notifyListeners();
  }

  /// Stop pad [index] without notifying (used inside other setters).
  /// Every stop path funnels through here so recordings capture it.
  void _stopPadNow(int index) {
    _recordPadEvent(index, 'stop');
    try {
      engine.stopPad(index);
    } catch (_) {}
    _padPlayStates[index] = false;
  }

  /// Select pad [index] in the grid (settings icon). Tapping again
  /// deselects. Selection never triggers playback.
  void selectPad(int index) {
    selectedPadIndex = selectedPadIndex == index ? null : index;
    _action(
      'selectPad',
      detail:
          'pad ${index + 1}'
          '${selectedPadIndex == null ? ' (deselected)' : ''}',
    );
    notifyListeners();
  }

  // -------------------------------------------------------- Phase D: undo

  /// One-level, in-memory undo snapshots per pad. Taken BEFORE a
  /// destructive action; never persisted. The FIRST snapshot wins until
  /// the user undoes (multiple quick edits undo back to the pre-edit
  /// state in one step).
  final Map<int, PadSnapshot?> _padUndo = {};

  void _snapshotPadForUndo(int index) {
    if (_padUndo[index] != null) return;
    final snap = PadSnapshot.of(pads[index]);
    if (snap != null) _padUndo[index] = snap;
  }

  void _clearPadUndo() => _padUndo.clear();

  bool padHasUndo(int index) => _padUndo[index] != null;

  /// Restore the pre-destructive-action state of pad [index]: bounds,
  /// pitch, reverse, gain, fade, label and source kind. Buffers are
  /// re-baked from the source PCM.
  Future<void> undoPad(int index) async {
    final snap = _padUndo.remove(index);
    if (snap == null) {
      showToast('Nothing to undo on this pad.');
      notifyListeners();
      return;
    }
    _stopPadNow(index);
    final pad = pads[index];
    pad.clear();
    var ok = false;
    if (snap.custom && snap.customSourcePath != null) {
      final path = snap.customSourcePath!;
      if (File(path).existsSync()) {
        _customSamples.remove(index);
        await assignCustomSampleToPad(
          index,
          path,
          bpm: snap.customBpm,
          quiet: true,
        );
        ok = !pads[index].isEmpty;
      }
    } else if (snap.original && original != null) {
      final o = original!;
      applyPadBounds(
        pad,
        stemLeft: o.left,
        stemRight: o.right,
        sampleRate: o.sampleRate,
        startSample: snap.startSample,
        endSample: snap.endSample,
        fadeSamples: padFadeSamples(clampPadFadeMs(snap.fadeMs), o.sampleRate),
        gain: clampPadGain(snap.gain),
      );
      pad
        ..original = true
        ..stemName = snap.stemName;
      ok = true;
    } else if (snap.starter && snap.starterName != null) {
      try {
        final sound = loadStarterSound(snap.starterName!);
        applyPadBounds(
          pad,
          stemLeft: sound.left,
          stemRight: sound.right,
          sampleRate: sound.sampleRate,
          startSample: 0,
          endSample: snap.endSample.clamp(1, sound.frames),
          fadeSamples: padFadeSamples(
            clampPadFadeMs(snap.fadeMs),
            sound.sampleRate,
          ),
          gain: clampPadGain(snap.gain),
        );
        pad
          ..starter = true
          ..starterName = snap.starterName
          ..stemName = snap.stemName;
        ok = true;
      } catch (e) {
        _action('undoPad.starter', detail: 'pad ${index + 1}: $e');
      }
    } else if (snap.stemName != null && stems.containsKey(snap.stemName)) {
      final stem = stems[snap.stemName!]!;
      applyPadBounds(
        pad,
        stemLeft: stem.left,
        stemRight: stem.right,
        sampleRate: stem.sampleRate,
        startSample: snap.startSample,
        endSample: snap.endSample,
        fadeSamples: padFadeSamples(
          clampPadFadeMs(snap.fadeMs),
          stem.sampleRate,
        ),
        gain: clampPadGain(snap.gain),
      );
      pad.stemName = snap.stemName;
      ok = true;
    }
    if (!ok) {
      _action(
        'undoPad.failed',
        detail: 'pad ${index + 1} source audio is gone',
      );
      showToast("Can't undo - the pad's source audio is gone.");
      notifyListeners();
      return;
    }
    pad
      ..loop = snap.loop
      ..pitchSemitones = clampPadPitch(snap.pitchSemitones)
      ..reverse = snap.reverse
      ..gain = clampPadGain(snap.gain)
      ..fadeMs = clampPadFadeMs(snap.fadeMs)
      ..label = snap.label
      ..edited = snap.edited
      ..origStartSample = snap.origStartSample
      ..origEndSample = snap.origEndSample;
    _action(
      'undoPad',
      detail:
          'pad ${index + 1} -> ${pad.startSample}..${pad.endSample} '
          '${pad.loop ? 'LOOP' : 'HIT'} pitch=${pad.pitchSemitones} '
          'reverse=${pad.reverse} gain=${pad.gain.toStringAsFixed(2)} '
          'fade=${pad.fadeMs.round()}ms label="${pad.label}"',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
    showToast('Pad ${index + 1} undone.');
  }

  // -------------------------------------------------------- step sequencer

  /// Toggle the step at [step] for pad [pad]. While the pattern plays,
  /// edits re-render after a short debounce.
  void toggleStep(int pad, int step) {
    if (pad < 0 || pad > 15) return;
    final lane = _pattern.laneFor(pad);
    if (step < 0 || step >= lane.length) return;
    lane[step] = !lane[step];
    _action(
      'seq.step',
      detail: 'pad ${pad + 1} step $step -> ${lane[step]}',
      quiet: true,
    );
    _schedulePatternRender();
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  void clearPattern() {
    _pattern.clear();
    _action('seq.clear');
    _schedulePatternRender();
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  void setPatternBars(int bars) {
    _pattern.setBars(bars);
    _action('seq.bars', detail: '${_pattern.bars}');
    _schedulePatternRender();
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  void setPatternBpm(double bpm) {
    _pattern.bpm = bpm.clamp(60.0, 180.0);
    _action('seq.bpm', detail: _pattern.bpm.toStringAsFixed(1));
    _schedulePatternRender();
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  void togglePatternLaneMute(int pad) {
    if (mutedPatternLanes.contains(pad)) {
      mutedPatternLanes.remove(pad);
    } else {
      mutedPatternLanes.add(pad);
    }
    _action('seq.mute', detail: 'pad ${pad + 1} muted=${
        mutedPatternLanes.contains(pad)}');
    _schedulePatternRender();
    notifyListeners();
  }

  void _schedulePatternRender() {
    if (!_patternPlaying) return;
    _patternRerender?.cancel();
    _patternRerender = Timer(const Duration(milliseconds: 300), () {
      unawaited(_renderPattern(start: false));
    });
  }

  /// Render the whole pattern OFFLINE (existing performance renderer),
  /// load it into voice 211 and loop it. Sample-accurate - no C engine
  /// changes.
  Future<void> _renderPattern({required bool start}) async {
    _patternRerender?.cancel();
    final events = patternEvents(
      totalSteps: _pattern.totalSteps,
      bpm: _pattern.bpm,
      lanes: _pattern.lanes,
      mutedLanes: mutedPatternLanes,
    );
    final specs = <int, PadRenderSpec>{};
    for (final e in events) {
      final pad = pads[e.padIndex];
      if (pad.isEmpty) continue;
      specs[e.padIndex] ??= PadRenderSpec.fromPad(pad);
    }
    if (events.isEmpty || specs.isEmpty) {
      try {
        engine.stopVoice(AppConfig.sequencerVoiceId);
      } catch (_) {}
      _patternPlaying = false;
      if (!start) notifyListeners();
      return;
    }
    final sr = AppConfig.engineSampleRate;
    RenderedPerformance rendered;
    try {
      rendered = await renderPerformanceInIsolate(events, specs, sr);
    } catch (e) {
      debugPrint('[BAKUSHI] pattern render isolate failed: $e');
      rendered = renderPerformanceSync(events, specs, sr);
    }
    final frames = patternFrames(
      bpm: _pattern.bpm,
      bars: _pattern.bars,
      sampleRate: sr,
    );
    final loop = fitPatternLoop(rendered, frames);
    engine.loadVoice(AppConfig.sequencerVoiceId, loop.left, loop.right);
    engine.playVoice(AppConfig.sequencerVoiceId, loop: true);
    _patternPlaying = true;
    _action(
      'seq.render',
      detail:
          'bars=${_pattern.bars} bpm=${_pattern.bpm.toStringAsFixed(1)} '
          'events=${events.length} '
          'loop=${(frames / sr).toStringAsFixed(3)}s '
          'voice=${AppConfig.sequencerVoiceId}',
    );
    if (!start) notifyListeners();
  }

  /// Start the pattern loop (renders + plays voice 211 looping).
  Future<void> playPattern() async {
    if (_patternPlaying) {
      _action('seq.play', detail: 'already playing');
      return;
    }
    if (_pattern.isEmpty) {
      showToast('The pattern is empty - click some steps first.');
      notifyListeners();
      return;
    }
    if (pads.every((p) => p.isEmpty)) {
      showToast('Fill some pads first.');
      notifyListeners();
      return;
    }
    _action(
      'seq.play.begin',
      detail:
          'bars=${_pattern.bars} bpm=${_pattern.bpm.toStringAsFixed(1)}',
    );
    await _renderPattern(start: true);
    notifyListeners();
  }

  void stopPattern() {
    _patternRerender?.cancel();
    try {
      engine.stopVoice(AppConfig.sequencerVoiceId);
    } catch (_) {}
    _patternPlaying = false;
    _action('seq.stop');
    notifyListeners();
  }

  // -------------------------------------------------------- Phase D: undo

  /// Set pad [index] pitch in semitones (-12..+12). Any setting change
  /// that affects playback stops the pad first (rate is applied at the
  /// next trigger/preview).
  void setPadPitch(int index, int semitones) {
    final pad = pads[index];
    if (pad.isEmpty) return;
    final clamped = clampPadPitch(semitones);
    if (pad.pitchSemitones == clamped) return;
    _stopPadNow(index);
    pad.pitchSemitones = clamped;
    _action(
      'setPadPitch',
      detail:
          'pad ${index + 1} -> $clamped st '
          '(rate ${pad.playRate.toStringAsFixed(4)})',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Set pad [index] reverse playback. Stops the pad before applying.
  void setPadReverse(int index, bool value) {
    final pad = pads[index];
    if (pad.isEmpty) return;
    if (pad.reverse == value) return;
    _stopPadNow(index);
    pad.reverse = value;
    _action(
      'setPadReverse',
      detail: 'pad ${index + 1} -> reverse=$value (stopped first)',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Set pad [index] gain (0%..200%). The gain is baked into the pad
  /// buffer with a hard clamp at [-1, 1], so 200% cannot clip inside the
  /// engine. Committed on slider release (stops + re-bakes + persists).
  void setPadGain(int index, double gain) {
    final pad = pads[index];
    if (pad.isEmpty) return;
    final g = clampPadGain(gain);
    if ((pad.gain - g).abs() < 0.001) return;
    _stopPadNow(index);
    pad.gain = g;
    final src = padSourceAudio(index);
    if (src != null) {
      applyPadBounds(
        pad,
        stemLeft: src.left,
        stemRight: src.right,
        sampleRate: src.sampleRate,
        startSample: pad.startSample,
        endSample: pad.endSample,
        fadeSamples: padFadeSamples(pad.fadeMs, src.sampleRate),
        gain: g,
      );
    }
    _action(
      'setPadGain',
      detail:
          'pad ${index + 1} -> gain=${g.toStringAsFixed(2)} '
          '(baked + clamped)',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Clear pad [index]: stop playback, drop source/slice/label and any
  /// custom sample reference. The UI confirms first when the pad has
  /// manually edited content. Phase D: snapshot for one-level undo.
  void clearPad(int index) {
    final pad = pads[index];
    if (pad.isEmpty) return;
    _snapshotPadForUndo(index);
    _stopPadNow(index);
    pad.clear();
    _customSamples.remove(index);
    _action('clearPad', detail: 'pad ${index + 1} cleared');
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Reset Slice: restore the pad's originally assigned range, bake the
  /// buffer again and preview once. Clears the manual-edit flag.
  void resetPadSlice(int index) {
    final pad = pads[index];
    final src = padSourceAudio(index);
    if (pad.isEmpty || src == null) return;
    _snapshotPadForUndo(index);
    _stopPadNow(index);
    applyPadBounds(
      pad,
      stemLeft: src.left,
      stemRight: src.right,
      sampleRate: src.sampleRate,
      startSample: pad.origStartSample,
      endSample: pad.origEndSample,
      fadeSamples: padFadeSamples(pad.fadeMs, src.sampleRate),
      gain: pad.gain,
    );
    pad.edited = false;
    _action(
      'resetPadSlice',
      detail:
          'pad ${index + 1} -> ${pad.startSample}..${pad.endSample} '
          '(original range, edited=false)',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
    previewPad(index);
  }

  // ---------------------------------------------------- Sampler Polish: pad

  /// Set pad [index] edge fade in ms (0..50). Stops the pad, clamps,
  /// re-bakes the slice with the new fade, marks the pad edited and
  /// previews once (one-shot).
  void setPadFade(int index, double fadeMs) {
    final pad = pads[index];
    if (pad.isEmpty) return;
    final v = clampPadFadeMs(fadeMs);
    if ((pad.fadeMs - v).abs() < 0.01) return;
    _stopPadNow(index);
    pad.fadeMs = v;
    final src = padSourceAudio(index);
    if (src != null) {
      applyPadBounds(
        pad,
        stemLeft: src.left,
        stemRight: src.right,
        sampleRate: src.sampleRate,
        startSample: pad.startSample,
        endSample: pad.endSample,
        fadeSamples: padFadeSamples(v, src.sampleRate),
        gain: pad.gain,
      );
    }
    pad.edited = true;
    _action(
      'setPadFade',
      detail:
          'pad ${index + 1} -> ${v.toStringAsFixed(0)}ms '
          '(re-baked, edited, previewing)',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
    previewPad(index);
  }

  /// Reset Sound: original bounds + pitch 0 + reverse off + gain 100% +
  /// fade 5 ms, re-bake, edited=false, preview once. (Reset Slice stays
  /// bounds-only.)
  void resetPadSound(int index) {
    final pad = pads[index];
    final src = padSourceAudio(index);
    if (pad.isEmpty || src == null) return;
    _snapshotPadForUndo(index);
    _stopPadNow(index);
    applyResetSoundDefaults(pad);
    applyPadBounds(
      pad,
      stemLeft: src.left,
      stemRight: src.right,
      sampleRate: src.sampleRate,
      startSample: pad.origStartSample,
      endSample: pad.origEndSample,
      fadeSamples: padFadeSamples(pad.fadeMs, src.sampleRate),
      gain: 1.0,
    );
    pad.edited = false;
    _action(
      'resetPadSound',
      detail:
          'pad ${index + 1} -> ${pad.startSample}..${pad.endSample} '
          'pitch=0 reverse=false gain=1.00 fade=5ms edited=false',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
    previewPad(index);
  }

  // ----------------------------------------------- Sampler Polish: recording

  int _recElapsedMs() {
    final start = _recStartAt;
    if (start == null) return 0;
    return DateTime.now().difference(start).inMilliseconds;
  }

  void _recordPadEvent(int index, String kind) {
    if (recState != RecState.recording) return;
    if (pads[index].isEmpty && kind == 'trigger') return;
    _recEvents.add(
      PadEvent(padIndex: index, kind: kind, timeMs: _recElapsedMs()),
    );
    _recSpecs[index] = PadRenderSpec.fromPad(pads[index]);
    _action(
      'rec.event',
      detail: '$kind pad ${index + 1} @ ${_recElapsedMs()}ms',
    );
  }

  void startRecording() {
    if (recState == RecState.recording) return;
    _recEvents.clear();
    _recSpecs.clear();
    _lastRender = null;
    _recStartAt = DateTime.now();
    recState = RecState.recording;
    _action('rec.start');
    notifyListeners();
  }

  Future<void> stopRecording() async {
    if (recState != RecState.recording) return;
    recState = RecState.stopped;
    _action('rec.stop', detail: '${_recEvents.length} events');
    RenderedPerformance r;
    try {
      r = await renderPerformanceInIsolate(
        _recEvents,
        _recSpecs,
        AppConfig.engineSampleRate,
      );
    } catch (e) {
      debugPrint('[BAKUSHI] performance render isolate failed: $e');
      r = renderPerformanceSync(
        _recEvents,
        _recSpecs,
        AppConfig.engineSampleRate,
      );
    }
    _lastRender = r;
    _action(
      'rec.done',
      detail:
          'events=${_recEvents.length} '
          'duration=${r.durationSeconds.toStringAsFixed(2)}s '
          'sr=${r.sampleRate} peak=${r.peak.toStringAsFixed(3)}',
    );
    if (r.left.isNotEmpty && activeLibraryId != null) {
      await _persistPerformance(r);
    } else {
      showToast(
        r.left.isEmpty
            ? 'Recording was empty.'
            : 'Recording rendered. Save the song to persist it.',
      );
    }
    notifyListeners();
  }

  /// Persist the rendered performance (D1): WAV + JSON metadata into
  /// `library/<slug>/performances/`. Returns the WAV path.
  Future<String?> _persistPerformance(RenderedPerformance r) async {
    final id = activeLibraryId;
    if (id == null) return null;
    final wav = encodeWavPcm16(r.left, r.right, r.sampleRate);
    final meta = {
      'name': 'Performance',
      'createdAt': DateTime.now().toIso8601String(),
      'durationSeconds': r.durationSeconds,
      'sampleRate': AppConfig.engineSampleRate,
      'channels': 2,
      'peak': r.peak,
      'eventCount': _recEvents.length,
      'sourceSong': fileName ?? id,
    };
    final path = await library.savePerformance(id, wav, meta);
    performanceList = await library.listPerformances(id);
    _action('perf.saved', detail: 'path=$path');
    showToast('Performance saved (${r.durationSeconds.toStringAsFixed(1)} s).');
    return path;
  }

  void previewPerformance() {
    final r = _lastRender;
    if (r == null || r.left.isEmpty) {
      showToast('No recording to preview.');
      return;
    }
    engine.loadVoice(AppConfig.recordingPreviewVoiceId, r.left, r.right);
    engine.playVoice(AppConfig.recordingPreviewVoiceId);
    _action('perf.preview', detail: '${r.durationSeconds.toStringAsFixed(2)}s');
  }

  void stopPerformancePreview() =>
      engine.stopVoice(AppConfig.recordingPreviewVoiceId);

  Future<void> exportPerformance() async {
    final r = _lastRender;
    if (r == null || r.left.isEmpty) {
      showToast('No recording to export.');
      return;
    }
    final loc = await getSaveLocation(
      suggestedName: 'performance.wav',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'WAV audio', extensions: ['wav']),
      ],
    );
    var path = loc?.path;
    if (path == null) return;
    if (p.extension(path).isEmpty) path = '$path.wav';
    await _writePerformanceWav(r, path);
    _action('perf.export', detail: 'path=$path');
    showToast('Exported performance to $path');
  }

  /// Headless export (autotest).
  Future<void> exportPerformanceTo(String path) async {
    final r = _lastRender;
    if (r == null || r.left.isEmpty) return;
    await _writePerformanceWav(r, path);
    _action('perf.export', detail: 'path=$path');
  }

  Future<void> _writePerformanceWav(RenderedPerformance r, String path) {
    return File(
      path,
    ).writeAsBytes(encodeWavPcm16(r.left, r.right, r.sampleRate), flush: true);
  }

  void discardPerformance() {
    recState = RecState.ready;
    _recEvents.clear();
    _recSpecs.clear();
    _lastRender = null;
    engine.stopVoice(AppConfig.recordingPreviewVoiceId);
    _action('rec.discard');
    notifyListeners();
  }

  /// Preview a SAVED performance file (list UI).
  void previewPerformanceFile(String wavPath) {
    try {
      final w = readWav(File(wavPath).readAsBytesSync());
      engine.loadVoice(AppConfig.recordingPreviewVoiceId, w.left, w.right);
      engine.playVoice(AppConfig.recordingPreviewVoiceId);
      _action('perf.previewFile', detail: wavPath);
    } catch (e) {
      showToast('Could not preview performance: $e');
    }
  }

  Future<void> exportPerformanceFile(String wavPath) async {
    final name = wavPath.split(Platform.pathSeparator).last;
    final loc = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'WAV audio', extensions: ['wav']),
      ],
    );
    var dest = loc?.path;
    if (dest == null) return;
    if (p.extension(dest).isEmpty) dest = '$dest.wav';
    await File(wavPath).copy(dest);
    showToast('Exported $dest');
  }

  Future<void> deletePerformanceFile(String wavPath) async {
    final id = activeLibraryId;
    if (id == null) return;
    await library.deletePerformance(id, wavPath);
    performanceList = await library.listPerformances(id);
    _action('perf.delete', detail: wavPath);
    notifyListeners();
  }

  // ------------------------------------------- Sampler Polish: played export

  /// Export Played Pad (D2): PROCESSED render through the pad's full
  /// settings (bounds, pitch, reverse, gain, fades) - what you hear is
  /// what you export. No raw-slice option.
  Future<void> exportPlayedPad(int index) async {
    final pad = pads[index];
    if (pad.isEmpty) {
      showToast('Pad is empty.');
      return;
    }
    final loc = await getSaveLocation(
      suggestedName: 'pad_${index + 1}_played.wav',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'WAV audio', extensions: ['wav']),
      ],
    );
    var path = loc?.path;
    if (path == null) return;
    if (p.extension(path).isEmpty) path = '$path.wav';
    await exportPlayedPadTo(index, path);
    showToast(
      'Exported Pad ${index + 1} with processed settings '
      '(pitch ${pad.pitchSemitones > 0 ? '+' : ''}${pad.pitchSemitones} st, '
      'reverse ${pad.reverse ? 'on' : 'off'}, '
      'gain ${(pad.gain * 100).round()}%, '
      'fade ${pad.fadeMs.toStringAsFixed(0)} ms).',
    );
  }

  /// Headless played-pad export (autotest).
  Future<void> exportPlayedPadTo(int index, String path) async {
    final pad = pads[index];
    if (pad.isEmpty) return;
    final r = renderSinglePad(pad, sampleRate: AppConfig.engineSampleRate);
    await File(
      path,
    ).writeAsBytes(encodeWavPcm16(r.left, r.right, r.sampleRate), flush: true);
    _action(
      'pad.exportPlayed',
      detail:
          'pad ${index + 1} -> $path '
          'pitch=${pad.pitchSemitones} reverse=${pad.reverse} '
          'gain=${pad.gain.toStringAsFixed(2)} '
          'fade=${pad.fadeMs.toStringAsFixed(0)}ms '
          'peak=${r.peak.toStringAsFixed(3)} '
          'duration=${r.durationSeconds.toStringAsFixed(3)}s',
    );
  }

  // ----------------------------------------------- Task 4B: original chops

  /// True when at least one pad has a source (drives the step-3 advance
  /// for pads-only sessions).
  bool get anyPadNonEmpty => pads.any((p) => !p.isEmpty);

  String originalSongTitle() => fileName ?? 'Original Song';

  void startChopEditor() {
    if (original == null) {
      showToast('Load a song first.');
      return;
    }
    chopEditorOpen = true;
    editingPadIndex = null;
    _action('chopEditor.open', detail: fileName ?? '');
    notifyListeners();
  }

  void endChopEditor() {
    chopEditorOpen = false;
    _action('chopEditor.close');
    notifyListeners();
  }

  /// Bake a chop of the ORIGINAL full mix into pad [index]. Pads hold
  /// bounds + a baked slice only - the source stays the ONE shared
  /// immutable original PCM (no duplication). No separation/BPM/transient
  /// calls in this path.
  void assignChopToPad(int index, int startSample, int endSample) {
    final o = original;
    if (o == null || index < 0 || index > 15) return;
    final s = math.max(0, startSample);
    final e = math.min(endSample, o.frames);
    final minLen = minSliceSamples(o.sampleRate);
    if (e - s < minLen) {
      showToast('Selection is too short (min 20 ms).');
      return;
    }
    final pad = pads[index];
    _snapshotPadForUndo(index);
    _stopPadNow(index);
    applyChopToPad(
      pad,
      stemLeft: o.left,
      stemRight: o.right,
      sampleRate: o.sampleRate,
      start: s,
      end: e,
      label: 'Original · ${originalSongTitle()}',
    );
    _action(
      'chop.assign',
      detail:
          'pad ${index + 1} $s..$e '
          '(${(s / o.sampleRate).toStringAsFixed(2)}s..'
          '${(e / o.sampleRate).toStringAsFixed(2)}s) '
          '${pad.loop ? 'LOOP' : 'HIT'} fade=${pad.fadeMs.toStringAsFixed(0)}ms',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Assign to the selected pad (fallback: next empty pad + toast).
  /// Returns the pad index, or null when every pad is filled.
  int? assignChopToSelected(int start, int end) {
    final sel = selectedPadIndex;
    if (sel != null) {
      assignChopToPad(sel, start, end);
      return sel;
    }
    final empty = firstEmptyPad(pads);
    if (empty != null) {
      assignChopToPad(empty, start, end);
      showToast('No pad selected - assigned to Pad ${empty + 1}.');
      return empty;
    }
    showToast('All pads are filled. Choose a pad to replace.');
    return null;
  }

  /// Assign to the next EMPTY pad - never overwrites. The chop editor
  /// stays open. Returns the pad index, or null when none is empty.
  int? assignChopToNextEmpty(int start, int end) {
    final empty = firstEmptyPad(pads);
    if (empty == null) {
      showToast('No empty pads available.');
      return null;
    }
    assignChopToPad(empty, start, end);
    showToast('Assigned original chop to Pad ${empty + 1}.');
    return empty;
  }

  /// Load the optional starter kit into EMPTY pads only. Shows the setup
  /// message when no licensed assets are installed; never overwrites
  /// existing stem/custom pads. Phase C: tempo-matched loops default to
  /// LOOP mode; one-shots default to HIT.
  Future<void> loadStarterKit() async {
    _action('starterKit.begin');
    final sounds = availableStarterSounds();
    if (sounds.isEmpty) {
      _action('starterKit.missing', detail: starterKitSetupMessage);
      showToast(starterKitSetupMessage);
      notifyListeners();
      return;
    }
    final names = [
      for (final n in starterKitNames)
        if (sounds.containsKey(n)) n,
    ];
    await _fillStarterPads(sounds, names);
  }

  /// Phase C (optional nicety): randomly fill EMPTY pads from the kit.
  Future<void> shuffleStarterKit() async {
    _action('starterKit.shuffle.begin');
    final sounds = availableStarterSounds();
    if (sounds.isEmpty) {
      showToast(starterKitSetupMessage);
      notifyListeners();
      return;
    }
    final names = [
      for (final n in starterKitNames)
        if (sounds.containsKey(n)) n,
    ]..shuffle(math.Random());
    await _fillStarterPads(sounds, names);
    _action('starterKit.shuffle.done');
  }

  /// Shared fill path: assign [names] to empty pads in order, never
  /// overwriting non-empty pads (fill-EMPTY-only rule).
  Future<void> _fillStarterPads(
    Map<String, String> sounds,
    List<String> names,
  ) async {
    final assignments = starterKitAssignments(pads, names);
    if (assignments.isEmpty) {
      _action('starterKit.noEmpty', detail: 'No empty pads available.');
      showToast('No empty pads available.');
      notifyListeners();
      return;
    }
    var loaded = 0;
    for (final a in assignments) {
      try {
        var sound = loadStarterSound(a.name);
        if (sound.sampleRate != AppConfig.engineSampleRate) {
          // Non-44.1k assets go through the PyAV decoder (resampled).
          final decoded = await decoder.decode(sounds[a.name]!);
          sound = StarterSound(
            name: a.name,
            left: decoded.left,
            right: decoded.right,
            sampleRate: decoded.sampleRate,
          );
        }
        final pad = pads[a.padIndex];
        pad.clear();
        final fade = padFadeSamples(
          AppConfig.padFadeMsDefault,
          sound.sampleRate,
        );
        final isLoop = starterSoundIsLoop(a.name);
        pad
          ..starter = true
          ..starterName = a.name
          ..startSample = 0
          ..endSample = sound.frames
          ..sampleRate = sound.sampleRate
          ..leftChannel = createSliceBuffer(sound.left, 0, sound.frames, fade)
          ..rightChannel = createSliceBuffer(sound.right, 0, sound.frames, fade)
          ..label = starterKitLabel(a.name)
          ..loop =
              isLoop // loops play as loops, one-shots as HIT
          ..origStartSample = 0
          ..origEndSample = sound.frames;
        loaded++;
        _action(
          'starterKit.fill',
          detail:
              'pad ${a.padIndex + 1} <- ${a.name} '
              '(${sound.frames} frames, '
              '${pad.loop ? 'LOOP' : 'HIT'})',
        );
      } catch (e) {
        _action('starterKit.error', detail: '${a.name} failed: $e');
      }
    }
    showToast(
      loaded > 0
          ? 'Loaded $loaded starter sound(s) into empty pads.'
          : 'Starter kit load failed - see diagnostics.',
    );
    _scheduleLibrarySettingsSave();
    notifyListeners();
    _action('starterKit.done', detail: '$loaded sounds');
  }

  /// The full decoded source audio behind pad [index] - the separated
  /// stem, the custom uploaded sample, a starter-kit sound, or the
  /// ORIGINAL full mix for original chops (Task 4B, shared immutable
  /// PCM - no duplication).
  ({Float32List left, Float32List right, int sampleRate})? padSourceAudio(
    int index,
  ) {
    final pad = pads[index];
    final cs = _customSamples[index];
    if (pad.custom && cs != null) {
      return (left: cs.left, right: cs.right, sampleRate: cs.sampleRate);
    }
    if (pad.original) {
      final o = original;
      if (o != null) {
        return (left: o.left, right: o.right, sampleRate: o.sampleRate);
      }
      return null;
    }
    if (pad.starter && pad.starterName != null) {
      try {
        final sound = loadStarterSound(pad.starterName!);
        return (
          left: sound.left,
          right: sound.right,
          sampleRate: sound.sampleRate,
        );
      } catch (_) {
        return null;
      }
    }
    final stem = stems[pad.stemName ?? ''];
    if (stem == null) return null;
    return (left: stem.left, right: stem.right, sampleRate: stem.sampleRate);
  }

  /// Task 3: apply new slice bounds to pad [index] live (drag handles).
  void updatePadBounds(int index, int startSample, int endSample) {
    final pad = pads[index];
    final src = padSourceAudio(index);
    if (pad.isEmpty || src == null) return;
    applyPadBounds(
      pad,
      stemLeft: src.left,
      stemRight: src.right,
      sampleRate: src.sampleRate,
      startSample: startSample,
      endSample: endSample,
      fadeSamples: padFadeSamples(pad.fadeMs, src.sampleRate),
      gain: pad.gain,
    );
    pad.edited = true; // manually edited in the slice editor
    _action(
      'updatePadBounds',
      detail: 'pad ${index + 1}: ${pad.startSample}..${pad.endSample}',
      quiet: true,
    );
    notifyListeners();
  }

  /// Task 3: preview a pad once (one-shot), used when a slice drag ends.
  /// Phase C: the preview uses the pad's current pitch/reverse/gain, but
  /// NEVER loops - not even when the pad is LOOP.
  void previewPad(int index) {
    final pad = pads[index];
    if (pad.isEmpty) return;
    final spec = PadPlaySpec.fromPad(pad, preview: true);
    _action(
      'previewPad',
      detail:
          'pad ${index + 1} ${pad.startSample}..${pad.endSample} '
          '(one-shot preview, rate=${spec.pitch.toStringAsFixed(4)}, '
          'reverse=${spec.reverse})',
    );
    try {
      engine.stopPad(index);
      engine.loadPad(index, pad.leftChannel!, pad.rightChannel!);
      engine.playPad(
        index,
        loop: spec.loop,
        pitch: spec.pitch,
        reverse: spec.reverse,
      );
    } catch (e) {
      debugPrint('[BAKUSHI] pad preview error: $e');
    }
  }

  /// Task 3: open the slice editor for pad [index]. Phase D: the pre-
  /// edit state is snapshotted once so Undo restores the old bounds.
  void startPadEdit(int index) {
    if (pads[index].isEmpty) return;
    _snapshotPadForUndo(index);
    editingPadIndex = index;
    final pad = pads[index];
    final src = padSourceAudio(index);
    final sr = src?.sampleRate ?? pad.sampleRate;
    final frames = src == null
        ? 0
        : math.min(src.left.length, src.right.length);
    var maxAbs = 0.0;
    if (src != null) {
      for (var i = 0; i < frames; i++) {
        final l = src.left[i].abs();
        final r = src.right[i].abs();
        if (l > maxAbs) maxAbs = l;
        if (r > maxAbs) maxAbs = r;
      }
    }
    final srcName = pad.custom
        ? (pad.customSourcePath ?? '').split(Platform.pathSeparator).last
        : pad.stemName;
    _action(
      'padEdit.diag',
      detail:
          'Pad ${index + 1} '
          'Source: ${pad.custom ? 'custom ($srcName)' : pad.stemName} '
          'Source samples: $frames '
          'Source duration: ${(frames / sr).toStringAsFixed(3)}s '
          'Source max amplitude: ${maxAbs.toStringAsFixed(3)} '
          'Slice: ${(pad.startSample / sr).toStringAsFixed(3)}s-'
          '${(pad.endSample / sr).toStringAsFixed(3)}s '
          '(${pad.startSample}..${pad.endSample})',
    );
    _action('startPadEdit', detail: 'pad ${index + 1}');
    notifyListeners();
  }

  /// Task 3: close the slice editor, back to the grid.
  void endPadEdit() {
    editingPadIndex = null;
    _action('endPadEdit');
    notifyListeners();
  }

  // ---------------------------------------------------------- custom samples

  /// Task 2 (Phase B): user picks WAV/MP3/OGG/M4A and it becomes pad
  /// [index]'s source. Decoded, BPM-detected if possible, best-energy
  /// 2-bar slice (or the whole sample), label 'Custom'.
  Future<void> uploadSampleToPad(int index) async {
    _action('uploadSample.pickBegin', detail: 'pad ${index + 1}');
    try {
      final f = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Audio', extensions: ['wav', 'mp3', 'ogg', 'm4a']),
        ],
      );
      if (f == null) {
        _action('uploadSample.pickCancelled');
        return;
      }
      await assignCustomSampleToPad(index, f.path);
    } catch (e) {
      log('Sample upload failed: $e', error: true);
      showToast('Sample upload failed: $e');
    }
  }

  /// Decode + attach a custom sample file to pad [index]. [bpm] skips
  /// the sidecar BPM detection (used when restoring from the library).
  Future<void> assignCustomSampleToPad(
    int index,
    String filePath, {
    double? bpm,
    bool quiet = false,
  }) async {
    if (busy) {
      showToast('Wait for the current task to finish.');
      return;
    }
    if (!quiet) {
      _action('uploadSample.begin', detail: 'pad ${index + 1} <- $filePath');
      _snapshotPadForUndo(index);
    }
    await _ensureSidecar();
    final audio = await decoder.decode(filePath);
    final stored = await _storeCustomSampleFile(filePath);
    double? sampleBpm = bpm;
    if (sampleBpm == null) {
      try {
        final l =
            '${workDir.path}${Platform.pathSeparator}custom${index}_l.f32le';
        final r =
            '${workDir.path}${Platform.pathSeparator}custom${index}_r.f32le';
        await writeF32Le(l, audio.left);
        await writeF32Le(r, audio.right);
        final res = await sidecar.request('beat_analyze', {
          'stems': {
            'drums': {'left': l, 'right': r},
          },
        }, timeout: const Duration(minutes: 6));
        final v = (res['bpm'] as num?)?.toDouble();
        if (v != null && v > 0) sampleBpm = v;
        _action(
          'uploadSample.bpm',
          detail:
              'pad ${index + 1} '
              'bpm=${sampleBpm?.toStringAsFixed(1) ?? 'none (long sample)'}',
        );
      } catch (e) {
        _action(
          'uploadSample.bpm',
          detail: 'pad ${index + 1} bpm failed: $e (long sample)',
        );
      }
    }
    final sr = audio.sampleRate;
    var start = 0;
    var end = audio.frames;
    if (sampleBpm != null && sampleBpm > 0) {
      // Best-energy 2-bar segment (1-bar if the sample is short).
      final barSamples = (4 * 60.0 / sampleBpm * sr).round().clamp(
        1,
        audio.frames,
      );
      final twoBarSamples = barSamples * 2;
      final useBar = audio.frames < 2 * twoBarSamples;
      final segs = computePadSegments(
        bpm: sampleBpm,
        sampleRate: sr,
        totalFrames: audio.frames,
        division: useBar ? Division.bar : Division.twoBars,
        maxSegments: 1 << 30,
      );
      var bestRms = -1.0;
      for (final seg in segs) {
        final rms = segmentRms(
          audio.left,
          audio.right,
          seg.startSample,
          seg.endSample,
        );
        if (rms > bestRms) {
          bestRms = rms;
          start = seg.startSample;
          end = seg.endSample;
        }
      }
    }
    _customSamples[index] = _CustomSample(
      left: audio.left,
      right: audio.right,
      sampleRate: sr,
      sourcePath: stored,
      bpm: sampleBpm,
    );
    final pad = pads[index];
    // Phase C: preserve mode/pitch/reverse/gain when replacing an
    // existing pad; a fresh upload defaults to LOOP, neutral settings.
    // Sampler Polish: label carries the file name, fade is preserved.
    final wasEmpty = pad.isEmpty;
    final keepLoop = wasEmpty ? true : pad.loop;
    final keepGain = clampPadGain(pad.gain);
    final keepFade = clampPadFadeMs(
      wasEmpty ? AppConfig.padFadeMsDefault : pad.fadeMs,
    );
    final fadeSamples = padFadeSamples(keepFade, sr);
    engine.stopPad(index);
    pad
      ..stemName = 'custom'
      ..startSample = start
      ..endSample = end
      ..sampleRate = sr
      ..leftChannel = createSliceBuffer(
        audio.left,
        start,
        end,
        fadeSamples,
        gain: keepGain,
      )
      ..rightChannel = createSliceBuffer(
        audio.right,
        start,
        end,
        fadeSamples,
        gain: keepGain,
      )
      ..label = Pad.customLabel(stored)
      ..loop = keepLoop
      ..fadeMs = keepFade
      ..custom = true
      ..customSourcePath = stored
      ..customBpm = sampleBpm
      ..origStartSample = start
      ..origEndSample = end;
    if (!quiet) {
      _action(
        'uploadSample.done',
        detail:
            'pad ${index + 1} custom src=$stored '
            '${(start / sr).toStringAsFixed(3)}s..'
            '${(end / sr).toStringAsFixed(3)}s '
            '${pad.loop ? 'LOOP' : 'HIT'} pitch=${pad.pitchSemitones} '
            'reverse=${pad.reverse} '
            'gain=${pad.gain.toStringAsFixed(2)} '
            '(bpm ${sampleBpm?.toStringAsFixed(1) ?? 'none'})',
      );
      showToast('Pad ${index + 1}: custom sample loaded.');
    }
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Copy the picked file into the app-support custom_samples folder so
  /// it survives library re-saves (the library dir is rebuilt on save).
  Future<String> _storeCustomSampleFile(String sourcePath) async {
    final name = sourcePath.split(Platform.pathSeparator).last;
    final dir = Directory(
      '${library.root.parent.path}'
      '${Platform.pathSeparator}custom_samples',
    );
    await dir.create(recursive: true);
    final dest = '${dir.path}${Platform.pathSeparator}$name';
    await File(sourcePath).copy(dest);
    return dest;
  }

  /// Restore custom samples saved in the library settings (state.json).
  Future<void> _restoreCustomSamples(Map settings) async {
    final m = settings['customSamples'];
    if (m is! Map) return;
    for (final entry in m.entries) {
      final idx = int.tryParse('${entry.key}');
      final info = entry.value is Map ? entry.value as Map : null;
      final path = info?['path'] as String?;
      if (idx == null || path == null) continue;
      if (!File(path).existsSync()) {
        _action(
          'uploadSample.restore',
          detail: 'pad ${idx + 1} file missing: $path',
        );
        continue;
      }
      try {
        final bpm = (info?['bpm'] as num?)?.toDouble();
        await assignCustomSampleToPad(idx, path, bpm: bpm, quiet: true);
        _action(
          'uploadSample.restore',
          detail: 'pad ${idx + 1} restored from $path',
        );
      } catch (e) {
        _action(
          'uploadSample.restore',
          detail: 'pad ${idx + 1} restore failed: $e',
        );
      }
    }
  }

  /// Whether pad [index] is currently sounding (polled).
  bool padPlaying(int index) => _padPlayStates[index];

  /// True while at least one pad is sounding.
  bool get anyPadPlaying => _padPlayStates.any((p) => p);

  /// The pad bound to keyboard key [key], if any.
  int? padForKey(String key) {
    for (final e in padKeys.entries) {
      if (e.value == key) return e.key;
    }
    return null;
  }

  /// Reassign pad [index] to [key]. If another pad already uses [key]
  /// the two assignments SWAP (clear message via toast).
  void assignPadKey(int index, String key) {
    if (!AppConfig.padAutoKeyOrder.contains(key)) {
      _action('padKey.reject', detail: 'pad ${index + 1} $key not allowed');
      return;
    }
    final other = padForKey(key);
    if (other != null && other != index) {
      final oldKey = padKeys[index];
      padKeys[index] = key;
      if (oldKey != null) {
        padKeys[other] = oldKey;
      } else {
        padKeys.remove(other);
      }
      _action(
        'padKey.swap',
        detail: 'pad ${index + 1}=$key, pad ${other + 1}=$oldKey',
      );
      showToast(
        'Swapped: pad ${index + 1} -> $key, '
        'pad ${other + 1} -> ${oldKey ?? 'none'}.',
      );
    } else {
      padKeys[index] = key;
      _action('padKey', detail: 'pad ${index + 1}=$key');
    }
    _scheduleLibrarySettingsSave();
    notifyListeners();
  }

  /// Keycap tap: enter reassignment mode for pad [index]. The next
  /// allowed key press (or Esc) finishes it.
  void startKeyAssign(int index) {
    assigningKeyPad = index;
    _action('startKeyAssign', detail: 'pad ${index + 1}');
    showToast(
      'Pad ${index + 1}: press a key '
      '(${AppConfig.padAutoKeyOrder.join(' ')}), Esc cancels.',
    );
    notifyListeners();
  }

  void cancelKeyAssign() {
    if (assigningKeyPad != null) {
      _action('cancelKeyAssign');
      assigningKeyPad = null;
      notifyListeners();
    }
  }

  void finishKeyAssign(String key) {
    final idx = assigningKeyPad;
    assigningKeyPad = null;
    if (idx == null) return;
    assignPadKey(idx, key);
  }

  /// Lightweight poll: 16 cheap FFI calls every 150 ms so pad tiles can
  /// light up while sounding (the C engine does not notify Dart when a
  /// one-shot hit ends by itself).
  void _startPadPlayMonitor() {
    _padPlayTimer?.cancel();
    _padPlayTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!engineOk) return;
      var changed = false;
      for (var i = 0; i < 16; i++) {
        final playing = !pads[i].isEmpty && engine.isPadPlaying(i);
        if (playing != _padPlayStates[i]) {
          _padPlayStates[i] = playing;
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });
  }

  // ============================================================== separation

  Future<void> chooseModelFile() async {
    _action('chooseModelFile.begin');
    try {
      final f = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'ONNX model', extensions: ['onnx']),
        ],
      );
      final path = f?.path;
      if (path == null) {
        _action('chooseModelFile.cancelled');
        log('Model selection cancelled.');
        return;
      }
      ModelLocator.userPath = path;
      await ModelLocator.persistUserPath(path);
      resolvedModelPath = path;
      modelStatus = 'ready';
      _action('chooseModelFile.done', detail: path);
      log('Model set to: $path');
      notifyListeners();
    } catch (e) {
      log('Model picker failed: $e', error: true);
    }
  }

  /// Re-resolve the model files on disk (4-stem default + optional
  /// 6-stem).
  void refreshModelAvailability() {
    _qualityModelPath = ModelLocator.resolve();
    _sixStemPath = ModelLocator.resolveSixStem();
    sixStemAvailable = _sixStemPath != null;
    if (_qualityModelPath == null) {
      modelStatus = 'missing';
    } else if (modelStatus != 'loading' && modelStatus != 'error') {
      modelStatus = 'ready';
    }
  }

  /// Step 2 chooser: 4-stem (recommended) vs 6-stem (guitar + piano).
  void selectModelMode(SeparationMode m) {
    if (m == SeparationMode.sixStem && !sixStemAvailable) return;
    if (m == modelMode) return;
    modelMode = m;
    resolvedModelPath = null;
    _action('selectModelMode', detail: m.name);
    notifyListeners();
  }

  /// Step 2 chooser: pick the compute device (CPU or GPU/OpenVINO).
  void selectBackend(SeparationBackend b) {
    if (b == backendChoice) return;
    backendChoice = b;
    _action('selectBackend', detail: b.name);
    notifyListeners();
  }

  /// Providers the sidecar already knows fail the probe on this machine
  /// (used by Step 2 to warn before a GPU attempt).
  List<String> get knownFailedProviders =>
      ((sidecar.info?.providerState['failed'] as List?) ?? const [])
          .cast<String>();

  String? resolveModelPath() {
    resolvedModelPath = modelMode == SeparationMode.sixStem
        ? _sixStemPath
        : _qualityModelPath;
    if (resolvedModelPath == null) {
      modelStatus = 'missing';
      log('Model file not found.', error: true);
      log(ModelLocator.placementHint(), error: true);
    }
    return resolvedModelPath;
  }

  Future<void> separateStems() async {
    _action('separateStems.begin');
    final audio = original;
    if (audio == null) {
      log('Load an audio file before separating.', error: true);
      return;
    }
    final modelPath = resolveModelPath();
    if (modelPath == null) return;

    setStage(PipelineStage.separating, 'Preparing local AI engine ...');
    await _ensureSidecar();
    _action('separateStems.sidecarReady', detail: '${sidecar.running}');
    if (!sidecar.running) {
      setStage(PipelineStage.error, 'Sidecar unavailable. See diagnostics.');
      return;
    }

    setStage(PipelineStage.separating, 'Loading model ...');
    cancelRequested = false;
    modelStatus = 'loading';
    _separationStartedAt = DateTime.now();
    log(
      'Starting separation with model: $modelPath '
      '(device: ${backendChoice.name})',
    );
    var lastProgressSeen = progress;
    final stallWatch = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!busy) return;
      if (progress <= lastProgressSeen) {
        debugPrint(
          '[BAKUSHI] inference progress unchanged for 60s - '
          'a chunk is taking unusually long (thermal throttling?). '
          'Still running.',
        );
      }
      lastProgressSeen = progress;
    });
    try {
      final result = await separation.separate(
        audio: audio,
        modelPath: modelPath,
        provider: backendChoice == SeparationBackend.gpu ? 'gpu' : 'cpu',
        drumPunch: drumPunch,
        onPunch: (r) {
          if (r['applied'] == true) {
            log(
              'Drum punch applied: RMS ${r['rms_before']} -> '
              '${r['rms_after']}, peak ${r['peak_before']} -> '
              '${r['peak_after']} (drums stem only).',
            );
          } else if (r['applied'] == false) {
            log(
              'Drum punch skipped: ${r['error'] ?? 'unavailable'}',
              error: true,
            );
          }
        },
        onProgress: (p) {
          progress = p.percent;
          final started = _separationStartedAt;
          final elapsed = started == null
              ? const Duration()
              : DateTime.now().difference(started);
          if (p.stage == 'loading' || p.stage.startsWith('probing-')) {
            // Model load phase: the sidecar reports which backend it is
            // testing so a slow first-load GPU probe never looks frozen.
            stageText = p.stage.startsWith('probing-')
                ? 'Testing ${p.stage.substring('probing-'.length)} backend ...'
                : 'Loading model ...';
            debugPrint('[BAKUSHI] ${p.stage}');
          } else {
            final avgSec = p.done > 0 ? elapsed.inSeconds / p.done : 0.0;
            final eta = p.done > 0
                ? Duration(seconds: (avgSec * (p.total - p.done)).round())
                : null;
            final etaText = eta == null
                ? ''
                : ' - ETA ${_fmtDuration(eta)} (avg ${avgSec.toStringAsFixed(1)}s/chunk)';
            stageText =
                'Separating: chunk ${p.done}/${p.total}'
                ' - elapsed ${_fmtDuration(elapsed)}$etaText';
            debugPrint(
              '[BAKUSHI] separate chunk ${p.done}/${p.total} '
              '${p.percent.toStringAsFixed(1)}%'
              ' - elapsed ${_fmtDuration(elapsed)}$etaText',
            );
          }
          notifyListeners();
        },
        onMeta: (e) {
          final d = (e['data'] as Map?)?.cast<String, dynamic>() ?? const {};
          backend = d['provider'] as String? ?? backend;
          modelStatus = 'loaded';
          _action(
            'separateStems.modelMeta',
            detail:
                '${d['input_name']} -> '
                '${(d['output_names'] as List? ?? const []).join(',')}',
            quiet: true,
          );
          log('Model loaded. Backend: $backend');
          log(
            'Input: ${d['input_name']} ${d['input_shape']} '
            'fp16=${d['input_fp16']}',
          );
          log(
            'Outputs: ${(d['output_names'] as List? ?? const []).join(', ')}',
          );
        },
        shouldCancel: () async => cancelRequested,
      );
      stems.clear();
      activeStemNames = result.meta.stemOrder.isEmpty
          ? List.of(AppConfig.stemNames)
          : List.of(result.meta.stemOrder);
      stemVolumes.clear();
      for (final n in activeStemNames) {
        stemVolumes[n] = 1.0;
      }
      mutedStems.removeWhere((n) => !activeStemNames.contains(n));
      if (soloStem != null && !activeStemNames.contains(soloStem)) {
        soloStem = null;
      }
      for (final stem in result.stems) {
        stems[stem.name] = stem;
        if (engineOk) {
          try {
            engine.loadStem(stem.name, stem.left, stem.right);
          } catch (e) {
            _action('loadStem.failed', detail: '${stem.name}: $e');
            log(
              'Stem ${stem.name} kept in memory but not loaded into the '
              'audio engine (low memory?): $e',
              error: true,
            );
          }
        }
        final silent = stem.isSilent ? ' (silent - hidden)' : '';
        _action(
          'stem.rms',
          detail:
              '${stem.name} RMS '
              '${stem.rms.toStringAsFixed(4)}, peak '
              '${stem.peak.toStringAsFixed(3)}, '
              '${stem.duration.toStringAsFixed(2)}s$silent',
        );
        log(
          'Stem ${stem.name}: RMS ${stem.rms.toStringAsFixed(4)}, '
          'peak ${stem.peak.toStringAsFixed(3)}, '
          '${stem.duration.toStringAsFixed(2)}s$silent',
          error: stem.isSilent,
        );
      }
      sepMeta = result.meta;
      backend = result.meta.provider;
      modelStatus = 'loaded';
      _separationStartedAt = null;
      stallWatch.cancel();
      setStage(PipelineStage.ready, '');
      progress = 0;
      notifyListeners();
      log('Separation complete in ${result.meta.chunks} chunk(s).');
      _action(
        'separateStems.done',
        detail: '${result.meta.chunks} chunks, backend=${result.meta.provider}',
      );
      // Release unused physical memory so the system stops paging. The
      // kernel call can block for a long while on a big working set, so it
      // runs off the UI thread (it affects the whole process anyway).
      unawaited(Isolate.run(NativeEngine.trimWorkingSet));
      // Fresh song: stop any transport and reset the pads before the new
      // stems appear.
      engine.stopTransport();
      engine.stopAllPads();
      for (final p in pads) {
        p.clear();
      }
      _resetPadKeys();
      detectedBpm = null;
      detectedBeats = [];
      detectedDownbeats = [];
      detectedOnsets = [];
      editingPadIndex = null;
      selectedPadIndex = null;
      _customSamples.clear();
      _clearPadUndo();
      notifyListeners();
      // Auto-save the separated song into the local library (after a short
      // pause so the UI settles first).
      unawaited(
        Future<void>.delayed(const Duration(seconds: 3))
            .then((_) => saveCurrentToLibrary(silent: true)),
      );
      log('Stems ready - play each layer or the full mix below.');
      // New requirement: pads auto-fill immediately after separation.
      // No stem selector, no division dropdown, no fill button.
      unawaited(autoFillPads());
    } catch (e) {
      stallWatch.cancel();
      final msg = '$e';
      final short = msg.length > 180 ? msg.substring(0, 180) : msg;
      setStage(PipelineStage.error, 'Separation failed: $short');
      modelStatus = 'error';
      log('$e', error: true);
      showToast('Separation failed: $short');
    }
  }

  void cancel() {
    _action('cancel');
    cancelRequested = true;
    log('Cancelling ...');
    unawaited(sidecar.cancel());
    notifyListeners();
  }

  /// Toggle the drum punch DSP chain. Before separation it only flips the
  /// flag (applied at separation); after separation it re-processes the
  /// drums stem live for A/B listening (backup kept by the sidecar).
  Future<void> setDrumPunch(bool v) async {
    if (drumPunch == v) return;
    drumPunch = v;
    _action('setDrumPunch', detail: '$v');
    notifyListeners();
    final lPath = '${workDir.path}${Platform.pathSeparator}drums_l.f32le';
    final rPath = '${workDir.path}${Platform.pathSeparator}drums_r.f32le';
    final stem = stems['drums'];
    if (stem == null || !File(lPath).existsSync()) {
      log('Drum punch ${v ? 'ON' : 'OFF'} - applies at the next separation.');
      return;
    }
    try {
      await _ensureSidecar();
      final res = await sidecar.request('drum_punch', {
        'left_path': lPath,
        'right_path': rPath,
        'enabled': v,
      }, timeout: const Duration(minutes: 4));
      final left = await readF32Le(lPath);
      final right = await readF32Le(rPath);
      final mono = monoDownmix(left, right);
      stems['drums'] = StemAudio(
        name: 'drums',
        left: left,
        right: right,
        sampleRate: stem.sampleRate,
        rms: calculateRMS(mono),
        peak: calculatePeak(mono),
        duration: left.length / stem.sampleRate,
      );
      engine.unloadStem('drums');
      if (engineOk) engine.loadStem('drums', left, right);
      if (res['applied'] == true) {
        log(
          'Drum punch ON: RMS ${res['rms_before']} -> ${res['rms_after']}, '
          'peak ${res['peak_before']} -> ${res['peak_after']}.',
        );
      } else if (res['restored'] == true) {
        log(
          'Drum punch OFF: original drums restored '
          '(RMS ${res['rms_after']}, peak ${res['peak_after']}).',
        );
      } else {
        log(
          'Drum punch ${v ? 'ON' : 'OFF'} (no stored original to '
          '${v ? 'back up' : 'restore'}).',
        );
      }
      log('Drums refreshed - replay them to hear the change.');
      notifyListeners();
    } catch (e, st) {
      debugPrint('[BAKUSHI] setDrumPunch failed: $e\n$st');
      log('Drum punch toggle failed: $e', error: true);
    }
  }

  // ================================================================= exports

  Future<void> exportStem(String name) async {
    _action('exportStem', detail: name);
    final stem = stems[name];
    if (stem == null) return;
    final bytes = exporter.encodeStemWav(stem);
    await _saveWav('${name}_stem.wav', bytes);
    log('Exported stem "$name".');
  }

  /// Export every stem into one user-chosen folder.
  Future<void> exportAllStems() async {
    _action('exportAllStems.begin');
    if (stems.isEmpty) {
      showToast('No stems to export.');
      return;
    }
    try {
      final dir = await getDirectoryPath();
      if (dir == null) {
        _action('exportAllStems.cancelled');
        return;
      }
      for (final name in activeStemNames) {
        final stem = stems[name];
        if (stem == null) continue;
        await exporter.exportStem(stem, p.join(dir, '${name}_stem.wav'));
      }
      showToast('Exported ${stems.length} stem(s) to $dir');
      log('Exported all stems to $dir');
    } catch (e) {
      log('Export all failed: $e', error: true);
      showToast('Export failed: $e');
    }
  }

  Future<void> _saveWav(String suggested, Uint8List bytes) async {
    try {
      final loc = await getSaveLocation(
        suggestedName: suggested,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'WAV audio', extensions: ['wav']),
        ],
      );
      var path = loc?.path;
      if (path == null) {
        log('Export cancelled.');
        return;
      }
      if (p.extension(path).isEmpty) path = '$path.wav';
      await File(path).writeAsBytes(bytes, flush: true);
      log('Saved: $path');
    } catch (e) {
      log('Export failed: $e', error: true);
      showToast('Export failed: $e');
    }
  }

  // ================================================================= library

  /// Save the current song (original + stems + mixer) into the local
  /// library. [silent] is used by the automatic post-separation save.
  Future<void> saveCurrentToLibrary({bool silent = false}) async {
    final o = original;
    if (o == null) {
      log('Load audio before saving to the library.', error: true);
      return;
    }
    _action('library.save.begin', detail: fileName);
    if (!silent) setStage(PipelineStage.decoding, 'Saving to library ...');
    try {
      final id = await library.saveSong(
        name: fileName ?? 'song',
        sourcePath: filePath ?? '',
        sampleRate: o.sampleRate,
        origLeft: o.left,
        origRight: o.right,
        stems: stems,
        settings: _librarySettings(),
      );
      activeLibraryId = id;
      librarySongs = await library.list();
      if (!silent) setStage(PipelineStage.ready, '');
      _action(
        'library.save.done',
        detail: '$id (${librarySongs.length} songs total)',
      );
      log('Saved to library: ${fileName ?? id}');
      // Off the UI thread - see the comment in separateStems above.
      unawaited(Isolate.run(NativeEngine.trimWorkingSet));
      notifyListeners();
    } catch (e) {
      if (!silent) setStage(PipelineStage.error, 'Library save failed');
      log('Library save failed: $e', error: true);
    }
  }

  Future<void> loadFromLibrary(String id) async {
    _action('library.load.begin', detail: id);
    setStage(PipelineStage.decoding, 'Loading library song ...');
    try {
      final data = await library.loadSong(id);
      _action(
        'library.load.decoded',
        detail: '${data.entry.name}, ${data.stems.length} stems',
      );
      engine.stopTransport();
      for (final n in stems.keys) {
        engine.unloadStem(n);
      }
      final o = StereoAudio(
        left: data.origLeft,
        right: data.origRight,
        sampleRate: data.entry.sampleRate,
        duration: data.entry.durationSec,
      );
      original = o;
      if (engineOk) engine.loadOriginal(o.left, o.right);
      filePath = data.entry.sourcePath.isEmpty ? null : data.entry.sourcePath;
      fileName = data.entry.name;
      fileSizeBytes = data.entry.sizeBytes;
      stems.clear();
      for (final stem in data.stems.values) {
        stems[stem.name] = stem;
        if (engineOk) engine.loadStem(stem.name, stem.left, stem.right);
        _action(
          'stem.rms',
          detail:
              '${stem.name} RMS '
              '${stem.rms.toStringAsFixed(4)}${stem.isSilent ? ' (silent - hidden)' : ''}',
        );
      }
      _applyLibrarySettings(data.settings);
      _customSamples.clear();
      activeLibraryId = id;
      sepMeta = null;
      modelStatus = 'loaded';
      setStage(PipelineStage.ready, '');
      progress = 0;
      notifyListeners();
      _action('library.load.done', detail: data.entry.name);
      log('Loaded from library: ${data.entry.name}');
      // Phase C: when the library has a persisted pads block, restore the
      // pads exactly (bounds/loop/pitch/reverse/gain/labels survive the
      // reload). Old libraries fall back to the auto-fill behavior.
      // Sampler Polish: performances are listed alongside.
      unawaited(() async {
        await _restoreLibraryPads(data.settings);
        try {
          performanceList = await library.listPerformances(id);
          _action(
            'perf.list',
            detail: '${performanceList.length} performance(s)',
          );
        } catch (e) {
          _action('perf.list', detail: 'failed: $e');
        }
      }());
    } catch (e) {
      setStage(PipelineStage.error, 'Library load failed');
      log('Library load failed: $e', error: true);
    }
  }

  Future<void> deleteLibrarySong(String id) async {
    _action('library.delete', detail: id);
    try {
      await library.deleteSong(id);
      if (activeLibraryId == id) activeLibraryId = null;
      librarySongs = await library.list();
      log('Deleted library song.');
    } catch (e) {
      log('Library delete failed: $e', error: true);
    }
    notifyListeners();
  }

  /// Serializable snapshot of the stem mixer for the library.
  Map<String, dynamic> _librarySettings() => {
    'stemVolumes': Map<String, dynamic>.from(stemVolumes),
    'mutedStems': mutedStems.toList(),
    'soloStem': soloStem,
    'masterVolume': masterVolume,
    'padKeys': {for (final e in padKeys.entries) '${e.key}': e.value},
    'customSamples': {
      for (final e in _customSamples.entries)
        '${e.key}': {'path': e.value.sourcePath, 'bpm': e.value.bpm},
    },
    'beats': {
      'bpm': detectedBpm,
      'downbeats': detectedDownbeats,
      'onsets': detectedOnsets,
    },
    'pattern': _pattern.toJson(),
    'pads': {
      for (var i = 0; i < 16; i++)
        if (!pads[i].isEmpty) '$i': _padSettings(i),
    },
  };

  /// Serializable snapshot of one pad (buffers are re-baked on restore).
  Map<String, dynamic> _padSettings(int index) {
    final p = pads[index];
    return {
      'stemName': p.stemName,
      'custom': p.custom,
      'customSourcePath': p.customSourcePath,
      'customBpm': p.customBpm,
      'starter': p.starter,
      'starterName': p.starterName,
      'original': p.original,
      'start': p.startSample,
      'end': p.endSample,
      'loop': p.loop,
      'pitch': p.pitchSemitones,
      'reverse': p.reverse,
      'gain': p.gain,
      'fade': p.fadeMs,
      'label': p.label,
      'edited': p.edited,
      'origStart': p.origStartSample,
      'origEnd': p.origEndSample,
    };
  }

  void _applyLibrarySettings(Map<String, dynamic> m) {
    for (final n in activeStemNames) {
      stemVolumes[n] = 1.0;
    }
    (m['stemVolumes'] as Map?)?.forEach((k, v) {
      stemVolumes['$k'] = (v as num).toDouble();
    });
    mutedStems
      ..clear()
      ..addAll((m['mutedStems'] as List? ?? const []).cast<String>());
    soloStem = m['soloStem'] as String?;
    masterVolume = (m['masterVolume'] as num?)?.toDouble() ?? 0.9;
    // Phase A (vision): restore the cached beat analysis so loading a
    // saved song skips the minutes-long re-analysis.
    final beats = m['beats'] is Map ? m['beats'] as Map : null;
    final savedBpm = (beats?['bpm'] as num?)?.toDouble();
    if (savedBpm != null && savedBpm > 0) {
      detectedBpm = savedBpm;
      detectedDownbeats = ((beats?['downbeats'] as List?) ?? const [])
          .map((v) => (v as num).toInt())
          .where((v) => v >= 0)
          .toList()
        ..sort();
      detectedOnsets = ((beats?['onsets'] as List?) ?? const [])
          .map((v) => (v as num).toInt())
          .where((v) => v >= 0)
          .toList()
        ..sort();
      detectedBeats = [];
      _action(
        'beats.restored',
        detail:
            'bpm=$savedBpm downbeats=${detectedDownbeats.length} '
            'onsets=${detectedOnsets.length}',
      );
    } else {
      detectedBpm = null;
      detectedBeats = [];
      detectedDownbeats = [];
      detectedOnsets = [];
    }
    // Step sequencer pattern (legacy-safe: missing -> keep the default).
    final savedPattern = Pattern.fromJson(
      m['pattern'] is Map<String, dynamic>
          ? m['pattern'] as Map<String, dynamic>
          : null,
    );
    if (savedPattern != null) {
      _pattern = savedPattern;
      _action(
        'pattern.restored',
        detail:
            'bars=${_pattern.bars} bpm=${_pattern.bpm.toStringAsFixed(1)} '
            'lanes=${_pattern.lanes.length}',
      );
    }
    engine.setMasterGain(masterVolume);
    for (final n in activeStemNames) {
      if (stems.containsKey(n)) {
        engine.setStemGain(n, effectiveStemGain(n));
      }
    }
    // Restore pad key assignments (fall back to the fixed layout).
    _resetPadKeys();
    (m['padKeys'] as Map?)?.forEach((k, v) {
      final idx = int.tryParse('$k');
      final key = '$v';
      if (idx != null && AppConfig.padAutoKeyOrder.contains(key)) {
        padKeys[idx] = key;
      }
    });
  }

  /// Restore pads after a library load. Libraries WITH a persisted
  /// 'pads' block get their pads back exactly (Phase C); older libraries
  /// keep the auto-fill behavior.
  Future<void> _restoreLibraryPads(Map settings) async {
    _clearPadUndo();
    final m = settings['pads'];
    if (m is! Map || m.isEmpty) {
      await autoFillPads().then((_) => _restoreCustomSamples(settings));
      return;
    }
    // Custom sample PCM first: padSourceAudio depends on it.
    await _restoreCustomSamples(settings);
    var restored = 0;
    for (var i = 0; i < 16; i++) {
      final info = m['$i'];
      if (info is! Map) {
        pads[i].clear();
        continue;
      }
      final pad = pads[i];
      final stemName = info['stemName'] as String?;
      final starterName = info['starterName'] as String?;
      final isCustom = info['custom'] == true;
      final isStarter = info['starter'] == true;
      final isOriginal = info['original'] == true;
      final start = (info['start'] as num?)?.toInt() ?? 0;
      final end = (info['end'] as num?)?.toInt() ?? 0;
      final gain = clampPadGain((info['gain'] as num?)?.toDouble() ?? 1.0);
      final fade = clampPadFadeMs(
        (info['fade'] as num?)?.toDouble() ?? AppConfig.padFadeMsDefault,
      );
      if (isOriginal && original == null) {
        // Original PCM is loaded before pads - if it is missing the pad
        // stays empty but labelled with a clear error toast.
        pad.clear();
        pad
          ..original = true
          ..label = info['label'] as String? ?? 'Original';
        showToast('Pad ${i + 1}: original audio missing - could not restore.');
        continue;
      }
      ({Float32List left, Float32List right, int sampleRate})? src;
      if (isCustom) {
        final cs = _customSamples[i];
        if (cs != null) {
          src = (left: cs.left, right: cs.right, sampleRate: cs.sampleRate);
        }
      } else if (isOriginal) {
        final o = original!;
        src = (left: o.left, right: o.right, sampleRate: o.sampleRate);
      } else if (isStarter && starterName != null) {
        try {
          final sound = loadStarterSound(starterName);
          src = (
            left: sound.left,
            right: sound.right,
            sampleRate: sound.sampleRate,
          );
        } catch (e) {
          _action(
            'pads.restore.starter',
            detail: 'pad ${i + 1} asset missing: $starterName ($e)',
          );
        }
      } else if (stemName != null && stems.containsKey(stemName)) {
        final stem = stems[stemName]!;
        src = (left: stem.left, right: stem.right, sampleRate: stem.sampleRate);
      }
      if (src == null) continue;
      pad.clear();
      applyPadBounds(
        pad,
        stemLeft: src.left,
        stemRight: src.right,
        sampleRate: src.sampleRate,
        startSample: start,
        endSample: end,
        fadeSamples: padFadeSamples(fade, src.sampleRate),
        gain: gain,
      );
      pad
        ..stemName = stemName
        ..custom = isCustom
        ..customSourcePath = info['customSourcePath'] as String?
        ..customBpm = (info['customBpm'] as num?)?.toDouble()
        ..starter = isStarter
        ..starterName = starterName
        ..original = isOriginal
        ..loop = info['loop'] == true
        ..pitchSemitones = ((info['pitch'] as num?)?.toInt() ?? 0).clamp(
          padPitchMin,
          padPitchMax,
        )
        ..reverse = info['reverse'] == true
        ..gain = gain
        ..fadeMs = fade
        ..label = info['label'] as String? ?? ''
        ..edited = info['edited'] == true
        ..origStartSample = (info['origStart'] as num?)?.toInt() ?? start
        ..origEndSample = (info['origEnd'] as num?)?.toInt() ?? end;
      restored++;
    }
    _action('pads.restore.done', detail: '$restored/16 pads restored');
    notifyListeners();
  }

  /// Debounced persist of the mixer for the active library entry.
  void _scheduleLibrarySettingsSave() {
    if (activeLibraryId == null) return;
    _librarySaveDebounce?.cancel();
    _librarySaveDebounce = Timer(const Duration(seconds: 2), () async {
      final id = activeLibraryId;
      if (id == null) return;
      try {
        await library.saveSettings(id, _librarySettings());
        debugPrint('[BAKUSHI] library settings saved for $id');
      } catch (e) {
        debugPrint('[BAKUSHI] library settings save failed: $e');
      }
    });
  }

  // ================================================================= helpers

  void setStage(PipelineStage s, String text) {
    stage = s;
    stageText = text;
    busy =
        s == PipelineStage.decoding ||
        s == PipelineStage.separating ||
        s == PipelineStage.analyzing;
    if (busy && _uiHeartbeat == null) {
      _uiHeartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        debugPrint('[BAKUSHI] ui alive ($stageText)');
      });
    } else if (!busy) {
      _uiHeartbeat?.cancel();
      _uiHeartbeat = null;
    }
    notifyListeners();
  }

  /// One-shot toast shown by the UI (errors and confirmations).
  String? lastToast;

  void showToast(String message) {
    lastToast = message;
    notifyListeners();
  }

  /// Called by the UI after the toast was displayed.
  void clearToast() {
    lastToast = null;
    notifyListeners();
  }

  void log(String message, {bool error = false}) {
    logs.insert(0, LogEntry(DateTime.now(), message, error));
    if (logs.length > 400) logs.removeRange(400, logs.length);
    notifyListeners();
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _fmtDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  @override
  void dispose() {
    _librarySaveDebounce?.cancel();
    _uiHeartbeat?.cancel();
    _watchdog?.cancel();
    _padPlayTimer?.cancel();
    engine.disposeEngine();
    unawaited(sidecar.shutdown());
    try {
      workDir.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }
}

/// Boot the native audio engine inside a worker isolate. A stalled WASAPI
/// device enumeration must never block the UI thread; the timeout in
/// [AppState._bootEngine] gives up and keeps the rest of the app usable.
int bootEngineInIsolate() {
  try {
    NativeEngine.instance.init();
    return NativeEngine.instance.deviceSampleRate();
  } catch (_) {
    return -1;
  }
}
