/// Phase C: compact selected-pad inspector (Canva-style).
///
/// One obvious action per control: HIT/LOOP pills, pitch slider with
/// reset, reverse switch, gain slider with reset, Preview / Stop / Edit /
/// Upload / Clear. Sliders commit on release (any playback-affecting
/// change stops the pad first).
library;

import 'package:flutter/material.dart';

import '../../config.dart';
import '../../models/pad.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';

class PadInspector extends StatefulWidget {
  final AppState state;
  final int index;
  const PadInspector({super.key, required this.state, required this.index});

  @override
  State<PadInspector> createState() => _PadInspectorState();
}

class _PadInspectorState extends State<PadInspector> {
  late double _pitchDraft;
  late double _gainDraft;
  late double _fadeDraft;

  @override
  void initState() {
    super.initState();
    _syncDrafts();
  }

  @override
  void didUpdateWidget(covariant PadInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _syncDrafts();
  }

  void _syncDrafts() {
    final pad = widget.state.pads[widget.index];
    _pitchDraft = pad.pitchSemitones.toDouble();
    _gainDraft = pad.gain;
    _fadeDraft = pad.fadeMs;
  }

  static Color _padColor(Pad pad) {
    if (pad.starter) return StemColors.starterKit;
    if (pad.custom) return StemColors.custom;
    if (pad.stemName != null) return StemColors.forStem(pad.stemName!);
    return StemColors.original;
  }

