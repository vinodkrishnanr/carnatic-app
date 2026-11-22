import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../music/editable_raga.dart';
import '../theme/app_theme.dart';

/// Visible window over the beat × sargam plane (scroll-wheel zoom).
class GridViewport {
  GridViewport({
    this.zoom = 1.0,
    this.beat0 = 0.0,
    double? cents0,
  }) : cents0 = cents0 ?? 0.0;

  static const double minZoom = 0.5;
  static const double maxZoom = 16.0;

  double zoom;

  /// Left edge of the view in beats.
  double beat0;

  /// Bottom edge of the view in cents-from-Sa.
  double cents0;

  double beatSpan(EditableRaga raga) => raga.totalBeats / zoom;

  double centsSpan(EditableRaga raga) {
    final full = (raga.maxCents - raga.minCents).abs();
    return (full < 1e-6 ? 1.0 : full) / zoom;
  }

  void clampTo(EditableRaga raga) {
    zoom = zoom.clamp(minZoom, maxZoom);
    final bSpan = beatSpan(raga);
    final cSpan = centsSpan(raga);
    final maxBeat0 = math.max(0.0, raga.totalBeats - bSpan);
    final minC = raga.minCents;
    final maxC0 = math.max(minC, raga.maxCents - cSpan);
    beat0 = beat0.clamp(0.0, maxBeat0);
    cents0 = cents0.clamp(minC, maxC0);
  }

  /// Zoom toward [local] so the beat/cents under the pointer stay fixed.
  void zoomAt({
    required EditableRaga raga,
    required Size size,
    required Offset local,
    required double factor,
  }) {
    final focusBeat = beatAt(local, size, raga);
    final focusCents = centsAt(local, size, raga);
    final ux = (local.dx / size.width).clamp(0.0, 1.0);
    final uy = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    zoom = (zoom * factor).clamp(minZoom, maxZoom);
    beat0 = focusBeat - ux * beatSpan(raga);
    cents0 = focusCents - uy * centsSpan(raga);
    clampTo(raga);
  }

  /// Pan by a screen-pixel drag delta (empty-grid drag). Content follows the pointer.
  void panBy({
    required EditableRaga raga,
    required Size size,
    required Offset pixelDelta,
  }) {
    if (size.width <= 0 || size.height <= 0) return;
    beat0 -= (pixelDelta.dx / size.width) * beatSpan(raga);
    cents0 += (pixelDelta.dy / size.height) * centsSpan(raga);
    clampTo(raga);
  }

  double beatAt(Offset local, Size size, EditableRaga raga) {
    final u = (local.dx / size.width).clamp(0.0, 1.0);
    return beat0 + u * beatSpan(raga);
  }

  double centsAt(Offset local, Size size, EditableRaga raga) {
    final u = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    return cents0 + u * centsSpan(raga);
  }

  Offset offsetFor(double beat, double cents, Size size, EditableRaga raga) {
    final bSpan = beatSpan(raga);
    final cSpan = centsSpan(raga);
    final x = ((beat - beat0) / bSpan) * size.width;
    final y = size.height - ((cents - cents0) / cSpan) * size.height;
    return Offset(x, y);
  }
}

/// Beat (X) × sargam/cents (Y) grid with the drawn pitch curve.
class RagaGridPainter extends CustomPainter {
  RagaGridPainter({
    required this.raga,
    required this.laneLabels,
    required this.viewport,
    this.activeEdgeDest,
  });

  final EditableRaga raga;
  final List<(double cents, String label)> laneLabels;
  final GridViewport viewport;

  /// Destination point index of the edge being bent (highlight).
  final int? activeEdgeDest;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = AppColors.teak.withValues(alpha: 0.85);
    canvas.drawRect(Offset.zero & size, bg);

    final beat0 = viewport.beat0;
    final beatEnd = beat0 + viewport.beatSpan(raga);
    final cents0 = viewport.cents0;
    final centsEnd = cents0 + viewport.centsSpan(raga);
    final bSpan = beatEnd - beat0;
    final cSpan = (centsEnd - cents0).abs() < 1e-6 ? 1.0 : (centsEnd - cents0);

    double yFor(double cents) =>
        size.height - ((cents - cents0) / cSpan) * size.height;
    double xFor(double beat) => ((beat - beat0) / bSpan) * size.width;

