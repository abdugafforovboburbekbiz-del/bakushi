/// App shell: 3-step flow - Upload Song -> Separate -> 16 Pads.
///
/// The 4-stem UI (waveforms/mixer rows) is intentionally NOT shown:
/// stems are separated, filtered and sliced in the background, and the
/// user works with the 16 pads only.
library;

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_settings.dart';
import '../state/app_state.dart';
import '../config.dart';
import '../theme/app_theme.dart';
import 'panels/diagnostics_panel.dart';
import 'panels/pads_panel.dart';
import 'panels/sequencer_panel.dart';
import 'panels/waveform_panel.dart';
import 'widgets/section_card.dart';

class HomePage extends StatefulWidget {
  final AppState state;
  const HomePage({super.key, required this.state});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _step = 1;
  String? _watchedFilePath;
  final Set<String> _heldKeys = {};
  final ScrollController _scroll = ScrollController();

  /// Phase D: first-run onboarding overlay. Hidden until the persisted
  /// flag is read (never flashes for returning users).
  bool _onboardingLoaded = false;
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    // Debug hook: autotest holds scroll the page to show bottom panels.
    widget.state.debugScrollRequest.addListener(() {
      final v = widget.state.debugScrollRequest.value;
      if (v != null && _scroll.hasClients) {
        _scroll.jumpTo(v.clamp(0, _scroll.position.maxScrollExtent));
        widget.state.debugScrollRequest.value = null;
      }
    });
    AppSettings.load().then((settings) {
      if (!mounted) return;
      final auto = Platform.environment['BAKUSHI_AUTOTEST'];
      final autotest = auto == '1' || auto == 'full';
      setState(() {
        _showOnboarding =
            settings['onboarding_done'] != true && !autotest;
        _onboardingLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _finishOnboarding() {
    AppSettings.save({'onboarding_done': true});
    setState(() => _showOnboarding = false);
    // Phase C: "Start making sound" loads the kit into empty pads.
    widget.state.loadStarterKit();
  }

  void _newSong() {
    widget.state.newSong();
    setState(() => _step = 1);
  }

  String _keyOf(KeyEvent event) {
    final label = event.logicalKey.keyLabel;
    return label.length == 1 ? label.toUpperCase() : label;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final key = _keyOf(event);
      final s = widget.state;
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        s.cancelKeyAssign();
        return KeyEventResult.handled;
      }
      if (s.assigningKeyPad != null) {
        // Keycap clicked: the next allowed key becomes that pad's key.
        if (AppConfig.padAutoKeyOrder.contains(key)) {
          s.finishKeyAssign(key);
        }
        return KeyEventResult.handled;
      }
      final padIndex = s.padForKey(key);
      if (padIndex != null && !_heldKeys.contains(key)) {
        _heldKeys.add(key);
        s.triggerPad(padIndex);
        return KeyEventResult.handled;
      }
    } else if (event is KeyUpEvent) {
      _heldKeys.remove(_keyOf(event));
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        // A new upload restarts the flow at step 1.
        if (s.filePath != null && s.filePath != _watchedFilePath) {
          _watchedFilePath = s.filePath;
          _step = 1;
        }
        // Step 1: advance once the file is decoded.
        if (_step == 1 && s.original != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _step == 1 && s.original != null) {
              setState(() => _step = 2);
            }
          });
        }
        // Phase C: a pads-only session (starter kit loaded with no song
        // yet) jumps straight to the pads - sound in seconds.
        if (_step == 1 && s.original == null && s.anyPadNonEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _step == 1 && s.original == null) {
              setState(() => _step = 3);
            }
          });
        }
        // Step 2: advance once the stems exist, or when the user is
        // actively chopping the original (chop pads only).
        if (_step == 2 && (s.stems.isNotEmpty || s.chopEditorOpen)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                _step == 2 &&
                (s.stems.isNotEmpty || s.chopEditorOpen)) {
              setState(() => _step = 3);
            }
          });
        }
        // Errors and confirmations arrive as toasts only.
        if (s.lastToast != null) {
          final msg = s.lastToast!;
          s.clearToast();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(msg)));
            }
          });
        }
        return Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            children: [
              Scaffold(
                body: DropTarget(
                  onDragDone: (detail) {
                    if (detail.files.isNotEmpty) {
                      s.onFileDropped(detail.files.first.path);
                    }
                  },
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 960),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildHeader(s),
                            const SizedBox(height: 12),
                            _stepBanner(s),
                            const SizedBox(height: 12),
                            if (_step == 1) _buildStep1(s),
                            if (_step == 2) _buildStep2(s),
                            if (_step == 3) ...[
                              PadsPanel(state: s, onNewSong: _newSong),
                              SequencerPanel(state: s),
                            ],
                            const SizedBox(height: 12),
                            _buildSettingsSection(s),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_onboardingLoaded && _showOnboarding)
                Positioned.fill(
                  child: _OnboardingOverlay(
                    onDone: _finishOnboarding,
                    onSkip: _finishOnboarding,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ header

  Widget _buildHeader(AppState s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: BakushiTokens.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [BakushiTokens.red, BakushiTokens.amber],
              ),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.graphic_eq, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          const Text(
            'Bakushi',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Make something out of any song.',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: BakushiTokens.text.withValues(alpha: 0.55),
              ),
            ),
          ),
          if (s.activeLibraryId != null) ...[
            const SizedBox(width: 8),
            _chip('Loaded: ${_loadedName(s)}', StemColors.custom),
          ],
        ],
      ),
    );
  }

  /// Name of the library song currently loaded (file name first, then
  /// a lookup in the saved-songs list).
  String _loadedName(AppState s) {
    if (s.fileName != null && s.fileName!.isNotEmpty) return s.fileName!;
    for (final e in s.librarySongs) {
      if (e.id == s.activeLibraryId) return e.name;
    }
    return 'song';
  }

  /// Phase B: technical chrome (backend/model chips + diagnostics) is
  /// demoted into ONE collapsed settings section at the very bottom.
  Widget _buildSettingsSection(AppState s) {
    final backendColor = switch (s.backend.toLowerCase()) {
      final b when b.contains('openvino') => StemColors.drums,
      final b when b.contains('cpu') => StemColors.other,
      _ => Colors.white24,
    };
    return Container(
      decoration: BoxDecoration(
        color: BakushiTokens.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BakushiTokens.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          iconColor: BakushiTokens.textFaint,
          collapsedIconColor: BakushiTokens.textFaint,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: const Icon(Icons.settings_outlined, size: 18),
          title: const Text(
            'Settings',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          children: [
            Row(
              children: [
                _chip('Backend: ${s.backend}', backendColor),
                const SizedBox(width: 8),
                _chip(
                  'Model: ${s.modelStatus}',
                  s.modelStatus == 'loaded' ? StemColors.bass : Colors.white24,
                ),
              ],
            ),
            const SizedBox(height: 10),
            DiagnosticsPanel(state: s),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }

  Widget _stepBanner(AppState s) {
    const steps = ['Upload Song', 'Separate', 'Pads'];
    return Row(
      children: [
        for (int i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Container(
              width: 28,
              height: 1,
              color: i < _step
                  ? BakushiTokens.ok
                  : Colors.white.withValues(alpha: 0.2),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: i + 1 == _step
                  ? BakushiTokens.red.withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: i + 1 == _step
                    ? BakushiTokens.red.withValues(alpha: 0.7)
                    : Colors.white.withValues(alpha: 0.12),
              ),
            ),
            child: Text(
              i + 1 < _step ? '✓ ${steps[i]}' : '${i + 1}. ${steps[i]}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: i + 1 == _step ? FontWeight.w700 : FontWeight.w400,
                color: i + 1 == _step ? Colors.white : Colors.white54,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ step 1: upload

  Widget _buildStep1(AppState s) {
    final o = s.original;
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.engine]),
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionCard(
              title: '1. Upload Song',
              subtitle:
                  'WAV, MP3, OGG or M4A - decoded locally, never uploaded',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 22),
                      ),
                      onPressed: s.busy ? null : s.pickFile,
                      icon: const Icon(Icons.music_note, size: 26),
                      label: const Text(
                        'Choose Song',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                      color: Colors.white.withValues(alpha: 0.03),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.cloud_upload_outlined, size: 26),
                        const SizedBox(height: 4),
                        Text(
                          s.fileName ??
                              'Or drag & drop an audio file anywhere here',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(
                              alpha: s.fileName != null ? 0.9 : 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (o != null) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 6,
                      children: [
                        _meta('File', s.fileName ?? '-'),
                        _meta(
                          'Size',
                          s.fileSizeBytes > 0
                              ? '${(s.fileSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB'
                              : '-',
                        ),
                        _meta('Duration', '${o.duration.toStringAsFixed(2)} s'),
                        _meta('Sample rate', '${o.sampleRate} Hz'),
                        _meta('Channels', '2 (stereo)'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          onPressed: !s.engine.transportPlaying && !s.busy
                              ? s.playOriginal
                              : null,
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('Play Original'),
                        ),
                        ElevatedButton.icon(
                          onPressed: s.engine.transportPlaying
                              ? s.stopMix
                              : null,
                          icon: const Icon(Icons.stop, size: 18),
                          label: const Text('Stop'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    StemWaveformStrip(
                      left: o.left,
                      right: o.right,
                      color: StemColors.original,
                      positionSec: s.engine.transportPositionSec,
                      height: 96,
                    ),
                  ],
                  if (s.stage == PipelineStage.error && o == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        s.stageText.isEmpty ? 'Decoding failed.' : s.stageText,
                        style: const TextStyle(
                          color: BakushiTokens.danger,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildSavedSongs(s),
          ],
        );
      },
    );
  }

  /// Saved songs list: reopen a song without re-running separation.
  Widget _buildSavedSongs(AppState s) {
    final songs = s.librarySongs;
    return SectionCard(
      title: 'Saved songs',
      subtitle:
          'Reopen a song (stems + pads) without re-running '
          'separation.',
      child: songs.isEmpty
          ? Text(
              'No saved songs yet.',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < songs.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.library_music_outlined,
                          size: 16,
                          color: Colors.white54,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                songs[i].name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${_fmtSavedAt(songs[i].savedAt)} · '
                                '${_fmtDurSec(songs[i].durationSec)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: s.busy
                              ? null
                              : () => s.loadFromLibrary(songs[i].id),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          child: const Text('Load'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _fmtSavedAt(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';

  static String _fmtDurSec(double sec) {
    final s = sec.round();
    return '${s ~/ 60}:${_two(s % 60)}';
  }

  Widget _meta(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 13)),
      ],
    );
  }

  // --------------------------------------------------------- step 2: separate

  Widget _buildStep2(AppState s) {
    final separating = s.busy && s.stage == PipelineStage.separating;
    return SectionCard(
      title: '2. Separate Stems',
      subtitle:
          'Runs the AI model locally on your machine - nothing is '
          'uploaded - stems are AI estimates and may contain bleed or '
          'artifacts.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 24),
              ),
              onPressed: (s.busy || s.original == null)
                  ? null
                  : s.separateStems,
              icon: const Icon(Icons.auto_awesome, size: 26),
              label: const Text(
                'Separate Stems',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Task 4B: chop the full mix WITHOUT separation.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (s.original == null || s.busy)
                  ? null
                  : s.startChopEditor,
              icon: const Icon(Icons.content_cut, size: 17),
              label: const Text('Chop Original Song'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (separating) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: s.progress > 0 ? s.progress / 100 : null,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.stageText.isEmpty ? 'Preparing ...' : s.stageText,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: s.cancel,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Cancel'),
              ),
            ),
          ],
          if (s.stage == PipelineStage.error && s.stems.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                s.stageText.isEmpty ? 'Separation failed.' : s.stageText,
                style: const TextStyle(
                  color: BakushiTokens.danger,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- Phase D: onboarding

/// First-run onboarding: 3 warm, image-free screens with one big button
/// each. Skippable; shown only once (persisted flag).
class _OnboardingOverlay extends StatefulWidget {
  final VoidCallback onDone;
  final VoidCallback onSkip;

  const _OnboardingOverlay({
    required this.onDone,
    required this.onSkip,
  });

  @override
  State<_OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<_OnboardingOverlay> {
  int _page = 0;

  static const _pages = [
    (
      icon: Icons.music_note,
      title: 'Put a song in.\nGet music out.',
      body:
          'Bakushi splits any song into drums, bass and vocals - right '
          'on your computer, nothing uploaded, no internet needed.',
    ),
    (
      icon: Icons.grid_view_rounded,
      title: 'One song becomes\n16 pads.',
      body:
          'Separation runs automatically and the pads are cut to the '
          'music. Drums become one-shots; bass and vocals become loops '
          'that start right on the beat.',
    ),
    (
      icon: Icons.bolt,
      title: 'Tap pads.\nMake something.',
      body:
          'Layer loops, pitch sounds up and down, record your '
          'performance and export it as a WAV. No tutorial - just play.',
    ),
  ];

  void _next() {
    if (_page == _pages.length - 1) {
      widget.onDone();
    } else {
      setState(() => _page++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _pages[_page];
    final last = _page == _pages.length - 1;
    return Material(
      color: BakushiTokens.bg.withValues(alpha: 0.985),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [BakushiTokens.red, BakushiTokens.amber],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(p.icon, size: 36, color: Colors.white),
              ),
              const SizedBox(height: 26),
              Text(
                p.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                p.body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.45,
                  color: BakushiTokens.text.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),
                  onPressed: _next,
                  icon: Icon(
                    last ? Icons.auto_awesome : Icons.arrow_forward,
                    size: 20,
                  ),
                  label: Text(
                    last ? 'Start making sound' : 'Next',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: widget.onSkip,
                child: const Text('Skip'),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    Container(
                      width: i == _page ? 18 : 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == _page
                            ? BakushiTokens.red
                            : BakushiTokens.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
