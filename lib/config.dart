/// Central configuration for Bakushi.
///
/// Every tunable that the spec asks to make visible lives here.
library;

class AppConfig {
  AppConfig._();

  static const String appName = 'Bakushi';

  /// Path to the HTDemucs ONNX model.
  ///
  /// The model is intentionally NOT bundled with the app.
  /// Loader resolution order:
  ///   1. user-chosen path (persisted; choose it once in the app)
  ///   2. `<working dir>/assets/models/htdemucs_fp16weights.onnx`
  ///   3. `<exe dir>/assets/models/htdemucs_fp16weights.onnx`
  ///   4. `<exe dir>/htdemucs_fp16weights.onnx`
  ///
  /// 4-stem model (drums, bass, other, vocals; fp16 internal weights,
  /// fp32 in/out): ~166 MB instead of 258 MB, faster and lighter than the
  /// fp32 exports. This is the app's DEFAULT and recommended model for
  /// MPC sampling. If the file is missing the UI shows a clear error -
  /// no fake audio.
  static const String modelFileName = 'htdemucs_fp16weights.onnx';
  static const String modelPathDefault =
      'assets/models/htdemucs_fp16weights.onnx';

  /// Optional 6-stem model (adds guitar + piano to the 4 stems; fp16
  /// internal weights, fp32 in/out, ~136 MB). Shown in Step 2 as
  /// "6-Stem (Guitar + Piano)" when the file exists. Slower than the
  /// 4-stem model and not needed for MPC pads, but useful for full mixes.
  ///
  /// The int8-quantized 4-stem variant is GONE: the 2026-10-11 benchmark
  /// proved it SLOWER than the fp16 model on every backend on this
  /// machine (3.32x RTF on the ORT CPU EP). See docs/BENCHMARKS.md.
  static const String sixStemModelFileName = 'htdemucs_6s_fp16weights.onnx';
  static const String sixStemModelPathDefault =
      'assets/models/htdemucs_6s_fp16weights.onnx';

  // Model I/O layout (configurable; the sidecar derives the real segment
  // length from the loaded model's input shape whenever possible).
  static const int modelSampleRate = 44100;
  static const int modelChannels = 2;
  static const int modelSegmentSamples = 343980; // ~7.8 s at 44.1 kHz
  static const int modelHopSamples = 88200; // 2.0 s overlap step
  // Longer hop for long songs. 257985 = 343980 x 0.75, i.e. the demucs
  // reference overlap of 0.25 (StemDeck calls apply_model(split=True,
  // overlap=0.25); see docs/RESEARCH.md). Fewer chunks, ~2.6x less work
  // than the old 132300 hop.
  static const int modelHopSamplesLong = 257985;

  /// Prototype safety cap for the input duration. The UI warns on long files.
  /// 5 min = 300 s; separation of a full 5 min needs ~2 GB free RAM.
  static const double maxInputSeconds = 300;

  /// Accepted upload formats (decoded locally by the sidecar via PyAV).
  static const List<String> supportedExtensions = ['wav', 'mp3', 'ogg', 'm4a'];

  // Engine.
  static const int engineSampleRate = 44100;
  static const int engineChannels = 2;

  /// Engine voice ids (pads 0..15, stems 100..105, original 200).
  static const int padVoiceIdBase = 0;
  static const int stemVoiceIdVocals = 100;
  static const int stemVoiceIdDrums = 101;
  static const int stemVoiceIdBass = 102;
  static const int stemVoiceIdOther = 103;
  static const int stemVoiceIdGuitar = 104;
  static const int stemVoiceIdPiano = 105;
  static const int originalVoiceId = 200;

  /// Click-avoiding transport fade (frames at 44.1 kHz).
  static const int transportFadeFrames = 441; // 10 ms

  /// Pad trigger fade (5 ms) + the loop-wrap re-fade in the C engine keep
  /// pad playback click-free and loops seamless.
  static const int padFadeFrames = 220; // 5 ms

