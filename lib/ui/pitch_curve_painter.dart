import 'package:material_ui/material_ui.dart';

import '../music/pitch_envelope.dart';
import '../theme/app_theme.dart';

class PitchCurvePainter extends CustomPainter {
  PitchCurvePainter({
    required this.points,
    this.compare,
  });

  final List<PitchPoint> points;
  final List<PitchPoint>? compare;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.peacock.withValues(alpha: 0.25),
          AppColors.teak.withValues(alpha: 0.9),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)),
      bg,
    );

    if (points.isEmpty) return;

    double minC = points.first.cents;
    double maxC = points.first.cents;
    for (final p in points) {
      if (p.cents < minC) minC = p.cents;
      if (p.cents > maxC) maxC = p.cents;
    }
    if (compare != null) {
      for (final p in compare!) {
        if (p.cents < minC) minC = p.cents;
        if (p.cents > maxC) maxC = p.cents;
      }
    }
    final pad = 40.0;
    minC -= pad;
    maxC += pad;
    final span = (maxC - minC).abs() < 1 ? 1.0 : (maxC - minC);

    Offset map(PitchPoint p) {
      final x = p.t * size.width;
      final y = size.height - ((p.cents - minC) / span) * size.height;
      return Offset(x, y);
    }

    void drawCurve(List<PitchPoint> pts, Color color, double width) {
      if (pts.length < 2) return;
      final path = Path()..moveTo(map(pts.first).dx, map(pts.first).dy);
      for (var i = 1; i < pts.length; i++) {
        final a = map(pts[i - 1]);
        final b = map(pts[i]);
        final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
        path.quadraticBezierTo(a.dx, a.dy, mid.dx, mid.dy);
      }
      path.lineTo(map(pts.last).dx, map(pts.last).dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Grid lines at Sa / Pa-ish hints.
    final gridPaint = Paint()
      ..color = AppColors.mist.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (final cents in [0.0, 702.0, 1200.0]) {
      if (cents < minC || cents > maxC) continue;
      final y = size.height - ((cents - minC) / span) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (compare != null) {
      drawCurve(compare!, AppColors.mist.withValues(alpha: 0.35), 2);
    }
    drawCurve(points, AppColors.goldSoft, 2.6);
  }

  @override
  bool shouldRepaint(covariant PitchCurvePainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.compare != compare;
  }
}
