/// Shared slice-canvas rendering: filled min/max peak waveform with two
/// cut lines + grab knobs, purple selection, dimmed outside regions and
/// optional region markers. Used by BOTH the pad slice editor and the
/// original-chop editor (Task 4B) - one painter, identical behavior.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Min/max PCM peaks for a source, bucketed to ~1 bucket per pixel.
class SlicePeaks {
  final Float32List mins;
  final Float32List maxs;
  final int samplesPerPixel;
  final int frames;
  final double maxAbs;
  const SlicePeaks(
    this.mins,
    this.maxs,
    this.samplesPerPixel,
    this.frames,
    this.maxAbs,
  );
}

/// Runs [peaksSync] in a worker isolate. The closure is created HERE, in
/// a top-level synchronous function, so its context only holds the four
/// parameters - creating the closure inside an async State method binds
/// it to the async frame context (which holds `this` + its Timer) and
/// makes it unsendable.
Future<SlicePeaks> peaksInIsolate(
  Float32List l,
  Float32List r,
  int frames,
  int spp,
) {
  return Isolate.run(() => peaksSync(l, r, frames, spp));
}

/// Synchronous fallback peak computation (top-level: cannot capture the
/// State). Used if Isolate.run rejects the closure for any reason.
SlicePeaks peaksSync(Float32List l, Float32List r, int frames, int spp) {
  final buckets = math.max(1, (frames + spp - 1) ~/ spp);
  final mins = Float32List(buckets);
  final maxs = Float32List(buckets);
  var maxAbs = 0.0;
  for (int b = 0; b < buckets; b++) {
    final start = b * spp;
    final end = math.min(frames, start + spp);
    var mn = 0.0;
    var mx = 0.0;
    for (int i = start; i < end; i++) {
      final lv = l[i];
      final rv = r[i];
      if (lv < mn) mn = lv;
      if (lv > mx) mx = lv;
      if (rv < mn) mn = rv;
      if (rv > mx) mx = rv;
    }
    mins[b] = mn;
    maxs[b] = mx;
    final amn = mn.abs();
    final amx = mx.abs();
    if (amn > maxAbs) maxAbs = amn;
    if (amx > maxAbs) maxAbs = amx;
  }
  return SlicePeaks(mins, maxs, spp, frames, maxAbs);
}

/// A small labelled region marker drawn above the waveform (used by the
/// chop editor to show existing original-pad regions).
class SliceMarker {
  final int sample;
  final String label;
  final Color color;
  const SliceMarker({
    required this.sample,
    required this.label,
    required this.color,
  });
}

/// Canva-style crop painter: smooth FILLED waveform inside 12 px
/// margins, 2 px cut lines with grab knobs, purple selection, dimmed
/// outside areas, optional pending line and region markers.
class SlicePainter extends CustomPainter {
  final SlicePeaks peaks;
  final Color color;
  final int sliceStart;
  final int sliceEnd;
  final double? pendingLine;
  final List<SliceMarker> markers;

  const SlicePainter({
    required this.peaks,
    required this.color,
    required this.sliceStart,
    required this.sliceEnd,
    this.pendingLine,
    this.markers = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final w = size.width;
    final mid = h / 2;
    // Inner margin: the waveform always stays INSIDE the canvas borders.
    const margin = 12.0;
    final amp = math.max(24.0, mid - margin);
    final spp = peaks.samplesPerPixel;

    // Background + centre line.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.30),
    );
    canvas.drawLine(
      Offset(0, mid),
      Offset(w, mid),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..strokeWidth = 1,
    );

    // Smooth FILLED waveform: one closed path across the maxes and back
    // along the mins, filled with a vertical gradient in the source
    // color, normalized by maxAbs and clamped INSIDE the margins.
    final n = peaks.mins.length;
    if (n > 0) {
      final scale = peaks.maxAbs > 0.0005 ? peaks.maxAbs : 1.0;
      final ysTop = Float32List(n);
      final ysBottom = Float32List(n);
      for (var b = 0; b < n; b++) {
        ysTop[b] = (mid - peaks.maxs[b] / scale * amp).clamp(
          margin,
          h - margin,
        );
        ysBottom[b] = (mid - peaks.mins[b] / scale * amp).clamp(
          margin,
          h - margin,
        );
      }
      final fill = Path()..moveTo(0, ysTop[0]);
      for (var b = 1; b < n; b++) {
        fill.quadraticBezierTo(
          (b - 1).toDouble(),
          ysTop[b - 1],
          b - 0.5,
          (ysTop[b - 1] + ysTop[b]) / 2,
        );
      }
      fill.lineTo((n - 1).toDouble(), ysTop[n - 1]);
      fill.lineTo((n - 1).toDouble(), ysBottom[n - 1]);
      for (var b = n - 2; b >= 0; b--) {
        fill.quadraticBezierTo(
          (b + 1).toDouble(),
          ysBottom[b + 1],
          b + 0.5,
          (ysBottom[b + 1] + ysBottom[b]) / 2,
        );
      }
      fill.close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.10),
              color.withValues(alpha: 0.45),
              color.withValues(alpha: 0.10),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(Offset.zero & size)
          ..style = PaintingStyle.fill,
      );
      // Soft outline along the top edge only (the "max" silhouette).
      final edge = Path()..moveTo(0, ysTop[0]);
      for (var b = 1; b < n; b++) {
        edge.quadraticBezierTo(
          (b - 1).toDouble(),
          ysTop[b - 1],
          b - 0.5,
          (ysTop[b - 1] + ysTop[b]) / 2,
        );
      }
      edge.lineTo((n - 1).toDouble(), ysTop[n - 1]);
      canvas.drawPath(
        edge,
        Paint()
          ..color = color.withValues(alpha: 0.95)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round,
      );
    }

    // Region markers (existing original-pad regions in the chop editor).
    for (final m in markers) {
      final x = (m.sample / spp).clamp(0.0, w).toDouble();
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, h),
        Paint()
          ..color = m.color.withValues(alpha: 0.55)
          ..strokeWidth = 1,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: m.label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: m.color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 3, 0));
    }

    // Selection region.
    final x1 = (sliceStart / spp).clamp(0.0, w).toDouble();
    final x2 = (sliceEnd / spp).clamp(0.0, w).toDouble();
    if (x2 > x1) {
      // Dim the outside areas.
      canvas.drawRect(
        Rect.fromLTRB(0, 0, x1, h),
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      );
      canvas.drawRect(
        Rect.fromLTRB(x2, 0, w, h),
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      );
      // Purple selection tint + border.
      final rect = Rect.fromLTRB(x1, 4, x2, h - 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = BakushiTokens.red.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      // Slim 2 px cut lines + small rounded grab knobs at the top. The
      // invisible hit area stays ~16 px wide (Listener tolerance).
      final linePaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.95)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(x1, 0), Offset(x1, h), linePaint);
      canvas.drawLine(Offset(x2, 0), Offset(x2, h), linePaint);
      final knobPaint = Paint()
        ..color = BakushiTokens.redSoft
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x1, 15), width: 8, height: 26),
          const Radius.circular(4),
        ),
        knobPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x2, 15), width: 8, height: 26),
          const Radius.circular(4),
        ),
        knobPaint,
      );
    }

    // Pending Set Start / Set End target line.
    final px = pendingLine;
    if (px != null) {
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, h),
        Paint()
          ..color = BakushiTokens.amber
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SlicePainter old) {
    return old.peaks != peaks ||
        old.sliceStart != sliceStart ||
        old.sliceEnd != sliceEnd ||
        old.pendingLine != pendingLine ||
        old.markers != markers ||
        old.color != color;
  }
}
