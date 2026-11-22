import 'dart:math' as math;

/// One control point on a pitch / amplitude contour.
///
/// [t] is normalized 0..1 within the ornament or phrase segment.
/// [cents] is offset from Sa (not from the nominal swara).
class PitchPoint {
  const PitchPoint({
    required this.t,
    required this.cents,
    this.amp = 1.0,
  });

  final double t;
  final double cents;
  final double amp;
}

/// Sample-accurate F0 / amplitude envelope with linear interpolation.
class PitchEnvelope {
  PitchEnvelope(List<PitchPoint> points)
      : _points = List<PitchPoint>.unmodifiable(
          (List<PitchPoint>.from(points)
            ..sort((a, b) => a.t.compareTo(b.t))),
        ) {
    assert(_points.isNotEmpty, 'PitchEnvelope needs at least one point');
  }

  final List<PitchPoint> _points;

  List<PitchPoint> get points => _points;

  PitchPoint sample(double t) {
    final clamped = t.clamp(0.0, 1.0);
    if (_points.length == 1) return _points.first;
    if (clamped <= _points.first.t) return _points.first;
    if (clamped >= _points.last.t) return _points.last;

    for (var i = 0; i < _points.length - 1; i++) {
      final a = _points[i];
      final b = _points[i + 1];
      if (clamped >= a.t && clamped <= b.t) {
        final span = (b.t - a.t).abs() < 1e-12 ? 1.0 : (b.t - a.t);
        final u = (clamped - a.t) / span;
        // Smoothstep for less angular gamaka corners.
        final s = u * u * (3 - 2 * u);
        return PitchPoint(
          t: clamped,
          cents: a.cents + (b.cents - a.cents) * s,
          amp: a.amp + (b.amp - a.amp) * s,
        );
      }
    }
    return _points.last;
  }

  /// Absolute Hz from Sa frequency and envelope cents.
  static double hzFromCents(double saHz, double cents) {
    return saHz * math.pow(2.0, cents / 1200.0);
  }

  /// Concatenate segment envelopes into one absolute-time phrase envelope.
  ///
  /// Each segment has duration [durations][i] seconds. Returned points use
  /// [t] in absolute seconds (not normalized). Use [sampleAtSeconds].
  static TimedPitchEnvelope stitch(
    List<PitchEnvelope> segments,
    List<double> durations,
  ) {
    assert(segments.length == durations.length);
    final out = <TimedPitchPoint>[];
    var cursor = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final dur = durations[i];
      final seg = segments[i];
      for (final p in seg.points) {
        out.add(TimedPitchPoint(
          seconds: cursor + p.t * dur,
          cents: p.cents,
          amp: p.amp,
        ));
      }
      cursor += dur;
    }
    // Ensure terminal point at exact end.
    if (out.isEmpty || out.last.seconds < cursor - 1e-9) {
      final last = segments.isEmpty
          ? const TimedPitchPoint(seconds: 0, cents: 0, amp: 0)
          : TimedPitchPoint(
              seconds: cursor,
              cents: segments.last.points.last.cents,
              amp: 0,
            );
      out.add(last);
    }
    return TimedPitchEnvelope(out, totalSeconds: cursor);
  }
}

class TimedPitchPoint {
  const TimedPitchPoint({
    required this.seconds,
    required this.cents,
    this.amp = 1.0,
  });

  final double seconds;
  final double cents;
  final double amp;
}

class TimedPitchEnvelope {
  TimedPitchEnvelope(List<TimedPitchPoint> points, {required this.totalSeconds})
      : _points = List<TimedPitchPoint>.unmodifiable(
          (List<TimedPitchPoint>.from(points)
            ..sort((a, b) => a.seconds.compareTo(b.seconds))),
        );

  final List<TimedPitchPoint> _points;
  final double totalSeconds;

  List<TimedPitchPoint> get points => _points;

  TimedPitchPoint sampleAtSeconds(double seconds) {
    final t = seconds.clamp(0.0, totalSeconds);
    if (_points.length == 1) return _points.first;
    if (t <= _points.first.seconds) return _points.first;
    if (t >= _points.last.seconds) return _points.last;

    for (var i = 0; i < _points.length - 1; i++) {
      final a = _points[i];
      final b = _points[i + 1];
      if (t >= a.seconds && t <= b.seconds) {
        final span =
            (b.seconds - a.seconds).abs() < 1e-12 ? 1.0 : (b.seconds - a.seconds);
        final u = (t - a.seconds) / span;
        final s = u * u * (3 - 2 * u);
        return TimedPitchPoint(
          seconds: t,
          cents: a.cents + (b.cents - a.cents) * s,
          amp: a.amp + (b.amp - a.amp) * s,
        );
      }
    }
    return _points.last;
  }

  /// Downsample for UI plotting (cents vs normalized time).
  List<PitchPoint> downsample({int count = 200}) {
    if (totalSeconds <= 0) return const [];
    final out = <PitchPoint>[];
    for (var i = 0; i < count; i++) {
      final u = count == 1 ? 0.0 : i / (count - 1);
      final s = sampleAtSeconds(u * totalSeconds);
      out.add(PitchPoint(t: u, cents: s.cents, amp: s.amp));
    }
    return out;
  }
}
