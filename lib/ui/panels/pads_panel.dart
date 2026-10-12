/// 16-pad auto-cut sampler: beat-locked pads with per-pad HIT/LOOP mode
/// and a slice editor (light Phase B).
library;

import 'package:flutter/material.dart';

import '../../config.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../widgets/section_card.dart';
import 'chop_editor.dart';
import 'pad_editor.dart';
import 'pad_inspector.dart';

class PadsPanel extends StatelessWidget {
  final AppState state;
  final VoidCallback? onNewSong;
  const PadsPanel({super.key, required this.state, this.onNewSong});

  @override
  Widget build(BuildContext context) {
    final s = state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final editing = s.editingPadIndex;
        final allNames = s.activeStemNames
            .where((n) => s.stems.containsKey(n))
            .toList();
        final silentCount = allNames.where(s.isStemSilent).length;
        final hiddenCount = silentCount;
        return SectionCard(
          title: '16-Pad Auto-Cut',
          subtitle: editing == null
              ? 'Pads fill automatically after separation. Tap a pad to '
                    'play it. Tap the sliders icon to open its settings - '
                    'pitch, reverse, gain, fade and slice editing live '
                    'there.'
              : 'Slice editor - drag the cut lines to resize, drag the '
                    'purple area to move. Changes apply live.',
          actions: [
            if (editing == null) ...[
              if (s.recState == RecState.recording)
                OutlinedButton.icon(
                  onPressed: s.stopRecording,
                  icon: const Icon(
                    Icons.fiber_manual_record,
                    size: 15,
                    color: BakushiTokens.danger,
                  ),
                  label: const Text('Stop Recording'),
                  style: OutlinedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: s.startRecording,
                  icon: const Icon(
                    Icons.fiber_manual_record,
                    size: 15,
                    color: BakushiTokens.danger,
                  ),
                  label: const Text('Record'),
                  style: ElevatedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              const SizedBox(width: 6),
              ElevatedButton.icon(
                onPressed: s.anyPadPlaying ? s.stopAllPads : null,
                icon: const Icon(Icons.stop_circle_outlined, size: 17),
                label: const Text('Stop All Pads'),
              ),
            ],
          ],
          child: editing != null
              ? PadSliceEditor(state: s, padIndex: editing)
              : s.chopEditorOpen
              ? ChopEditor(state: s)
              : Column(
                  children: [
                    Stack(
                      children: [
                        GridView.count(
                          crossAxisCount: 4,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.45,
                          children: [
                            for (int i = 0; i < 16; i++)
                              _PadTile(state: s, index: i),
                          ],
                        ),
                        // Phase E: "it's alive" moment - a warm glow
                        // over the grid while 3+ loops sound at once.
                        Positioned.fill(
                          child: _ComboGlow(active: s.comboActive),
                        ),
                      ],
                    ),
                    if (s.recState == RecState.stopped) _recordingCard(s),
                    if (s.selectedPadIndex != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: PadInspector(
                          state: s,
                          index: s.selectedPadIndex!,
                        ),
                      ),
                    if (s.performanceList.isNotEmpty) _performancesCard(s),
                    if (silentCount > 0)
                      Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: BakushiTokens.amber
                              .withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: BakushiTokens.amber
                                .withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.info_outline,
                              size: 14,
                              color: BakushiTokens.amber,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${allNames.length - silentCount} stems with '
                                'audio detected '
                                '($hiddenCount near-silent hidden).',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.85),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: s.detectedBpm == null
                                ? const SizedBox.shrink()
                                : Text(
                                    'Tempo ${s.detectedBpm!.toStringAsFixed(1)} BPM - '
                                    'loops start on the real downbeats.',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.white.withValues(
                                        alpha: 0.45,
                                      ),
                                    ),
                                  ),
                          ),
                          if (s.original != null)
                            OutlinedButton.icon(
                              onPressed: s.startChopEditor,
                              icon: const Icon(Icons.content_cut, size: 16),
                              label: const Text('Chop Original Song'),
                              style: OutlinedButton.styleFrom(
                                textStyle: const TextStyle(fontSize: 12),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            onPressed: s.loadStarterKit,
                            icon: const Icon(Icons.music_note, size: 16),
                            label: const Text('Load Starter Kit'),
                            style: OutlinedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 12),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            onPressed: s.shuffleStarterKit,
                            icon: const Icon(Icons.shuffle, size: 16),
                            label: const Text('Shuffle'),
                            style: OutlinedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 12),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const SizedBox(width: 6),
                          TextButton.icon(
                            onPressed: s.stems.isEmpty
                                ? null
                                : s.exportAllStems,
                            icon: const Icon(Icons.save_alt, size: 16),
                            label: const Text('Export Stems'),
                          ),
                          TextButton.icon(
                            onPressed: onNewSong,
                            icon: const Icon(
                              Icons.add_circle_outline,
                              size: 16,
                            ),
                            label: const Text('New Song'),
                          ),
                        ],
                      ),
                    ),
                    // Phase E: master FX knobs (Filter / Echo), off by
                    // default - wet=0 is an exact passthrough.
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          const Text(
                            'Filter',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 10,
                                ),
                              ),
                              child: Slider(
                                value: s.fxFilterHz.clamp(0, 8000),
                                min: 0,
                                max: 8000,
                                onChanged: s.setFxFilter,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 52,
                            child: Text(
                              s.fxFilterHz > 0
                                  ? '${s.fxFilterHz.round()} Hz'
                                  : 'off',
                              style: TextStyle(
                                fontSize: 10,
                                color: s.fxFilterHz > 0
                                    ? BakushiTokens.redSoft
                                    : Colors.white38,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'Echo',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 10,
                                ),
                              ),
                              child: Slider(
                                value: s.fxEchoWet.clamp(0, 0.5),
                                min: 0,
                                max: 0.5,
                                onChanged: s.setFxEcho,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 52,
                            child: Text(
                              s.fxEchoWet > 0
                                  ? '${(s.fxEchoWet * 200).round()}%'
                                  : 'off',
                              style: TextStyle(
                                fontSize: 10,
                                color: s.fxEchoWet > 0
                                    ? BakushiTokens.redSoft
                                    : Colors.white38,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// Rendered recording: Preview / Export / Discard (D1, no timeline).
  Widget _recordingCard(AppState s) {
    final r = s.lastRender;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: BakushiTokens.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: BakushiTokens.danger.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.fiber_manual_record,
            size: 14,
            color: BakushiTokens.danger,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              r == null
                  ? 'Recording ready.'
                  : 'Recording ready · '
                        '${r.durationSeconds.toStringAsFixed(1)} s · '
                        'peak ${r.peak.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: s.previewPerformance,
            icon: const Icon(Icons.play_arrow, size: 15),
            label: const Text('Preview Recording'),
          ),
          TextButton.icon(
            onPressed: s.exportPerformance,
            icon: const Icon(Icons.save_alt, size: 15),
            label: const Text('Export Recording WAV'),
          ),
          TextButton.icon(
            onPressed: s.discardPerformance,
            icon: const Icon(Icons.delete_outline, size: 15),
            label: const Text('Discard'),
          ),
        ],
      ),
    );
  }

  /// Saved performances of the active song: Preview / Export / Delete
  /// ONLY (no timeline editing).
  Widget _performancesCard(AppState s) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Performances (${s.performanceList.length})',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            for (final p in s.performanceList)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${p['name'] ?? 'Performance'} · '
                        '${((p['durationSeconds'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)} s',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Preview',
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      onPressed: () =>
                          s.previewPerformanceFile('${p['wavPath']}'),
                      icon: const Icon(Icons.play_arrow, color: Colors.white70),
                    ),
                    IconButton(
                      tooltip: 'Export',
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      onPressed: () =>
                          s.exportPerformanceFile('${p['wavPath']}'),
                      icon: const Icon(Icons.save_alt, color: Colors.white70),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      onPressed: () =>
                          s.deletePerformanceFile('${p['wavPath']}'),
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PadTile extends StatefulWidget {
  final AppState state;
  final int index;

  const _PadTile({required this.state, required this.index});

  @override
  State<_PadTile> createState() => _PadTileState();
}

class _PadTileState extends State<_PadTile> {
  bool _pressed = false;

  static Color colorFor(AppState s, int index) {
    final pad = s.pads[index];
    if (pad.isEmpty) return Colors.white24;
    if (pad.original) return StemColors.originalChop;
    if (pad.starter) return StemColors.starterKit;
    if (pad.custom) return StemColors.custom;
    if (pad.stemName != null) return StemColors.forStem(pad.stemName!);
    return Colors.white24;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final index = widget.index;
    final pad = s.pads[index];
    final color = colorFor(s, index);
    final playing = pad.isEmpty ? false : s.padPlaying(index);
    final key = s.padKeys[index] ?? AppConfig.padAutoKeyOrder[index];
    final assigning = s.assigningKeyPad == index;
    final selected = s.selectedPadIndex == index;
    final stemLabel = pad.isEmpty
        ? ''
        : pad.label.isEmpty
        ? 'EMPTY'
        : pad.label.toUpperCase();

    final tile = AnimatedScale(
      scale: _pressed ? 0.96 : 1.0,
      duration: const Duration(milliseconds: 90),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          splashColor: color.withValues(alpha: 0.35),
          highlightColor: color.withValues(alpha: 0.22),
          onHighlightChanged: (v) {
            if (v != _pressed) setState(() => _pressed = v);
          },
          // Phase D: the ENTIRE tile is one button. Empty pads open the
          // inspector (action row); filled pads trigger.
          onTap: () =>
              pad.isEmpty ? s.selectPad(index) : s.triggerPad(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: color.withValues(alpha: playing ? 0.45 : 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: playing
                    ? color
                    : selected
                    ? BakushiTokens.red
                    : assigning
                    ? BakushiTokens.amber
                    : color.withValues(alpha: 0.45),
                width: selected || assigning ? 2 : 1,
              ),
              // Phase B: a real glow while the pad is sounding.
              boxShadow: playing
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ]
                  : const [],
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Small corner keycap: tap to reassign the key.
                    Tooltip(
                      message: 'Reassign key (tap, then press a key)',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(5),
                        onTap: () => s.startKeyAssign(index),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: assigning
                                ? BakushiTokens.amber
                                : Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: assigning
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            assigning ? '?' : key,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'PAD ${index + 1}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                  color: Colors.white.withValues(alpha: 0.75),
                                ),
                              ),
                              const Spacer(),
                              if (playing && pad.loop)
                                const _LoopPulseIcon()
                              else if (playing)
                                const Icon(
                                  Icons.volume_up,
                                  size: 13,
                                  color: Colors.white,
                                ),
                            ],
                          ),
                          Text(
                            stemLabel.isEmpty ? 'empty' : stemLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  pad.isEmpty
                                      ? (s.busy &&
                                              s.stage ==
                                                  PipelineStage.analyzing)
                                            ? 'Finding the best moments...'
                                            : 'empty pad - tap to fill'
                                      : '${pad.loop ? 'LOOP' : 'HIT'} · '
                                            '${pad.durationSeconds.toStringAsFixed(2)} s',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.65),
                                  ),
                                ),
                              ),
                              // Sampler Polish badges: pitch (unselected
                              // only - the selected tile shows its slider),
                              // REV, gain, fade.
                              if (pad.pitchSemitones != 0 && !selected)
                                Padding(
                                  padding: const EdgeInsets.only(left: 3),
                                  child: _badge(
                                    '${pad.pitchSemitones > 0 ? '+' : ''}'
                                    '${pad.pitchSemitones} st',
                                    BakushiTokens.redSoft,
                                  ),
                                ),
                              if (pad.reverse)
                                Padding(
                                  padding: const EdgeInsets.only(left: 3),
                                  child: _badge('REV', BakushiTokens.danger),
                                ),
                              if ((pad.gain - 1.0).abs() >= 0.001)
                                Padding(
                                  padding: const EdgeInsets.only(left: 3),
                                  child: _badge(
                                    '${(pad.gain * 100).round()}%',
                                    BakushiTokens.ok,
                                  ),
                                ),
                              if ((pad.fadeMs - 5.0).abs() >= 0.01)
                                Padding(
                                  padding: const EdgeInsets.only(left: 3),
                                  child: _badge(
                                    '${pad.fadeMs.round()}ms',
                                    BakushiTokens.gold,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    // Phase D: editing lives ONLY in the selected-pad
                    // inspector; the tile keeps one quiet settings icon.
                    if (!pad.isEmpty)
                      Tooltip(
                        message: 'Pad settings (selects without triggering)',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => s.selectPad(index),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.tune,
                              size: 13,
                              color: selected
                                  ? BakushiTokens.redSoft
                                  : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Task 1: the selected pad gets a compact pitch slider OUTSIDE the
    // play InkWell, so dragging can never trigger audio.
    if (!selected || pad.isEmpty) return tile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(child: tile),
        _TilePitchSlider(state: s, index: index),
      ],
    );
  }

  static Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