  Future<void> _confirmClear(AppState s, Pad pad) async {
    if (!pad.edited && !pad.custom) {
      s.clearPad(widget.index);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: BakushiTokens.panel2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Clear pad?'),
        content: const Text(
          'This pad has manually edited content. Clearing removes its '
          'source, slice range and label.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: BakushiTokens.danger,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) s.clearPad(widget.index);
  }

  /// Upload replaces the pad's source: confirm first when the pad has
  /// manually edited content (mirrors the Clear confirmation).
  Future<void> _confirmUpload(AppState s, Pad pad) async {
    if (!pad.edited && !pad.custom) {
      await s.uploadSampleToPad(widget.index);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: BakushiTokens.panel2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Replace this pad?'),
        content: const Text(
          "Replace this pad's edited sample? This cannot be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (ok == true) await s.uploadSampleToPad(widget.index);
  }

  /// Reset Sound resets bounds + pitch/reverse/gain/fade; confirms when
  /// the pad has manually edited content (mirrors Clear/Upload).
  Future<void> _confirmResetSound(AppState s, Pad pad) async {
    if (!pad.edited && !pad.custom) {
      s.resetPadSound(widget.index);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: BakushiTokens.panel2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Reset sound?'),
        content: const Text(
          'This restores the original slice, pitch 0, reverse off, '
          'gain 100% and fade 5 ms. Current edits will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep edits'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) s.resetPadSound(widget.index);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final pad = s.pads[widget.index];
    final color = _padColor(pad);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: source identity + close (deselect).
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      pad.isEmpty
                          ? 'Pad ${widget.index + 1} · Empty'
                          : 'Pad ${widget.index + 1} · ${pad.label}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close inspector',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: () => s.selectPad(widget.index),
                    icon: const Icon(Icons.close, color: Colors.white54),
                  ),
                ],
              ),
              if (pad.isEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'This pad is empty. Pick a source to make it sound:',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _confirmUpload(s, pad),
                      icon: const Icon(Icons.file_upload, size: 16),
                      label: const Text('Upload sample'),
                    ),
                    OutlinedButton.icon(
                      onPressed: s.loadStarterKit,
                      icon: const Icon(Icons.music_note, size: 16),
                      label: const Text('Starter kit'),
                    ),
                    OutlinedButton.icon(
                      onPressed: s.original == null
                          ? null
                          : s.startChopEditor,
                      icon: const Icon(Icons.content_cut, size: 16),
                      label: const Text('Chop from song'),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 8),
                // HIT / LOOP pills.
                Row(
                  children: [
                    Text(
                      'Mode',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _modePill(s, true, pad),
                    const SizedBox(width: 6),
                    _modePill(s, false, pad),
                    const Spacer(),
                    Text(pad.loop ? 'loops until stopped' : 'plays once'),
                  ],
                ),
                const SizedBox(height: 8),
                // Pitch slider (Sampler Polish: -24..+24, commits on
                // release + one-shot preview).
                _sliderRow(
                  label: 'Pitch',
                  icon: Icons.music_note,
                  value: _pitchDraft,
                  min: AppConfig.padPitchMin.toDouble(),
                  max: AppConfig.padPitchMax.toDouble(),
                  divisions: 48,
                  display: _pitchDraft == 0
                      ? '0 st'
                      : '${_pitchDraft > 0 ? '+' : ''}'
                            '${_pitchDraft.round()} st',
                  neutral: _pitchDraft == 0,
                  onChanged: (v) => setState(() => _pitchDraft = v),
                  onCommit: (v) {
                    _pitchDraft = v;
                    s.setPadPitch(widget.index, v.round());
                    s.previewPad(widget.index); // one-shot
                  },
                  onReset: () {
                    setState(() => _pitchDraft = 0);
                    s.setPadPitch(widget.index, 0);
                  },
                ),
                const SizedBox(height: 2),
                // Reverse switch.
                Row(
                  children: [
                    Text(
                      'Reverse',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Switch(
                      value: pad.reverse,
                      onChanged: (v) => s.setPadReverse(widget.index, v),
                    ),
                    const SizedBox(width: 8),
                    if (pad.reverse)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: BakushiTokens.danger
                              .withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'REV',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: BakushiTokens.redSoft,
                          ),
                        ),
                      ),
                    const Spacer(),
                    Text(pad.reverse ? 'plays backward' : 'plays forward'),
                  ],
                ),
                const SizedBox(height: 2),
                // Gain slider.
                _sliderRow(
                  label: 'Gain',
                  icon: Icons.volume_up,
                  value: _gainDraft,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  display: '${(_gainDraft * 100).round()}%',
                  neutral: (_gainDraft - 1.0).abs() < 0.001,
                  onChanged: (v) => setState(() => _gainDraft = v),
                  onCommit: (v) {
                    _gainDraft = v;
                    s.setPadGain(widget.index, v);
                  },
                  onReset: () {
                    setState(() => _gainDraft = 1.0);
                    s.setPadGain(widget.index, 1.0);
                  },
                ),
                const SizedBox(height: 2),
                // Fade slider (Sampler Polish: 0-50 ms, default 5).
                _sliderRow(
                  label: 'Fade',
                  icon: Icons.graphic_eq,
                  value: _fadeDraft,
                  min: AppConfig.padFadeMsMin,
                  max: AppConfig.padFadeMsMax,
                  divisions: 50,
                  display: '${_fadeDraft.round()} ms',
                  neutral:
                      (_fadeDraft - AppConfig.padFadeMsDefault).abs() < 0.01,
                  onChanged: (v) => setState(() => _fadeDraft = v),
                  onCommit: (v) {
                    _fadeDraft = v;
                    s.setPadFade(widget.index, v);
                  },
                  onReset: () {
                    setState(() => _fadeDraft = AppConfig.padFadeMsDefault);
                    s.setPadFade(widget.index, AppConfig.padFadeMsDefault);
                  },
                ),
                const SizedBox(height: 10),
                // Actions.
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => s.previewPad(widget.index),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('Preview'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => s.stopPadNow(widget.index),
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('Stop'),
                    ),
                    FilledButton.icon(
                      onPressed: () => s.startPadEdit(widget.index),
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('Edit'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _confirmUpload(s, pad),
                      icon: const Icon(Icons.file_upload, size: 16),
                      label: const Text('Upload'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _confirmResetSound(s, pad),
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('Reset Sound'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => s.exportPlayedPad(widget.index),
                      icon: const Icon(Icons.save_alt, size: 16),
                      label: const Text('Export Played Pad'),
                    ),
                    // Phase D: one-level undo (enabled after a
                    // destructive edit).
                    OutlinedButton.icon(
                      onPressed: s.padHasUndo(widget.index)
                          ? () => s.undoPad(widget.index)
                          : null,
                      icon: const Icon(Icons.undo, size: 16),
                      label: const Text('Undo'),
                    ),
                    TextButton.icon(
                      onPressed: () => _confirmClear(s, pad),
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Clear'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _modePill(AppState s, bool loop, Pad pad) {
    final active = pad.loop == loop;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => s.setPadLoop(widget.index, loop),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? BakushiTokens.red.withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? BakushiTokens.red
                : Colors.white.withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          loop ? 'LOOP' : 'HIT',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: active ? Colors.white : Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  Widget _sliderRow({
    required String label,
    required IconData icon,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required bool neutral,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onCommit,
    required VoidCallback onReset,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.5)),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onCommit,
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              fontWeight: neutral ? FontWeight.w500 : FontWeight.w800,
              color: neutral
                  ? Colors.white.withValues(alpha: 0.7)
                  : BakushiTokens.redSoft,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Reset $label',
          visualDensity: VisualDensity.compact,
          iconSize: 14,
          onPressed: onReset,
          icon: const Icon(Icons.restart_alt, color: Colors.white54),
        ),
      ],
    );
  }
}
