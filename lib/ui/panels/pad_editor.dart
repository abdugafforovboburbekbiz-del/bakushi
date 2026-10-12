/// Phase C: Canva-style full-source waveform crop editor for one pad.
///
/// Renders the COMPLETE source audio (stem, custom sample or starter
/// sound) as a smooth, FILLED min/max peak waveform that always fits
/// inside the canvas margins. The pad's slice is a purple crop region
/// between two thin cut lines (2 px) with grab knobs; drag a line to
/// resize, drag the body to move, or use Set Start / Set End to place a
/// line with one click. Every release re-bakes the pad buffer with
/// micro-fades and previews the slice once. Space = preview, Esc cancels
/// the pending line tool.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../widgets/slice_canvas.dart';

class PadSliceEditor extends StatefulWidget {
  final AppState state;
  final int padIndex;

  const PadSliceEditor({
    super.key,
    required this.state,
    required this.padIndex,
  });

  @override
  State<PadSliceEditor> createState() => _PadSliceEditorState();
}

class _PadSliceEditorState extends State<PadSliceEditor> {
  SlicePeaks? _peaks;
  String? _error;
  int _gen = 0;
  Timer? _debounce;
  double _width = 800;

  // Drag state: 1 = left handle, 2 = right handle, 3 = move body.
  int _dragHandle = 0;
  double _anchorPx = 0;
  int _start0 = 0;
  int _end0 = 0;

  // Set Start / Set End tools: 0 = none, 1 = next click moves the start
  // line only, 2 = next click moves the end line only.
  int _setLine = 0;

  AppState get s => widget.state;
  int get index => widget.padIndex;

  @override
  void initState() {
    super.initState();
    _schedulePeaks();
  }

