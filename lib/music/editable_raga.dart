import 'dart:convert';
import 'dart:math' as math;

import 'pitch_envelope.dart';
import 'shankarabharanam.dart';
import 'swara.dart';

/// Pitch snap when grid-lock is on.
enum ToneSnap {
  /// ~10¢ steps — fine gamaka shaping.
  micro,

  /// 25¢ steps.
  mini,

  /// 100¢ Western semitone.
  semi,
}

extension ToneSnapCents on ToneSnap {
  /// Pitch (Y) snap in cents-from-Sa.
  double get centsStep => switch (this) {
        ToneSnap.micro => 10.0,
        ToneSnap.mini => 25.0,
        ToneSnap.semi => 100.0,
      };

  /// Beat (X) column snap — same Micro / Mini / Semi control.
  double get beatStep => switch (this) {
        ToneSnap.micro => 0.0625, // 1/16 beat
        ToneSnap.mini => 0.25, // 1/4 beat
        ToneSnap.semi => 1.0, // whole beat
      };

  String get label => switch (this) {
        ToneSnap.micro => 'Micro (10¢ · 1/16)',
        ToneSnap.mini => 'Mini (25¢ · 1/4)',
        ToneSnap.semi => 'Semi (100¢ · 1)',
      };
}

/// One control point on the editor grid: beat (X) × cents-from-Sa (Y).
///
/// Optional [bendBeat]/[bendCents] shape the edge *into* this point from the
/// previous one (quadratic Bezier). Null bend = stepped hold (no glide).
class CurvePoint {
  const CurvePoint({
    required this.beat,
    required this.cents,
    this.amp = 1.0,
    this.bendBeat,
    this.bendCents,
  });

  final double beat;
  final double cents;
  final double amp;

  /// Bezier control for the edge arriving at this point (null = step).
  final double? bendBeat;
  final double? bendCents;

  bool get hasBend => bendBeat != null && bendCents != null;

  CurvePoint copyWith({
    double? beat,
    double? cents,
    double? amp,
    double? bendBeat,
    double? bendCents,
    bool clearBend = false,
  }) =>
      CurvePoint(
        beat: beat ?? this.beat,
        cents: cents ?? this.cents,
        amp: amp ?? this.amp,
        bendBeat: clearBend ? null : (bendBeat ?? this.bendBeat),
        bendCents: clearBend ? null : (bendCents ?? this.bendCents),
      );

  Map<String, Object?> toJson() => {
        'beat': beat,
        'cents': cents,
        'amp': amp,
        if (bendBeat != null) 'bendBeat': bendBeat,
        if (bendCents != null) 'bendCents': bendCents,
      };

  factory CurvePoint.fromJson(Map<String, dynamic> j) => CurvePoint(
        beat: (j['beat'] as num).toDouble(),
        cents: (j['cents'] as num).toDouble(),
        amp: (j['amp'] as num?)?.toDouble() ?? 1.0,
        bendBeat: (j['bendBeat'] as num?)?.toDouble(),
        bendCents: (j['bendCents'] as num?)?.toDouble(),
      );
}

/// User-authored raga: scale degrees + continuous pitch curve for gamakas.
class EditableRaga {
  EditableRaga({
    required this.id,
    required this.name,
    required List<Swara> scale,
    required List<CurvePoint> points,
    this.totalBeats = 16,
    this.beatsPerMinute = 72,
    this.gridLock = true,
    this.toneSnap = ToneSnap.mini,
  })  : scale = List<Swara>.from(scale),
        points = List<CurvePoint>.from(points);

  String id;
  String name;
  List<Swara> scale;
  List<CurvePoint> points;
  double totalBeats;
  double beatsPerMinute;
  bool gridLock;
  ToneSnap toneSnap;

  /// Beat column snap — driven by [toneSnap] (Micro / Mini / Semi).
  double get beatSnap => toneSnap.beatStep;

  double get beatSeconds => 60.0 / beatsPerMinute;

  /// Sorted unique scale cents (Y lanes), including Sȧ if missing.
  List<double> get scaleCents {
    final c = scale.map((s) => s.cents).toSet().toList()..sort();
    if (c.isEmpty) return [0.0, 1200.0];
    if (c.first > 0) c.insert(0, 0);
    if (c.last < 1200) c.add(1200);
    return c;
  }

  double get minCents => math.min(0.0, scaleCents.first) - 50;
  double get maxCents => math.max(1200.0, scaleCents.last) + 50;

