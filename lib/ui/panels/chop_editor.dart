/// Task 4B: chop the ORIGINAL full mix - NO separation, NO BPM, NO
/// transient calls. Reuses the shared slice canvas. Pads hold bounds +
/// baked slices only; the source stays the one shared original PCM.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../audio/dsp.dart';
import '../../config.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../widgets/slice_canvas.dart';

class ChopEditor extends StatefulWidget {
  final AppState state;
  const ChopEditor({super.key, required this.state});

  @override
  State<ChopEditor> createState() => _ChopEditorState();
}

class _ChopEditorState extends State<ChopEditor> {
  SlicePeaks? _peaks;
  String? _error;
  int _gen = 0;
  Timer? _debounce;
  double _width = 800;

  // Local selection (not applied to any pad until the user assigns it).
  int _selStart = 0;
  int _selEnd = 0;
  bool _initSelection = false;

  // Set Start / Set End tools: 0 = none, 1 = start line, 2 = end line.
  int _setLine = 0;

  // Drag state: 1 = start line, 2 = end line, 3 = move body.
  int _dragHandle = 0;
  double _anchorPx = 0;
  int _start0 = 0;
  int _end0 = 0;

  AppState get s => widget.state;

  int get _sr => s.original?.sampleRate ?? 44100;
  int get _frames => _peaks?.frames ?? 0;
  int get _spp => _peaks?.samplesPerPixel ?? 1;
  int get _minSlice => math.max(2, (0.020 * _sr).round()); // 20 ms

