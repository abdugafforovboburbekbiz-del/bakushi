/// View-only waveform rendering for the strip-down UI.
///
/// A single track's waveform plus a transport playhead. No draggable
/// regions, no slices, no interaction - the stem separator only needs to
/// SHOW audio.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../config.dart';

class _Peaks {
  final Float32List mins;
  final Float32List maxs;
  final int samplesPerPixel;
  const _Peaks(this.mins, this.maxs, this.samplesPerPixel);
}

/// A view-only waveform strip for one audio track with a playhead line.
class StemWaveformStrip extends StatefulWidget {
  final Float32List left;
  final Float32List right;
  final Color color;

  /// Current transport position in seconds (drives the playhead).
  final double positionSec;
  final double height;

  const StemWaveformStrip({
    super.key,
    required this.left,
    required this.right,
    required this.color,
    required this.positionSec,
    this.height = 64,
  });

  @override
  State<StemWaveformStrip> createState() => _StemWaveformStripState();
}

class _StemWaveformStripState extends State<StemWaveformStrip> {
  _Peaks? _peaks;
  int _gen = 0;
  Timer? _debounce;
  double _width = 800;

  @override
  void initState() {
    super.initState();
    _schedulePeaks();
  }

  @override
  void didUpdateWidget(covariant StemWaveformStrip old) {
    super.didUpdateWidget(old);
    if (!identical(old.left, widget.left) ||
        !identical(old.right, widget.right)) {
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
    _debounce = Timer(const Duration(milliseconds: 120), _rebuildPeaks);
  }

  /// Compute min/max peaks per pixel off the UI thread; a generation
  /// counter discards stale results when the audio or width changes.
  Future<void> _rebuildPeaks() async {
    final gen = ++_gen;
    final left = widget.left;
    final right = widget.right;
    final frames = math.min(left.length, right.length);
    final width = math.max(100.0, _width);
    final spp = math.max(1, (frames / width).ceil());
    try {
      final peaks = await Isolate.run(() {
        final buckets = math.max(1, (frames + spp - 1) ~/ spp);
        final mins = Float32List(buckets);
        final maxs = Float32List(buckets);
        for (int b = 0; b < buckets; b++) {
          final start = b * spp;
          final end = math.min(frames, start + spp);
          var mn = 0.0;
          var mx = 0.0;
          for (int i = start; i < end; i++) {
            final l = left[i];
            final r = right[i];
            if (l < mn) mn = l;
            if (l > mx) mx = l;
            if (r < mn) mn = r;
            if (r > mx) mx = r;
          }
          mins[b] = mn;
          maxs[b] = mx;
        }
        return _Peaks(mins, maxs, spp);
      });
      if (!mounted || gen != _gen) return;
      setState(() => _peaks = peaks);
    } catch (_) {
      // A failed peak computation just leaves the strip empty.
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = math.max(100.0, constraints.maxWidth);
        if ((w - _width).abs() > 8) {
          _width = w;
          _schedulePeaks();
        }
        return SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: _StripPainter(
              peaks: _peaks,
              color: widget.color,
              playheadSec: widget.positionSec,
            ),
          ),
        );
      },
    );
  }
}

class _StripPainter extends CustomPainter {
  final _Peaks? peaks;
  final Color color;
  final double playheadSec;

  const _StripPainter({
    required this.peaks,
    required this.color,
    required this.playheadSec,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final mid = h / 2;
    final amp = mid - 4;

    // Center line.
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.07)
        ..strokeWidth = 1,
    );

    final p = peaks;
    if (p != null) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      final n = p.mins.length;
      final top = Path();
      final bottom = Path();
      for (int i = 0; i < n; i++) {
        final x = i.toDouble() + 0.5;
        final yMax = mid - p.maxs[i].clamp(-1.0, 1.0).toDouble() * amp;
        final yMin = mid - p.mins[i].clamp(-1.0, 1.0).toDouble() * amp;
        if (i == 0) {
          top.moveTo(x, yMax);
          bottom.moveTo(x, yMin);
        } else {
          top.lineTo(x, yMax);
          bottom.lineTo(x, yMin);
        }
      }
      canvas.drawPath(top, paint);
      canvas.drawPath(bottom, paint);
    }

    // Playhead.
    if (playheadSec > 0) {
      final spp = p?.samplesPerPixel ?? 200;
      final x = playheadSec * AppConfig.engineSampleRate / spp;
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, h),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.85)
            ..strokeWidth = 1.2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StripPainter old) {
    return old.peaks != peaks ||
        old.color != color ||
        old.playheadSec != playheadSec;
  }
}