  static double snapValue(double value, double step) {
    if (step <= 0) return value;
    return (value / step).round() * step;
  }

  /// Snap pitch to sargam lanes (magnetic) or micro/mini/semi steps.
  ///
  /// Just-intonation Ga₃ ≈ 386¢ is not on an ET lattice. Within half a snap
  /// step of a scale lane, lock to that swara; otherwise use the tone grid.
  double snapCents(double cents) {
    if (!gridLock) return cents.clamp(minCents, maxCents);
    final step = toneSnap.centsStep;
    double? bestLane;
    var bestLaneDist = double.infinity;
    for (final lane in scaleCents) {
      final d = (cents - lane).abs();
      if (d < bestLaneDist) {
        bestLaneDist = d;
        bestLane = lane;
      }
    }
    if (bestLane != null && bestLaneDist <= step * 0.5 + 1e-9) {
      return bestLane.clamp(minCents, maxCents);
    }
    return snapValue(cents, step).clamp(minCents, maxCents);
  }

  CurvePoint snapPoint(CurvePoint p) {
    if (!gridLock) return p;
    return CurvePoint(
      beat: snapValue(p.beat, beatSnap).clamp(0.0, totalBeats),
      cents: snapCents(p.cents),
      amp: p.amp,
      bendBeat: p.bendBeat == null
          ? null
          : snapValue(p.bendBeat!, beatSnap).clamp(0.0, totalBeats),
      bendCents: p.bendCents == null ? null : snapCents(p.bendCents!),
    );
  }

  void addOrUpdatePoint(CurvePoint raw) {
    final p = snapPoint(raw);
    // Replace near-duplicate on same beat when locked; else append.
    final tol = gridLock ? beatSnap * 0.51 : 0.02;
    final idx = points.indexWhere((e) => (e.beat - p.beat).abs() <= tol);
    if (idx >= 0) {
      points[idx] = p;
    } else {
      points.add(p);
    }
    sortPoints();
  }

  /// Insert a point; returns its index after sorting.
  int addPoint(CurvePoint raw) {
    final p = snapPoint(raw);
    points.add(p);
    sortPoints();
    return points.indexWhere(
      (e) =>
          e.beat == p.beat &&
          e.cents == p.cents &&
          e.amp == p.amp &&
          e.bendBeat == p.bendBeat &&
          e.bendCents == p.bendCents,
    );
  }

  /// Move an existing point by index (left-drag). Does not re-sort mid-drag.
  void movePoint(int index, CurvePoint raw) {
    if (index < 0 || index >= points.length) return;
    final prev = points[index];
    final snapped = snapPoint(raw);
    points[index] = snapped.copyWith(
      bendBeat: prev.bendBeat,
      bendCents: prev.bendCents,
      clearBend: !prev.hasBend,
    );
  }