  /// Fixed keyboard layout for the 16 pads, shown on each pad's keycap:
  /// pads 1-4 Q W E R, 5-8 A S D F, 9-12 Z X C V, 13-16 1 2 3 4.
  /// Also the set of keys the reassignment mode accepts.
  static const List<String> padAutoKeyOrder = [
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
  ];

  /// Stems whose RMS is below this are considered near-silent and hidden
  /// from the default Step 3 view (data is kept for export).
  static const double silentStemRms = 0.01;

  /// Whether an RMS value falls under the near-silent threshold.
  static bool isSilentRms(double rms) => rms < silentStemRms;

  // Phase C: per-pad sampler controls.

  /// Pitch range in semitones (playback rate = 2^(semitones/12)).
  /// Sampler Polish: widened to -24..+24 (two octaves each way).
  static const int padPitchMin = -24;
  static const int padPitchMax = 24;

  /// Gain range: 0%..200% (linear 0..2), baked with a hard clamp.
  static const double padGainMin = 0.0;
  static const double padGainMax = 2.0;

  /// Minimum slice length in the cut editor (milliseconds).
  static const double minSliceMs = 20.0;

  // Sampler Polish: per-pad micro-fade (click-free edges, no ADSR).
  /// Pad edge-fade range in milliseconds.
  static const double padFadeMsMin = 0.0;
  static const double padFadeMsMax = 50.0;
  static const double padFadeMsDefault = 5.0;

  /// Engine voice id used for rendered performance / chop previews
  /// (must stay < BA_MAX_BUFFERS 256 and unused by pads/stems/original).
  static const int recordingPreviewVoiceId = 210;

  /// Sequencer loop voice: the rendered pattern loop plays from here.
  /// Must stay < BA_MAX_BUFFERS 256 and unused by every other id.
  static const int sequencerVoiceId = 211;

  /// Stem display names and order (4-stem HTDemucs: no guitar/piano).
  static const List<String> stemNames = ['drums', 'bass', 'other', 'vocals'];

  /// The 4-stem model is the app's default; the old 6-stem names remain
  /// here only for the audio-engine voice-id table.
  static const List<String> allStemNames = [
    'drums',
    'bass',
    'other',
    'vocals',
    'guitar',
    'piano',
  ];
}

/// Separation models offered in the Step 2 chooser.
///   fourStem = htdemucs_fp16weights.onnx (~166 MB, fp16 weights):
///              drums/bass/other/vocals - RECOMMENDED for MPC sampling.
///   sixStem  = htdemucs_6s_fp16weights.onnx (~136 MB, fp16 weights):
///              adds guitar + piano - for full mixes.
/// The int8-quantized fast mode was removed after benchmarks proved it
/// slower than fp16 on every backend on this machine (docs/BENCHMARKS.md).
enum SeparationMode { fourStem, sixStem }

/// Compute device offered in the Step 2 chooser. Both choices FORCE the
/// sidecar to that backend (no automatic fallback): GPU = native OpenVINO
/// on the Intel GPU (every GPU device is probe-validated), CPU = OpenVINO
/// CPU (falls back to the ORT CPU EP if OpenVINO fails).
enum SeparationBackend { cpu, gpu }

/// Pad division (pure beat-locked math from the BPM scalar).
///   beat    = 1 beat per pad  -> pads default to HIT
///   bar     = 1 bar per pad   -> pads default to LOOP
///   twoBars = 2 bars per pad  -> pads default to LOOP
enum Division {
  beat('1 Beat', 1),
  bar('1 Bar', 4),
  twoBars('2 Bars', 8);

  final String label;

  /// Segment length in beats (1 bar = 4 beats).
  final int beats;

  /// Default pad behavior for this division.
  bool get defaultLoop => this != Division.beat;

  const Division(this.label, this.beats);
}