    // Vertical beat lines.
    final beatPaint = Paint()
      ..color = AppColors.mist.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    final barPaint = Paint()
      ..color = AppColors.mist.withValues(alpha: 0.28)
      ..strokeWidth = 1.2;
    final beatStart = beat0.floor();
    final beatLast = beatEnd.ceil();
    for (var b = beatStart; b <= beatLast; b++) {
      if (b < 0) continue;
      final x = xFor(b.toDouble());
      if (x < -1 || x > size.width + 1) continue;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        b % 4 == 0 ? barPaint : beatPaint,
      );
    }

    // Horizontal sargam lanes.
    final lanePaint = Paint()
      ..color = AppColors.peacockBright.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final labelStyle = TextStyle(
      color: AppColors.sand.withValues(alpha: 0.75),
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    for (final (cents, label) in laneLabels) {
      if (cents < cents0 - 1 || cents > centsEnd + 1) continue;
      final y = yFor(cents);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), lanePaint);
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, y - tp.height - 2));
    }

    // Snap micro-grid when locked: beat subdivisions + pitch steps between
    // sargam lanes (JI swaras are not on an ET lattice — lanes are the Y grid).
    if (raga.gridLock) {
      final step = raga.toneSnap.centsStep;
      final micro = Paint()
        ..color = AppColors.mist.withValues(alpha: 0.06)
        ..strokeWidth = 0.6;
      final lanes = raga.scaleCents;
      final anchors = <double>[
        if (lanes.isEmpty || lanes.first > cents0) cents0,
        ...lanes,
        if (lanes.isEmpty || lanes.last < centsEnd) centsEnd,
      ];
      for (var i = 0; i < anchors.length - 1; i++) {
        final a = anchors[i];
        final b = anchors[i + 1];
        for (var c = a + step; c < b - 1e-6; c += step) {
          if (c < cents0 - 1 || c > centsEnd + 1) continue;
          final y = yFor(c);
          canvas.drawLine(Offset(0, y), Offset(size.width, y), micro);
        }
      }
      final bStep = raga.beatSnap;
      for (var b = snapCeil(beat0, bStep); b <= beatEnd + 1e-9; b += bStep) {
        final x = xFor(b);
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), micro);
      }
    }

    final pts = List<CurvePoint>.from(raga.points)
      ..sort((a, b) => a.beat.compareTo(b.beat));
    if (pts.isEmpty) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final path = Path();
    path.moveTo(xFor(pts.first.beat), yFor(pts.first.cents));
    for (var i = 1; i < pts.length; i++) {
      final prev = pts[i - 1];
      final next = pts[i];
      if (next.hasBend) {
        path.quadraticBezierTo(
          xFor(next.bendBeat!),
          yFor(next.bendCents!),
          xFor(next.beat),
          yFor(next.cents),
        );
      } else {
        // Stepped: hold then jump.
        path.lineTo(xFor(next.beat), yFor(prev.cents));
        path.lineTo(xFor(next.beat), yFor(next.cents));
      }
    }
    final stroke = Paint()
      ..color = AppColors.gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);

    // Edge bend handles (mid elbow or control).
    final handleFill = Paint()..color = AppColors.peacockBright;
    final handleActive = Paint()..color = AppColors.gold;
    final handleRing = Paint()
      ..color = AppColors.sand.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final Offset handle;
      if (b.hasBend) {
        handle = Offset(xFor(b.bendBeat!), yFor(b.bendCents!));
        // Guide lines to anchors.
        final guide = Paint()
          ..color = AppColors.mist.withValues(alpha: 0.35)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke;
        canvas.drawLine(
          Offset(xFor(a.beat), yFor(a.cents)),
          handle,
          guide,
        );
        canvas.drawLine(
          handle,
          Offset(xFor(b.beat), yFor(b.cents)),
          guide,
        );
      } else {
        // Default elbow of the step path.
        handle = Offset(xFor(b.beat), yFor(a.cents));
      }
      // Map sorted edge dest → live list index for highlight.
      final destLive = raga.points.indexWhere(
        (p) =>
            identical(p, b) ||
            (p.beat == b.beat &&
                p.cents == b.cents &&
                p.bendBeat == b.bendBeat &&
                p.bendCents == b.bendCents),
      );
      final fill =
          activeEdgeDest != null && activeEdgeDest == destLive
              ? handleActive
              : handleFill;
      canvas.drawCircle(handle, 4.5, fill);
      canvas.drawCircle(handle, 4.5, handleRing);
    }

    final dot = Paint()..color = AppColors.goldSoft;
    for (final p in pts) {
      canvas.drawCircle(Offset(xFor(p.beat), yFor(p.cents)), 3.2, dot);
    }
    canvas.restore();
  }

  static double snapCeil(double v, double step) {
    if (step <= 0) return v;
    return (v / step).ceil() * step;
  }

  @override
  bool shouldRepaint(covariant RagaGridPainter oldDelegate) => true;
}

/// Maps a local offset in the grid to beat/cents.
class GridMapper {
  GridMapper({
    required this.size,
    required this.raga,
    required this.viewport,
  });

