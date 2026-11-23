import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart';

import '../theme/app_theme.dart';

/// Bottom strip: peak waveform with optional crop selection (0–1).
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.peaks,
    this.cropStart = 0,
    this.cropEnd = 1,
    this.showSelection = false,
    /// 0–1 within the crop (or full strip); null hides the playhead.
    this.playhead,
  });

  final Float32List peaks;
  final double cropStart;
  final double cropEnd;
  final bool showSelection;
  final double? playhead;

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
    final path = Path();
    final n = peaks.length;
    for (var i = 0; i < n; i++) {
      final x = i / math.max(1, n - 1) * size.width;
      final h = (peaks[i] / maxP) * (mid - 2);
      if (i == 0) {
        path.moveTo(x, mid - h);
      } else {
        path.lineTo(x, mid - h);
      }
    }
    for (var i = n - 1; i >= 0; i--) {
      final x = i / math.max(1, n - 1) * size.width;
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
      final x0 = cropStart.clamp(0.0, 1.0) * size.width;
      final x1 = cropEnd.clamp(0.0, 1.0) * size.width;

      // Dim outside selection.
      final dim = Paint()..color = const Color(0x99000000);
      if (x0 > 0) {
        canvas.drawRect(Rect.fromLTRB(0, 0, x0, size.height), dim);
      }
      if (x1 < size.width) {
        canvas.drawRect(Rect.fromLTRB(x1, 0, size.width, size.height), dim);
      }

      final edge = Paint()
        ..color = AppColors.gold
        ..strokeWidth = 2;
      canvas.drawLine(Offset(x0, 0), Offset(x0, size.height), edge);
      canvas.drawLine(Offset(x1, 0), Offset(x1, size.height), edge);

      // Handle grips.
      final grip = Paint()..color = AppColors.gold;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x0, mid), width: 8, height: 28),
          const Radius.circular(2),
        ),
        grip,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x1, mid), width: 8, height: 28),
          const Radius.circular(2),
        ),
        grip,
      );
    }

    _drawPlayhead(canvas, size);
  }

  void _drawPlayhead(Canvas canvas, Size size) {
    final t = playhead;
    if (t == null || peaks.isEmpty) return;
    final x0 = cropStart.clamp(0.0, 1.0) * size.width;
    final x1 = cropEnd.clamp(0.0, 1.0) * size.width;
    final span = (x1 - x0).abs() < 1 ? size.width : (x1 - x0);
    final x = x0 + t.clamp(0.0, 1.0) * span;
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
      oldDelegate.playhead != playhead;
}
