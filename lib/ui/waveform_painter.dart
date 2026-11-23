import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart';

import '../theme/app_theme.dart';

/// Visible window over the full-file time axis (0–1). Scroll-wheel zoom + pan.
class WaveformViewport {
  WaveformViewport({
    this.zoom = 1.0,
    this.t0 = 0.0,
  });

  static const double minZoom = 1.0;
  static const double maxZoom = 64.0;

  double zoom;

  /// Left edge of the view in full-file time (0–1).
  double t0;

  double get span => 1.0 / zoom;

  void clampTo() {
    zoom = zoom.clamp(minZoom, maxZoom);
    final s = span;
    final maxT0 = math.max(0.0, 1.0 - s);
    t0 = t0.clamp(0.0, maxT0);
  }

  /// Zoom toward [local] so the file-time under the pointer stays fixed.
  void zoomAt({
    required Size size,
    required Offset local,
    required double factor,
  }) {
    if (size.width <= 0) return;
    final focus = timeAt(local, size);
    final ux = (local.dx / size.width).clamp(0.0, 1.0);
    zoom = (zoom * factor).clamp(minZoom, maxZoom);
    t0 = focus - ux * span;
    clampTo();
  }

  /// Pan by a screen-pixel drag delta. Content follows the pointer.
  void panBy({
    required Size size,
    required Offset pixelDelta,
  }) {
    if (size.width <= 0) return;
    t0 -= (pixelDelta.dx / size.width) * span;
    clampTo();
  }

  double timeAt(Offset local, Size size) {
    final u = (local.dx / size.width).clamp(0.0, 1.0);
    return t0 + u * span;
  }

  double xFor(double fileT, Size size) {
    final s = span;
    if (s < 1e-12) return 0;
    return ((fileT - t0) / s) * size.width;
  }

  void reset() {
    zoom = 1.0;
    t0 = 0.0;
  }
}

/// Bottom strip: peak waveform with optional crop selection (0–1).
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.peaks,
    this.cropStart = 0,
    this.cropEnd = 1,
    this.showSelection = false,
    /// 0–1 within the crop (or full strip); null hides the playhead.
    this.playhead,
    WaveformViewport? viewport,
  }) : viewport = viewport ?? WaveformViewport();

  final Float32List peaks;
  final double cropStart;
  final double cropEnd;
  final bool showSelection;
  final double? playhead;
  final WaveformViewport viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = AppColors.teakDeep.withValues(alpha: 0.85);
    canvas.drawRect(Offset.zero & size, bg);

    if (peaks.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'Drop WAV/MP3 — crop below, then Sync to build the pitch line',
          style: TextStyle(color: AppColors.mist, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 16);
      tp.paint(canvas, Offset(12, (size.height - tp.height) / 2));
      return;
    }

    var maxP = 1e-6;
    for (final p in peaks) {
      if (p > maxP) maxP = p;
    }

    final mid = size.height / 2;
    final n = peaks.length;
    final tStart = viewport.t0;
    final tEnd = viewport.t0 + viewport.span;
    final i0 = (tStart * (n - 1)).floor().clamp(0, n - 1);
    final i1 = (tEnd * (n - 1)).ceil().clamp(0, n - 1);

    final path = Path();
    for (var i = i0; i <= i1; i++) {
      final fileT = n <= 1 ? 0.0 : i / (n - 1);
      final x = viewport.xFor(fileT, size);
      final h = (peaks[i] / maxP) * (mid - 2);
      if (i == i0) {
        path.moveTo(x, mid - h);
      } else {
        path.lineTo(x, mid - h);
      }
    }
    for (var i = i1; i >= i0; i--) {
      final fileT = n <= 1 ? 0.0 : i / (n - 1);
      final x = viewport.xFor(fileT, size);
      final h = (peaks[i] / maxP) * (mid - 2);
      path.lineTo(x, mid + h);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = AppColors.peacock.withValues(alpha: 0.45),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.gold.withValues(alpha: 0.75)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );

    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = AppColors.mist.withValues(alpha: 0.25)
        ..strokeWidth = 1,
    );

    if (showSelection && peaks.isNotEmpty) {
      final x0 = viewport.xFor(cropStart.clamp(0.0, 1.0), size);
      final x1 = viewport.xFor(cropEnd.clamp(0.0, 1.0), size);

      // Dim outside selection (within the visible strip).
      final dim = Paint()..color = const Color(0x99000000);
      final left = math.min(x0, x1);
      final right = math.max(x0, x1);
      if (left > 0) {
        canvas.drawRect(Rect.fromLTRB(0, 0, left, size.height), dim);
      }
      if (right < size.width) {
        canvas.drawRect(
          Rect.fromLTRB(right, 0, size.width, size.height),
          dim,
        );
      }

      final edge = Paint()
        ..color = AppColors.gold
        ..strokeWidth = 2;
      canvas.drawLine(Offset(x0, 0), Offset(x0, size.height), edge);
      canvas.drawLine(Offset(x1, 0), Offset(x1, size.height), edge);

      // Handle grips (only if on-screen).
      final grip = Paint()..color = AppColors.gold;
      if (x0 >= -4 && x0 <= size.width + 4) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x0, mid), width: 8, height: 28),
            const Radius.circular(2),
          ),
          grip,
        );
      }
      if (x1 >= -4 && x1 <= size.width + 4) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x1, mid), width: 8, height: 28),
            const Radius.circular(2),
          ),
          grip,
        );
      }
    }

    _drawPlayhead(canvas, size);
  }

  void _drawPlayhead(Canvas canvas, Size size) {
    final t = playhead;
    if (t == null || peaks.isEmpty) return;
    final cropSpan = (cropEnd - cropStart).clamp(1e-6, 1.0);
    final fileT = cropStart + t.clamp(0.0, 1.0) * cropSpan;
    final x = viewport.xFor(fileT, size);
    if (x < -2 || x > size.width + 2) return;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = const Color(0x800088FF) // blue @ 50%
        ..strokeWidth = 1.5
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) =>
      !identical(oldDelegate.peaks, peaks) ||
      oldDelegate.cropStart != cropStart ||
      oldDelegate.cropEnd != cropEnd ||
      oldDelegate.showSelection != showSelection ||
      oldDelegate.playhead != playhead ||
      oldDelegate.viewport.zoom != viewport.zoom ||
      oldDelegate.viewport.t0 != viewport.t0;
}