  /// Next point in beat order after [fromIndex], or null.
  int? nextPointIndex(int fromIndex) {
    if (fromIndex < 0 || fromIndex >= points.length) return null;
    final from = points[fromIndex];
    int? bestIdx;
    for (var i = 0; i < points.length; i++) {
      if (i == fromIndex) continue;
      final p = points[i];
      final after = p.beat > from.beat + 1e-12 ||
          (p.beat == from.beat && i > fromIndex);
      if (!after) continue;
      if (bestIdx == null ||
          p.beat < points[bestIdx].beat ||
          (p.beat == points[bestIdx].beat && i < bestIdx)) {
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// When a new anchor is dragged up/down, create edge bend controls around it.
  void autoBendAroundPoint(int index) {
    if (index < 0 || index >= points.length) return;
    final cur = points[index];
    final prev = previousPoint(index);
    if (prev != null && (cur.cents - prev.cents).abs() > 8) {
      setEdgeBend(
        index,
        (prev.beat + cur.beat) / 2,
        cur.cents,
      );
    }
    final nextIdx = nextPointIndex(index);
    if (nextIdx != null) {
      final next = points[nextIdx];
      if ((cur.cents - next.cents).abs() > 8 ||
          (prev != null && (cur.cents - prev.cents).abs() > 8)) {
        setEdgeBend(
          nextIdx,
          (cur.beat + next.beat) / 2,
          cur.cents,
        );
      }
    }
  }

  /// Previous point in beat order before [destIndex], or null.
  CurvePoint? previousPoint(int destIndex) {
    if (destIndex < 0 || destIndex >= points.length) return null;
    final dest = points[destIndex];
    int? bestIdx;
    for (var i = 0; i < points.length; i++) {
      if (i == destIndex) continue;
      final p = points[i];
      final before = p.beat < dest.beat - 1e-12 ||
          (p.beat == dest.beat && i < destIndex);
      if (!before) continue;
      if (bestIdx == null ||
          p.beat > points[bestIdx].beat ||
          (p.beat == points[bestIdx].beat && i > bestIdx)) {
        bestIdx = i;
      }
    }
    return bestIdx == null ? null : points[bestIdx];
  }

  /// Set / update the Bezier bend on the edge arriving at [destIndex].
  ///
  /// Dragging near the stepped elbow clears the bend back to a hard step.
  void setEdgeBend(int destIndex, double beat, double cents) {
    if (destIndex < 0 || destIndex >= points.length) return;
    final a = previousPoint(destIndex);
    final b = points[destIndex];
    if (a == null) return;
    var ctrlBeat = beat.clamp(0.0, totalBeats);
    var ctrlCents = cents.clamp(minCents, maxCents);
    if (gridLock) {
      ctrlBeat = snapValue(ctrlBeat, beatSnap).clamp(0.0, totalBeats);
      ctrlCents = snapCents(ctrlCents);
    }
    // Elbow of the default step path: (b.beat, a.cents).
    final nearElbow = (ctrlBeat - b.beat).abs() <=
            (gridLock ? beatSnap * 0.51 : 0.08) &&
        (ctrlCents - a.cents).abs() <=
            (gridLock ? toneSnap.centsStep * 0.51 : 15.0);
    if (nearElbow) {
      points[destIndex] = b.copyWith(clearBend: true);
      return;
    }
    points[destIndex] = b.copyWith(
      bendBeat: ctrlBeat,
      bendCents: ctrlCents,
    );
  }

  void sortPoints() => points.sort((a, b) => a.beat.compareTo(b.beat));

  void eraseNear(double beat, double cents, {double beatRadius = 0.35}) {
    points.removeWhere((p) => (p.beat - beat).abs() <= beatRadius);
  }

  void clearCurve() => points.clear();

  /// Seed a stepped scale outline (ārohaṇa then avarohaṇa) for editing.
  void seedScaleOutline() {
    points.clear();
    final up = List<Swara>.from(scale);
    if (up.isEmpty) return;
    if (up.last != Swara.saHigh && !up.any((s) => s.cents >= 1190)) {
      up.add(Swara.saHigh);
    }
    final down = up.reversed.skip(1).toList();
    final seq = [...up, ...down];
    final n = math.max(1, seq.length);
    for (var i = 0; i < seq.length; i++) {
      var beat = i * totalBeats / n;
      if (gridLock) {
        beat = snapValue(beat, beatSnap).clamp(0.0, totalBeats);
      }
      points.add(CurvePoint(
        beat: beat,
        cents: seq[i].cents, // exact JI swara — on its sargam lane
        amp: 1.0,
      ));
    }
    // Hold last Sa.
    points.add(CurvePoint(
      beat: totalBeats,
      cents: Swara.sa.cents,
      amp: 0.0,
    ));
    if (gridLock) sortPoints();
  }

  /// Quadratic Bezier sample between two anchors and a control.
  static (double beat, double cents) quadBezier(
    CurvePoint a,
    double ctrlBeat,
    double ctrlCents,
    CurvePoint b,
    double t,
  ) {
    final u = 1.0 - t;
    final beat = u * u * a.beat + 2 * u * t * ctrlBeat + t * t * b.beat;
    final cents = u * u * a.cents + 2 * u * t * ctrlCents + t * t * b.cents;
    return (beat, cents);
  }

  /// Builds playback: stepped holds by default; curved edges sample a Bezier.
  TimedPitchEnvelope toEnvelope({
    double stepSeconds = 0.002,
    int curveSamples = 24,
  }) {
    if (points.isEmpty) {
      return TimedPitchEnvelope(
        const [TimedPitchPoint(seconds: 0, cents: 0, amp: 0)],
        totalSeconds: beatSeconds,
      );
    }
    final sorted = List<CurvePoint>.from(points)
      ..sort((a, b) => a.beat.compareTo(b.beat));
    final out = <TimedPitchPoint>[];

    void addSample(double beat, double cents, double amp) {
      final t = beat * beatSeconds;
      if (out.isNotEmpty && (t - out.last.seconds).abs() < 1e-9) {
        out[out.length - 1] =
            TimedPitchPoint(seconds: t, cents: cents, amp: amp);
        return;
      }
      out.add(TimedPitchPoint(seconds: t, cents: cents, amp: amp));
    }

    addSample(sorted.first.beat, sorted.first.cents, sorted.first.amp);

    for (var i = 1; i < sorted.length; i++) {
      final prev = sorted[i - 1];
      final next = sorted[i];
      if (next.hasBend) {
        final n = math.max(4, curveSamples);
        for (var s = 1; s <= n; s++) {
          final t = s / n;
          final (beat, cents) = quadBezier(
            prev,
            next.bendBeat!,
            next.bendCents!,
            next,
            t,
          );
          final amp = prev.amp + (next.amp - prev.amp) * t;
          addSample(beat, cents, amp);
        }
      } else {
        // Hold previous pitch until just before this attack, then step.
        final t = next.beat * beatSeconds;
        final holdEnd = math.max(out.last.seconds, t - stepSeconds);
        if (holdEnd > out.last.seconds + 1e-9) {
          out.add(TimedPitchPoint(
            seconds: holdEnd,
            cents: prev.cents,
            amp: prev.amp,
          ));
        }
        out.add(TimedPitchPoint(
          seconds: t,
          cents: next.cents,
          amp: next.amp,
        ));
      }
    }

    final endSec = totalBeats * beatSeconds;
    final last = out.last;
    if (last.seconds < endSec - 1e-9) {
      out.add(TimedPitchPoint(
        seconds: endSec,
        cents: last.cents,
        amp: 0.0,
      ));
    } else if (last.amp > 0.05) {
      out.add(TimedPitchPoint(
        seconds: last.seconds + 0.05,
        cents: last.cents,
        amp: 0.0,
      ));
    }
    return TimedPitchEnvelope(
      out,
      totalSeconds: math.max(out.last.seconds, endSec),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'scale': scale.map((s) => s.name).toList(),
        'points': points.map((p) => p.toJson()).toList(),
        'totalBeats': totalBeats,
        'beatsPerMinute': beatsPerMinute,
        'gridLock': gridLock,
        'toneSnap': toneSnap.name,
        'beatSnap': beatSnap, // derived; kept for older readers
      };

  factory EditableRaga.fromJson(Map<String, dynamic> j) {
    final scaleNames = (j['scale'] as List?)?.cast<String>() ?? [];
    final scale = <Swara>[
      for (final n in scaleNames)
        Swara.values.firstWhere(
          (s) => s.name == n,
          orElse: () => Swara.sa,
        ),
    ];
    final pts = (j['points'] as List? ?? [])
        .map((e) => CurvePoint.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final snapName = j['toneSnap'] as String? ?? ToneSnap.mini.name;
    return EditableRaga(
      id: j['id'] as String? ??
          'raga_${DateTime.now().millisecondsSinceEpoch}',
      name: j['name'] as String? ?? 'Untitled',
      scale: scale.isEmpty ? List.of(Shankarabharanam.arohana) : scale,
      points: pts,
      totalBeats: (j['totalBeats'] as num?)?.toDouble() ?? 16,
      beatsPerMinute: (j['beatsPerMinute'] as num?)?.toDouble() ?? 72,
      gridLock: j['gridLock'] as bool? ?? true,
      toneSnap: ToneSnap.values.firstWhere(
        (t) => t.name == snapName,
        orElse: () => ToneSnap.mini,
      ),
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory EditableRaga.decode(String raw) =>
      EditableRaga.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  factory EditableRaga.shankarabharanamTemplate() {
    final r = EditableRaga(
      id: 'template_shankarabharanam',
      name: 'Śankarābharaṇam',
      scale: List.of(Shankarabharanam.arohana),
      points: const [],
      totalBeats: 16,
      beatsPerMinute: 60,
      gridLock: true,
      toneSnap: ToneSnap.mini,
    );
    r.seedScaleOutline();
    return r;
  }

  EditableRaga cloneWithNewId(String newName) => EditableRaga(
        id: 'raga_${DateTime.now().millisecondsSinceEpoch}',
        name: newName,
        scale: List.of(scale),
        points: points.map((p) => p.copyWith()).toList(),
        totalBeats: totalBeats,
        beatsPerMinute: beatsPerMinute,
        gridLock: gridLock,
        toneSnap: toneSnap,
      );
}