/// Small pulsing loop icon shown while a LOOP pad is actively sounding.
class _LoopPulseIcon extends StatefulWidget {
  const _LoopPulseIcon();

  @override
  State<_LoopPulseIcon> createState() => _LoopPulseIconState();
}

class _LoopPulseIconState extends State<_LoopPulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(
        begin: 0.45,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: const Icon(Icons.loop, size: 13, color: BakushiTokens.redSoft),
    );
  }
}

/// Sampler Polish Task 1: compact pitch slider shown ONLY on the
/// selected tile. Lives OUTSIDE the tile's play InkWell, so dragging
/// never triggers the pad. Drag = UI only; release commits
/// (setPadPitch stops the pad, then previews once).
class _TilePitchSlider extends StatefulWidget {
  final AppState state;
  final int index;
  const _TilePitchSlider({required this.state, required this.index});

  @override
  State<_TilePitchSlider> createState() => _TilePitchSliderState();
}

class _TilePitchSliderState extends State<_TilePitchSlider> {
  late double _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.state.pads[widget.index].pitchSemitones.toDouble();
  }

  @override
  void didUpdateWidget(covariant _TilePitchSlider old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _draft = widget.state.pads[widget.index].pitchSemitones.toDouble();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final min = AppConfig.padPitchMin.toDouble();
    final max = AppConfig.padPitchMax.toDouble();
    return Row(
      children: [
        const Text('-24', style: TextStyle(fontSize: 8, color: Colors.white38)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
            ),
            child: Slider(
              value: _draft.clamp(min, max),
              min: min,
              max: max,
              divisions: 48,
              onChanged: (v) => setState(() => _draft = v),
              onChangeEnd: (v) {
                setState(() => _draft = v);
                s.setPadPitch(widget.index, v.round());
                s.previewPad(widget.index); // one-shot
              },
            ),
          ),
        ),
        const Text('+24', style: TextStyle(fontSize: 8, color: Colors.white38)),
        SizedBox(
          width: 36,
          child: Text(
            _draft == 0
                ? '0 st'
                : '${_draft > 0 ? '+' : ''}${_draft.round()} st',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 9,
              fontWeight: _draft == 0 ? FontWeight.w500 : FontWeight.w800,
              color: _draft == 0
                  ? Colors.white.withValues(alpha: 0.6)
                  : BakushiTokens.redSoft,
            ),
          ),
        ),
      ],
    );
  }
}

/// Phase E (vision): the "it's alive" combo moment - a warm glow washes
/// over the pad grid while 3+ loop pads sound simultaneously. Pure
/// Flutter, no engine involvement.
class _ComboGlow extends StatelessWidget {
  final bool active;

  const _ComboGlow({required this.active});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: active ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: BakushiTokens.amber.withValues(alpha: 0.55),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: BakushiTokens.amber.withValues(alpha: 0.3),
                blurRadius: 34,
                spreadRadius: 6,
              ),
            ],
            gradient: RadialGradient(
              colors: [
                BakushiTokens.red.withValues(alpha: 0.18),
                BakushiTokens.amber.withValues(alpha: 0.06),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