  @override
  void initState() {
    super.initState();
    _schedulePeaks();
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
    final gen = ++_gen;
    final o = s.original;
    final frames = o == null ? 0 : math.min(o.left.length, o.right.length);
    final width = math.max(200.0, _width);
    final spp = math.max(1, (frames / width).ceil());
    String? error = frames <= 0 ? 'No original audio loaded.' : null;
    SlicePeaks? peaks;
    if (error == null) {
      final l = o!.left;
      final r = o.right;
      try {
        peaks = await peaksInIsolate(l, r, frames, spp);
      } catch (e) {
        debugPrint('[BAKUSHI] chop peaks isolate failed: $e');
        peaks = peaksSync(l, r, frames, spp);
      }
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _error = error;
      if (peaks != null) {
        _peaks = peaks;
        if (!_initSelection && peaks.frames > 0) {
          _selStart = 0;
          _selEnd = peaks.frames;
          _initSelection = true;
        }
      }
    });
  }

  int _sampleAtPx(double px) =>
      (px * _spp).round().clamp(0, math.max(0, _frames - 1));

  double _pxAtSample(int sample) => sample / _spp;

  void _onDown(double px) {
    if (_frames <= 0) return;
    if (_setLine != 0) {
      final sample = _sampleAtPx(px);
      setState(() {
        if (_setLine == 1) {
          _selStart = math.min(sample, math.max(0, _selEnd - _minSlice));
        } else {
          _selEnd = math.max(_selStart + _minSlice, math.min(sample, _frames));
        }
        _setLine = 0;
      });
      return;
    }
    final x1 = _pxAtSample(_selStart);
    final x2 = _pxAtSample(_selEnd);
    const tol = 8.0; // 16 px hit target
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
    _start0 = _selStart;
    _end0 = _selEnd;
  }

  void _onMove(double px) {
    if (_dragHandle == 0) return;
    final delta = ((px - _anchorPx) * _spp).round();
    setState(() {
      if (_dragHandle == 1) {
        _selStart = (_start0 + delta).clamp(0, math.max(0, _end0 - _minSlice));
      } else if (_dragHandle == 2) {
        _selEnd = (_end0 + delta).clamp(_start0 + _minSlice, _frames);
      } else {
        final dur = _end0 - _start0;
        _selStart = (_start0 + delta).clamp(0, _frames - dur);
        _selEnd = _selStart + dur;
      }
    });
  }

  void _onUp() => _dragHandle = 0;

  /// One-shot neutral preview of the current selection on voice 210.
  void _preview() {
    final o = s.original;
    if (o == null || _frames <= 0) return;
    final fade = (AppConfig.padFadeMsDefault / 1000 * o.sampleRate).round();
    final l = createSliceBuffer(o.left, _selStart, _selEnd, fade);
    final r = createSliceBuffer(o.right, _selStart, _selEnd, fade);
    s.engine.loadVoice(AppConfig.recordingPreviewVoiceId, l, r);
    s.engine.playVoice(AppConfig.recordingPreviewVoiceId);
  }

  void _stop() => s.engine.stopVoice(AppConfig.recordingPreviewVoiceId);

  void _resetSelection() {
    setState(() {
      _selStart = 0;
      _selEnd = _frames;
      _setLine = 0;
    });
  }

  /// Assign with the "never overwrite" rule; if every pad is filled the
  /// user picks which pad to replace.
  Future<void> _assign(bool toSelected) async {
    final assigned = toSelected
        ? s.assignChopToSelected(_selStart, _selEnd)
        : s.assignChopToNextEmpty(_selStart, _selEnd);
    if (assigned == null && mounted) {
      // All pads filled: ask which pad to replace (never auto-overwrite).
      final choice = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: BakushiTokens.panel2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text('All pads are filled'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Choose the pad to replace with this chop.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < 16; i++) ...[
                  ListTile(
                    dense: true,
                    title: Text(
                      'Pad ${i + 1} · ${s.pads[i].label.isEmpty ? 'empty' : s.pads[i].label}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(context, i),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
      if (choice != null) {
        s.assignChopToPad(choice, _selStart, _selEnd);
      }
    }
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final durSec = _frames / _sr;
        final markers = <SliceMarker>[
          for (var i = 0; i < 16; i++)
            if (s.pads[i].original && !s.pads[i].isEmpty)
              SliceMarker(
                sample: s.pads[i].startSample,
                label: 'P${i + 1}',
                color: StemColors.originalChop,
              ),
        ];
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: StemColors.originalChop.withValues(alpha: 0.5),
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
                    Text(
                      'Source: Original Song · ${s.originalSongTitle()}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Duration ${durSec.toStringAsFixed(1)} s',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.55),
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
                    _toolButton(Icons.play_arrow, 'Preview', _preview),
                    _toolButton(Icons.stop, 'Stop', _stop),
                    _toolButton(
                      Icons.first_page,
                      'Set Start',
                      () => setState(() => _setLine = _setLine == 1 ? 0 : 1),
                      active: _setLine == 1,
                    ),
                    _toolButton(
                      Icons.last_page,
                      'Set End',
                      () => setState(() => _setLine = _setLine == 2 ? 0 : 2),
                      active: _setLine == 2,
                    ),
                    _toolButton(
                      Icons.restart_alt,
                      'Reset Selection',
                      _resetSelection,
                    ),
                    _toolButton(
                      Icons.check,
                      'Assign to Selected Pad',
                      () => _assign(true),
                      filled: true,
                    ),
                    _toolButton(
                      Icons.add,
                      'Assign to Next Empty Pad',
                      () => _assign(false),
                      filled: true,
                    ),
                    _toolButton(Icons.done, 'Done', s.endChopEditor),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 14,
                  runSpacing: 2,
                  children: [
                    _readout(
                      'Start',
                      '${(_selStart / _sr).toStringAsFixed(2)} s',
                    ),
                    _readout('End', '${(_selEnd / _sr).toStringAsFixed(2)} s'),
                    _readout(
                      'Duration',
                      '${((_selEnd - _selStart) / _sr).toStringAsFixed(2)} s',
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = math.max(200.0, constraints.maxWidth);
                      if ((w - _width).abs() > 8) {
                        _width = w;
                        _schedulePeaks();
                      }
                      return _buildWaveform(markers);
                    },
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'drag the cut lines to resize · drag the teal area to '
                  'move · space = preview · P<n> markers = assigned pads',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Use audio you own or have permission to sample. '
                  'Releasing music containing copyrighted recordings may '
                  'require rights clearance.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWaveform(List<SliceMarker> markers) {
    final peaks = _peaks;
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
          color: StemColors.originalChop,
          sliceStart: _selStart,
          sliceEnd: _selEnd,
          pendingLine: _setLine == 1
              ? _pxAtSample(_selStart)
              : _setLine == 2
              ? _pxAtSample(_selEnd)
              : null,
          markers: markers,
        ),
        size: Size.infinite,
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

  Widget _toolButton(
    IconData icon,
    String label,
    VoidCallback onPressed, {
    bool active = false,
    bool filled = false,
  }) {
    if (filled) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
}
