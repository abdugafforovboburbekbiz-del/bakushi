/// Step-grid sequencer (the minimal MPC core): 16 lanes, 16th-note
/// steps, 1/2/4 bars. Plays through the rendered pattern loop voice -
/// no real-time recording, no swing, no quantization.
library;

import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../widgets/section_card.dart';

class SequencerPanel extends StatelessWidget {
  final AppState state;
  const SequencerPanel({super.key, required this.state});

  static Color _padColor(AppState s, int index) {
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
    final s = state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final pat = s.activePattern;
        final steps = pat.totalSteps;
        return SectionCard(
          title: 'Beat Grid',
          subtitle:
              'Click steps to place pads on the 16th grid. Press Play - '
              'the pattern loops while you keep building.',
          actions: [
            s.isPatternPlaying
                ? OutlinedButton.icon(
                    onPressed: s.stopPattern,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('Stop'),
                    style: OutlinedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                : FilledButton.icon(
                    onPressed: pat.isEmpty ? null : s.playPattern,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Play'),
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: pat.isEmpty ? null : s.clearPattern,
              icon: const Icon(Icons.delete_outline, size: 15),
              label: const Text('Clear'),
              style: OutlinedButton.styleFrom(
                textStyle: const TextStyle(fontSize: 12),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Tempo',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${pat.bpm.round()} BPM',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  IconButton(
                    tooltip: '-5 BPM',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: () => s.setPatternBpm(pat.bpm - 5),
                    icon: const Icon(Icons.remove, size: 15),
                  ),
                  IconButton(
                    tooltip: '+5 BPM',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: () => s.setPatternBpm(pat.bpm + 5),
                    icon: const Icon(Icons.add, size: 15),
                  ),
                  const SizedBox(width: 10),
                  for (final b in const [1, 2, 4]) ...[
                    _barsChip(s, b),
                    const SizedBox(width: 6),
                  ],
                  const Spacer(),
                  if (s.isPatternPlaying)
                    Row(
                      children: [
                        const _PlayingPulse(),
                        const SizedBox(width: 6),
                        Text(
                          'looping',
                          style: TextStyle(
                            fontSize: 11,
                            color: BakushiTokens.redSoft,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 6),
              for (var p = 0; p < 16; p++) _laneRow(context, s, p, steps),
            ],
          ),
        );
      },
    );
  }

  Widget _barsChip(AppState s, int bars) {
    final active = s.activePattern.bars == bars;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => s.setPatternBars(bars),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: active
              ? BakushiTokens.red.withValues(alpha: 0.85)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '$bars bar${bars == 1 ? '' : 's'}',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: active
                ? Colors.white
                : Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  Widget _laneRow(
    BuildContext context,
    AppState s,
    int pad,
    int steps,
  ) {
    final pat = s.activePattern;
    final color = _padColor(s, pad);
    final muted = s.mutedPatternLanes.contains(pad);
    final lane = pat.lanes[pad] ?? const <bool>[];
    final padLabel = s.pads[pad].isEmpty
        ? 'Pad ${pad + 1}'
        : s.pads[pad].label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => s.togglePatternLaneMute(pad),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                muted ? Icons.volume_off : Icons.volume_up,
                size: 13,
                color: muted
                    ? BakushiTokens.danger
                    : Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 110,
            child: Text(
              padLabel,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: muted
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Opacity(
              opacity: muted ? 0.35 : 1.0,
              child: Row(
                children: [
                  for (var step = 0; step < steps; step++) ...[
                    if (step > 0 && step % 16 == 0)
                      const SizedBox(width: 6),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => s.toggleStep(pad, step),
                        child: Container(
                          height: 14,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: step < lane.length && lane[step]
                                ? color
                                : Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pulsing dot shown while the pattern loop is running.
class _PlayingPulse extends StatefulWidget {
  const _PlayingPulse();

  @override
  State<_PlayingPulse> createState() => _PlayingPulseState();
}

class _PlayingPulseState extends State<_PlayingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.3, end: 1.0).animate(_c),
      child: const Icon(
        Icons.fiber_manual_record,
        size: 10,
        color: BakushiTokens.red,
      ),
    );
  }
}