  final Size size;
  final EditableRaga raga;
  final GridViewport viewport;

  double beatAt(Offset local) => viewport.beatAt(local, size, raga);

  double centsAt(Offset local) => viewport.centsAt(local, size, raga);

  Offset offsetFor(CurvePoint p) =>
      viewport.offsetFor(p.beat, p.cents, size, raga);

  Offset offsetBeatCents(double beat, double cents) =>
      viewport.offsetFor(beat, cents, size, raga);

  /// Nearest point within [hitPx] screen pixels, or null.
  int? nearestPointIndex(Offset local, {double hitPx = 14}) {
    final limit = hitPx * hitPx;
    var best = limit;
    int? idx;
    for (var i = 0; i < raga.points.length; i++) {
      final d = (offsetFor(raga.points[i]) - local).distanceSquared;
      if (d <= best) {
        best = d;
        idx = i;
      }
    }
    return idx;
  }

  int? _indexOfPoint(CurvePoint target) {
    final destIdx = raga.points.indexWhere(
      (p) =>
          identical(p, target) ||
          (p.beat == target.beat &&
              p.cents == target.cents &&
              p.bendBeat == target.bendBeat &&
              p.bendCents == target.bendCents),
    );
    return destIdx >= 0 ? destIdx : null;
  }

  Offset _handleFor(CurvePoint a, CurvePoint b) {
    if (b.hasBend) {
      return offsetBeatCents(b.bendBeat!, b.bendCents!);
    }
    return offsetBeatCents(b.beat, a.cents);
  }

  double _pathDist(Offset local, CurvePoint a, CurvePoint b) {
    if (b.hasBend) {
      return _distToQuad(
        local,
        offsetFor(a),
        offsetBeatCents(b.bendBeat!, b.bendCents!),
        offsetFor(b),
      );
    }
    return math.min(
      _distToSegment(
        local,
        offsetFor(a),
        offsetBeatCents(b.beat, a.cents),
      ),
      _distToSegment(
        local,
        offsetBeatCents(b.beat, a.cents),
        offsetFor(b),
      ),
    );
  }

  /// Blue edge-handle only; destination point index in [raga.points].
  int? nearestHandleDestIndex(Offset local, {double hitPx = 12}) {
    final sorted = List<CurvePoint>.from(raga.points)
      ..sort((a, b) => a.beat.compareTo(b.beat));
    if (sorted.length < 2) return null;

    final limit = hitPx * hitPx;
    var best = limit;
    CurvePoint? bestDest;
    for (var i = 0; i < sorted.length - 1; i++) {
      final a = sorted[i];
      final b = sorted[i + 1];
      final d = (_handleFor(a, b) - local).distanceSquared;
      if (d <= best) {
        best = d;
        bestDest = b;
      }
    }
    return bestDest == null ? null : _indexOfPoint(bestDest);
  }

  /// Gold pitch line only (not the blue handle).
  int? nearestLineDestIndex(Offset local, {double hitPx = 10}) {
    final sorted = List<CurvePoint>.from(raga.points)
      ..sort((a, b) => a.beat.compareTo(b.beat));
    if (sorted.length < 2) return null;

    // Prefer handle if closer — so line hit does not steal handle clicks.
    if (nearestHandleDestIndex(local, hitPx: hitPx + 2) != null) return null;

    final limit = hitPx * hitPx;
    var best = limit;
    CurvePoint? bestDest;
    for (var i = 0; i < sorted.length - 1; i++) {
      final a = sorted[i];
      final b = sorted[i + 1];
      final d = _pathDist(local, a, b);
      final d2 = d * d;
      if (d2 <= best) {
        best = d2;
        bestDest = b;
      }
    }
    return bestDest == null ? null : _indexOfPoint(bestDest);
  }

  /// Handle or line (for “empty grid” checks).
  int? nearestEdgeDestIndex(Offset local, {double hitPx = 12}) =>
      nearestHandleDestIndex(local, hitPx: hitPx) ??
      nearestLineDestIndex(local, hitPx: hitPx);

  static double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.distanceSquared;
    if (len2 < 1e-9) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  static double _distToQuad(Offset p, Offset a, Offset c, Offset b) {
    var best = double.infinity;
    Offset prev = a;
    const n = 16;
    for (var i = 1; i <= n; i++) {
      final t = i / n;
      final u = 1.0 - t;
      final pt = Offset(
        u * u * a.dx + 2 * u * t * c.dx + t * t * b.dx,
        u * u * a.dy + 2 * u * t * c.dy + t * t * b.dy,
      );
      best = math.min(best, _distToSegment(p, prev, pt));
      prev = pt;
    }
    return best;
  }
}