  @override
  void didUpdateWidget(covariant PadSliceEditor old) {
    super.didUpdateWidget(old);
    if (old.padIndex != widget.padIndex) {
      _peaks = null;
      _error = null;
      _setLine = 0;
      _schedulePeaks();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedulePeaks() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), _rebuildPeaks);
  }

  Future<void> _rebuildPeaks() async {
    // IMPORTANT: no closure is created before the isolate call below.
    // Closures that capture `this` (setState) before Isolate.run make the
    // isolate closure share a context holding the State (which owns a
    // Timer) -> "object is unsendable". The working pattern used by
    // waveform_panel.dart has the setState ONLY after the await.
    final gen = ++_gen;
    final src = s.padSourceAudio(index);
    final pad = s.pads[index];
    final frames = (pad.isEmpty || src == null)
        ? 0
        : math.min(src.left.length, src.right.length);
    final width = math.max(200.0, _width);
    final spp = math.max(1, (frames / width).ceil());
    final left = src?.left;
    final right = src?.right;
    String? error = frames <= 0 ? 'This pad has no source audio.' : null;
    SlicePeaks? peaks;
    if (error == null) {
      final l = left!;
      final r = right!;
      debugPrint(
        '[BAKUSHI] padEdit peaks start: pad=${index + 1} '
        'frames=$frames spp=$spp',
      );
      try {
        peaks = await peaksInIsolate(l, r, frames, spp);
        debugPrint('[BAKUSHI] padEdit peaks isolate done: pad=${index + 1}');
      } catch (e) {
        debugPrint(
          '[BAKUSHI] padEdit peaks isolate failed: $e '
          '(falling back to synchronous)',
        );
        peaks = peaksSync(l, r, frames, spp);
      }
    }
    if (!mounted || gen != _gen) return;
    final p = peaks;
    final nonFlat = p != null && p.maxAbs > 1e-4;
    if (p != null) {
      debugPrint(
        '[BAKUSHI] padEdit peaks: pad=${index + 1} '
        'sourceSamples=${p.frames} '
        'spp=$spp buckets=${p.mins.length} '
        'maxAbs=${p.maxAbs.toStringAsFixed(4)} '
        'nonFlat=$nonFlat',
      );
    }
    setState(() {
      _error = error;
      if (p != null) _peaks = p;
    });
  }

  int get _sr {
    final pad = s.pads[index];
    final src = s.padSourceAudio(index);
    return src?.sampleRate ?? pad.sampleRate;
  }

  int get _frames => _peaks?.frames ?? 0;

  int get _spp => _peaks?.samplesPerPixel ?? 1;

  int get _minSliceSamples => math.max(2, (0.020 * _sr).round()); // 20 ms

  int _sampleAtPx(double px) =>
      (px * _spp).round().clamp(0, math.max(0, _frames - 1));

  double _pxAtSample(int sample) => sample / _spp;

  void _onDown(double px) {
    final p = s.pads[index];
    if (_frames <= 0) return;
    if (_setLine != 0) {
      // One-shot line tools: the next waveform click moves only that line.
      final sample = _sampleAtPx(px);
      if (_setLine == 1) {
        final maxStart = math.max(0, p.endSample - _minSliceSamples);
        s.updatePadBounds(index, math.min(sample, maxStart), p.endSample);
      } else {
        final minEnd = p.startSample + _minSliceSamples;
        s.updatePadBounds(
          index,
          p.startSample,
          math.max(minEnd, math.min(sample, _frames)),
        );
      }
      setState(() => _setLine = 0);
      s.previewPad(index);
      return;
    }
    final x1 = _pxAtSample(p.startSample);
    final x2 = _pxAtSample(p.endSample);
    const tol = 8.0; // 16 px visual target
    if ((px - x1).abs() <= tol) {
      _dragHandle = 1;
    } else if ((px - x2).abs() <= tol) {
      _dragHandle = 2;
    } else if (px > x1 && px < x2) {
      _dragHandle = 3;
    } else {
      return;
    }
    _anchorPx = px;
    _start0 = p.startSample;
    _end0 = p.endSample;
  }

  void _onMove(double px) {
    if (_dragHandle == 0) return;
    final delta = ((px - _anchorPx) * _spp).round();
    final frames = _frames;
    final minLen = _minSliceSamples;
    var start = _start0;
    var end = _end0;
    if (_dragHandle == 1) {
      start = (_start0 + delta).clamp(0, math.max(0, end - minLen));
    } else if (_dragHandle == 2) {
      end = (_end0 + delta).clamp(start + minLen, frames);
    } else {
      final dur = end - start;
      start = (_start0 + delta).clamp(0, frames - dur);
      end = start + dur;
    }
    s.updatePadBounds(index, start, end);
  }

  void _onUp() {
    if (_dragHandle == 0) return;
    _dragHandle = 0;
    s.previewPad(index); // re-bake already happened live; preview once
  }

  void _preview() => s.previewPad(index);

  void _stop() => s.stopPadNow(index);

  /// Reset Slice: restore the originally assigned range. Confirms first
  /// when the pad has manual edits.
  Future<void> _resetSlice() async {
    if (s.pads[index].edited) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: BakushiTokens.panel2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text('Reset slice?'),
          content: const Text(
            'This pad has manual edits. Reset returns the slice to its '
            'originally assigned range. Current edits will be lost.',
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
      if (ok != true) return;
    }
    s.resetPadSlice(index);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.space) {
        _preview();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _setLine = 0);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  static String _cap(String name) =>
      name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';

  @override
  Widget build(BuildContext context) {
    final pad = s.pads[index];
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = math.max(200.0, constraints.maxWidth);
            if ((w - _width).abs() > 8) {
              _width = w;
              _schedulePeaks();
            }
            final sourceName = pad.custom
                ? (pad.customSourcePath ?? '')
                      .split(Platform.pathSeparator)
                      .last
                : pad.stemName ?? '?';
            final kind = pad.starter
                ? 'Starter Kit'
                : pad.custom
                ? 'Custom'
                : _cap(pad.stemName ?? '?');
            final fx = <String>[
              if (pad.pitchSemitones != 0)
                '${pad.pitchSemitones > 0 ? '+' : ''}'
                    '${pad.pitchSemitones} st',
              if (pad.reverse) 'REV',
              if ((pad.gain - 1.0).abs() >= 0.001)
                'gain ${(pad.gain * 100).round()}%',
            ];
            final header =
                'Pad ${index + 1} · $kind · '
                '${pad.durationSeconds.toStringAsFixed(2)} s'
                '${fx.isEmpty ? '' : ' · ${fx.join(' · ')}'} · '
                'Source: ${pad.custom ? sourceName : '$kind source'}';
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: BakushiTokens.red.withValues(alpha: 0.35),
                ),
              ),
              child: Focus(
                autofocus: true,
                onKeyEvent: _onKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 380),
                          child: Text(
                            header,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (_setLine != 0)
                          Text(
                            _setLine == 1
                                ? 'set start: click the waveform'
                                : 'set end: click the waveform',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        _toolButton(
                          Icons.play_arrow,
                          'Preview',
                          _preview,
                          active: false,
                        ),
                        _toolButton(Icons.stop, 'Stop', _stop, active: false),
                        _toolButton(
                          Icons.first_page,
                          'Set Start',
                          () =>
                              setState(() => _setLine = _setLine == 1 ? 0 : 1),
                          active: _setLine == 1,
                        ),
                        _toolButton(
                          Icons.last_page,
                          'Set End',
                          () =>
                              setState(() => _setLine = _setLine == 2 ? 0 : 2),
                          active: _setLine == 2,
                        ),
                        _toolButton(
                          Icons.restart_alt,
                          'Reset Slice',
                          _resetSlice,
                          active: false,
                        ),
                        _toolButton(
                          Icons.check,
                          'Done',
                          s.endPadEdit,
                          active: false,
                          filled: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Simple bounded readout - no on-canvas labels, nothing
                    // can overflow the panel borders.
                    Wrap(
                      spacing: 14,
                      runSpacing: 2,
                      children: [
                        _readout(
                          'Start',
                          '${(pad.startSample / _sr).toStringAsFixed(2)} s',
                        ),
                        _readout(
                          'End',
                          '${(pad.endSample / _sr).toStringAsFixed(2)} s',
                        ),
                        _readout(
                          'Duration',
                          '${pad.durationSeconds.toStringAsFixed(2)} s',
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 180,
                      width: double.infinity,
                      child: _buildWaveform(),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'drag the cut lines to resize · drag the purple area '
                      'to move · space = preview',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _toolButton(
    IconData icon,
    String label,
    VoidCallback onPressed, {
    required bool active,
    bool filled = false,
  }) {
    if (filled) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        foregroundColor: active ? BakushiTokens.amber : Colors.white70,
        side: BorderSide(
          color: active
              ? BakushiTokens.amber
              : Colors.white.withValues(alpha: 0.18),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _readout(String label, String value) {
    return Text.rich(
      TextSpan(
        text: '$label ',
        style: TextStyle(
          fontSize: 11,
          color: Colors.white.withValues(alpha: 0.5),
        ),
        children: [
          TextSpan(
            text: value,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildWaveform() {
    final peaks = _peaks;
    final pad = s.pads[index];
    if (_error != null) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _error!,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    if (peaks == null) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 8),
            Text(
              'Computing waveform ...',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      );
    }
    return Listener(
      onPointerDown: (e) => _onDown(e.localPosition.dx),
      onPointerMove: (e) => _onMove(e.localPosition.dx),
      onPointerUp: (_) => _onUp(),
      onPointerCancel: (_) => _onUp(),
      child: CustomPaint(
        painter: SlicePainter(
          peaks: peaks,
          color: StemColors.forStem(pad.stemName ?? 'other'),
          sliceStart: pad.startSample,
          sliceEnd: pad.endSample,
          pendingLine: _setLine == 1
              ? _pxAtSample(pad.startSample)
              : _setLine == 2
              ? _pxAtSample(pad.endSample)
              : null,
        ),
        size: Size.infinite,
      ),
    );
  }
}
