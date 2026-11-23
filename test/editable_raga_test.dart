import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:carnatic_app/music/editable_raga.dart';
import 'package:carnatic_app/music/swara.dart';
import 'package:carnatic_app/storage/raga_store.dart';
import 'package:carnatic_app/ui/raga_grid_painter.dart';
import 'package:carnatic_app/ui/waveform_painter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('grid lock snaps micro / mini / semi', () {
    final r = EditableRaga(
      id: 't',
      name: 't',
      scale: [Swara.sa, Swara.pa, Swara.saHigh],
      points: const [],
      gridLock: true,
      toneSnap: ToneSnap.mini,
    );
    final p = r.snapPoint(const CurvePoint(beat: 1.12, cents: 237));
    expect(p.beat, closeTo(1.0, 0.001));
    expect(p.cents, closeTo(225, 0.001)); // 25¢ mini

    r.toneSnap = ToneSnap.semi;
    final s = r.snapPoint(const CurvePoint(beat: 2.1, cents: 237));
    expect(s.cents, closeTo(200, 0.001));
    expect(s.beat, closeTo(2.0, 0.001)); // semi = whole beat
    expect(r.beatSnap, 1.0);

    r.toneSnap = ToneSnap.micro;
    expect(r.beatSnap, 0.0625);
    final m = r.snapPoint(const CurvePoint(beat: 1.10, cents: 237));
    expect(m.beat, closeTo(1.125, 0.001)); // nearest 1/16

    r.gridLock = false;
    final free = r.snapPoint(const CurvePoint(beat: 1.12, cents: 237));
    expect(free.beat, 1.12);
    expect(free.cents, 237);
  });

  test('Ga₃ snaps to sargam lane, not nearest ET mini step', () {
    final r = EditableRaga.shankarabharanamTemplate();
    r.gridLock = true;
    r.toneSnap = ToneSnap.mini;
    final ga = Swara.ga3.cents; // ≈ 386.3, between 375 and 400
    expect(ga, isNot(closeTo(375, 0.5)));
    expect(ga, isNot(closeTo(400, 0.5)));

    final onLane = r.snapPoint(CurvePoint(beat: 2, cents: ga));
    expect(onLane.cents, closeTo(ga, 0.01));

    // Near Ga₃ prefers the lane over 375/400.
    final near = r.snapPoint(CurvePoint(beat: 2, cents: ga + 8));
    expect(near.cents, closeTo(ga, 0.01));

    // Seeded outline keeps Ga on its lane and beats on beatSnap.
    r.seedScaleOutline();
    final gaPts = r.points.where((p) => (p.cents - ga).abs() < 0.5);
    expect(gaPts, isNotEmpty);
    for (final p in gaPts) {
      expect(p.cents, closeTo(ga, 0.01));
      expect(p.beat % r.beatSnap, closeTo(0, 0.001));
    }
  });

  test('envelope duration follows beats', () {
    final r = EditableRaga.shankarabharanamTemplate();
    r.beatsPerMinute = 60;
    r.totalBeats = 8;
    r.seedScaleOutline();
    final env = r.toEnvelope();
    expect(env.totalSeconds, closeTo(8.0, 0.1));
    expect(env.points.length, greaterThan(4));
  });

  test('addPoint always inserts; movePoint updates index', () {
    final r = EditableRaga(
      id: 'pts',
      name: 'pts',
      scale: [Swara.sa, Swara.ri2],
      points: [CurvePoint(beat: 0, cents: Swara.sa.cents)],
      gridLock: false,
    );
    final idx = r.addPoint(CurvePoint(beat: 1, cents: Swara.ri2.cents));
    expect(r.points.length, 2);
    expect(idx, 1);
    r.movePoint(0, CurvePoint(beat: 0.5, cents: 50));
    expect(r.points[0].beat, 0.5);
    expect(r.points[0].cents, 50);
  });

  test('autoBendAroundPoint creates edge bend when dragged vertically', () {
    final r = EditableRaga(
      id: 'ab',
      name: 'ab',
      scale: [Swara.sa, Swara.ga3],
      points: [
        CurvePoint(beat: 0, cents: Swara.sa.cents),
        CurvePoint(beat: 1, cents: Swara.sa.cents),
        CurvePoint(beat: 2, cents: Swara.sa.cents),
      ],
      gridLock: false,
      totalBeats: 4,
    );
    r.movePoint(1, CurvePoint(beat: 1, cents: Swara.ga3.cents));
    r.autoBendAroundPoint(1);
    expect(r.points[1].hasBend, isTrue);
    expect(r.points[2].hasBend, isTrue);
  });

  test('Sa holds then Ri steps — no mid-slide average', () {
    final r = EditableRaga(
      id: 'step',
      name: 'step',
      scale: [Swara.sa, Swara.ri2],
      points: [
        CurvePoint(beat: 0, cents: Swara.sa.cents),
        CurvePoint(beat: 2, cents: Swara.ri2.cents),
      ],
      totalBeats: 4,
      beatsPerMinute: 60,
    );
    final env = r.toEnvelope();
    // Halfway through Sa's hold — still Sa, not halfway to Ri.
    final mid = env.sampleAtSeconds(1.0);
    expect(mid.cents, closeTo(Swara.sa.cents, 1.0));
    // Just after Ri attack — Ri.
    final after = env.sampleAtSeconds(2.01);
    expect(after.cents, closeTo(Swara.ri2.cents, 1.0));
  });

  test('Sa Sa re-articulates — amp dips between identical pitches', () {
    final r = EditableRaga(
      id: 'sasa',
      name: 'sasa',
      scale: [Swara.sa],
      points: [
        CurvePoint(beat: 0, cents: Swara.sa.cents),
        CurvePoint(beat: 1, cents: Swara.sa.cents),
        CurvePoint(beat: 2, cents: Swara.sa.cents, amp: 0),
      ],
      totalBeats: 2,
      beatsPerMinute: 60,
      gridLock: false,
    );
    final env = r.toEnvelope();
    // First note sounding.
    expect(env.sampleAtSeconds(0.05).amp, greaterThan(0.5));
    // Gap at the second attack instant (amp 0 before swell).
    expect(env.sampleAtSeconds(1.0).amp, lessThan(0.05));
    // Second Sa attacks again.
    expect(env.sampleAtSeconds(1.05).amp, greaterThan(0.5));
    expect(env.sampleAtSeconds(1.05).cents, closeTo(Swara.sa.cents, 1.0));
  });

  test('edge bend follows Bezier — not a hard Sa hold', () {
    final r = EditableRaga(
      id: 'bend',
      name: 'bend',
      scale: [Swara.sa, Swara.ri2],
      points: [
        CurvePoint(beat: 0, cents: Swara.sa.cents),
        CurvePoint(beat: 2, cents: Swara.ri2.cents),
      ],
      totalBeats: 4,
      beatsPerMinute: 60,
      gridLock: false,
    );
    // Pull the Sa→Ri edge upward mid-way (jaaru / kampita shape).
    r.setEdgeBend(1, 1.0, Swara.ri2.cents + 100);
    expect(r.points[1].hasBend, isTrue);

    final env = r.toEnvelope();
    final mid = env.sampleAtSeconds(1.0);
    // Curved edge leaves Sa before beat 2.
    expect(mid.cents, greaterThan(Swara.sa.cents + 20));
    expect(mid.cents, isNot(closeTo(Swara.sa.cents, 1.0)));

    // Envelope times stay monotonic (sideways handle must not reverse time).
    for (var i = 1; i < env.points.length; i++) {
      expect(env.points[i].seconds, greaterThanOrEqualTo(env.points[i - 1].seconds));
    }
    // Landing stays sounding — no amp→0 re-attack click after the glide.
    expect(env.sampleAtSeconds(2.0).amp, greaterThan(0.5));
    expect(env.sampleAtSeconds(2.0).cents, closeTo(Swara.ri2.cents, 1.0));

    // Drag control back to the step elbow → bend clears.
    r.setEdgeBend(1, 2.0, Swara.sa.cents);
    expect(r.points[1].hasBend, isFalse);
    final stepped = r.toEnvelope().sampleAtSeconds(1.0);
    expect(stepped.cents, closeTo(Swara.sa.cents, 1.0));
  });

  test('scroll zoom keeps focus beat/cents under the cursor', () {
    final r = EditableRaga.shankarabharanamTemplate();
    final vp = GridViewport(cents0: r.minCents);
    const size = Size(400, 300);
    const local = Offset(200, 150);
    final beforeBeat = vp.beatAt(local, size, r);
    final beforeCents = vp.centsAt(local, size, r);
    vp.zoomAt(raga: r, size: size, local: local, factor: 2.0);
    expect(vp.zoom, 2.0);
    expect(vp.beatAt(local, size, r), closeTo(beforeBeat, 0.05));
    expect(vp.centsAt(local, size, r), closeTo(beforeCents, 2.0));
    vp.zoomAt(raga: r, size: size, local: local, factor: 0.5);
    expect(vp.zoom, closeTo(1.0, 0.01));
  });

  test('empty-grid pan shifts viewport by pixel delta', () {
    final r = EditableRaga.shankarabharanamTemplate();
    final vp = GridViewport(zoom: 4.0, beat0: 4.0, cents0: 300);
    vp.clampTo(r);
    const size = Size(400, 300);
    final beatBefore = vp.beat0;
    final centsBefore = vp.cents0;
    // Drag right/up → content follows → view origin moves left/down in music space.
    vp.panBy(raga: r, size: size, pixelDelta: const Offset(40, -30));
    expect(vp.beat0, lessThan(beatBefore));
    expect(vp.cents0, lessThan(centsBefore));
  });

  test('waveform scroll zoom keeps focus time under the cursor', () {
    final vp = WaveformViewport();
    const size = Size(400, 80);
    const local = Offset(100, 40);
    final before = vp.timeAt(local, size);
    vp.zoomAt(size: size, local: local, factor: 4.0);
    expect(vp.zoom, 4.0);
    expect(vp.timeAt(local, size), closeTo(before, 1e-6));
    vp.zoomAt(size: size, local: local, factor: 0.25);
    expect(vp.zoom, closeTo(1.0, 0.01));
  });

  test('waveform pan shifts t0 by pixel delta', () {
    final vp = WaveformViewport(zoom: 4.0, t0: 0.25);
    vp.clampTo();
    const size = Size(400, 80);
    final before = vp.t0;
    vp.panBy(size: size, pixelDelta: const Offset(40, 0));
    expect(vp.t0, lessThan(before));
  });

  test('multi-select move keeps relative spacing', () {
    final r = EditableRaga.shankarabharanamTemplate()..clearCurve();
    r.gridLock = false;
    r.points.addAll([
      CurvePoint(beat: 1, cents: 0),
      CurvePoint(
        beat: 2,
        cents: 200,
        bendBeat: 1.5,
        bendCents: 100,
      ),
      CurvePoint(beat: 3, cents: 400),
    ]);
    final origins = {
      0: r.points[0],
      1: r.points[1],
      2: r.points[2],
    };
    r.movePointsFromOrigins(origins, 0.5, -50);
    expect(r.points[0].beat, closeTo(1.5, 1e-9));
    expect(r.points[0].cents, closeTo(-50, 1e-9));
    expect(r.points[1].beat, closeTo(2.5, 1e-9));
    expect(r.points[1].cents, closeTo(150, 1e-9));
    expect(r.points[1].bendBeat, closeTo(2.0, 1e-9));
    expect(r.points[1].bendCents, closeTo(50, 1e-9));
    expect(r.points[2].beat, closeTo(3.5, 1e-9));
    expect(r.points[2].cents, closeTo(350, 1e-9));
    r.eraseIndices({0, 2});
    expect(r.points.length, 1);
    expect(r.points[0].beat, closeTo(2.5, 1e-9));
  });

  test('multi-select snaps only dragged note; others keep relative offsets', () {
    final r = EditableRaga.shankarabharanamTemplate()..clearCurve();
    r.gridLock = true;
    r.toneSnap = ToneSnap.mini; // ¼ beat, 25¢
    r.points.addAll([
      CurvePoint(beat: 1.0, cents: 0),
      CurvePoint(beat: 1.37, cents: 40), // off-grid relative to leader
      CurvePoint(beat: 2.1, cents: 210),
    ]);
    final origins = {
      0: r.points[0],
      1: r.points[1],
      2: r.points[2],
    };
    // Drag leader toward beat 1.12 / 12¢ → snaps to 1.0 / 0 or 1.25 / 25.
    r.movePointsFromOrigins(origins, 0.12, 12, snapIndex: 0);
    final lead = r.points[0];
    expect(lead.beat, closeTo(1.0, 1e-9)); // 1.12 → mini beat snap 1.0
    expect(lead.cents, closeTo(0, 1e-9));
    // Others = origin + (snappedLead - leadOrigin); not independently snapped.
    expect(r.points[1].beat, closeTo(1.37, 1e-9));
    expect(r.points[1].cents, closeTo(40, 1e-9));
    expect(r.points[2].beat, closeTo(2.1, 1e-9));
    expect(r.points[2].cents, closeTo(210, 1e-9));
    // Non-zero move that snaps leader forward.
    r.points[0] = origins[0]!;
    r.points[1] = origins[1]!;
    r.points[2] = origins[2]!;
    r.movePointsFromOrigins(origins, 0.3, 30, snapIndex: 0);
    expect(r.points[0].beat, closeTo(1.25, 1e-9)); // 1.3 → 1.25
    expect(r.points[0].cents, closeTo(25, 1e-9)); // 30 → 25
    expect(r.points[1].beat, closeTo(1.37 + 0.25, 1e-9));
    expect(r.points[1].cents, closeTo(40 + 25, 1e-9));
    expect(r.points[2].beat, closeTo(2.1 + 0.25, 1e-9));
    expect(r.points[2].cents, closeTo(210 + 25, 1e-9));
  });

  test('marquee rect selects points by screen position', () {
    final r = EditableRaga.shankarabharanamTemplate()..clearCurve();
    r.gridLock = false;
    r.points.addAll([
      CurvePoint(beat: 1, cents: 0),
      CurvePoint(beat: 2, cents: 200),
      CurvePoint(beat: 4, cents: 700),
    ]);
    final vp = GridViewport();
    const size = Size(400, 300);
    final map = GridMapper(size: size, raga: r, viewport: vp);
    final a = map.offsetFor(r.points[0]);
    final b = map.offsetFor(r.points[1]);
    final rect = Rect.fromPoints(
      Offset(a.dx - 4, a.dy + 4),
      Offset(b.dx + 4, b.dy - 4),
    );
    final picked = map.indicesInRect(rect);
    expect(picked.contains(0), isTrue);
    expect(picked.contains(1), isTrue);
    expect(picked.contains(2), isFalse);
  });

  test('marquee gold vs teal handles are independent', () {
    final r = EditableRaga.shankarabharanamTemplate()..clearCurve();
    r.gridLock = false;
    r.points.addAll([
      CurvePoint(beat: 1, cents: 0),
      CurvePoint(beat: 1.05, cents: 200),
      CurvePoint(
        beat: 8,
        cents: 700,
        bendBeat: 1.2,
        bendCents: 100,
      ),
    ]);
    final vp = GridViewport();
    const size = Size(400, 300);
    final map = GridMapper(size: size, raga: r, viewport: vp);
    final a = map.offsetFor(r.points[0]);
    final b = map.offsetFor(r.points[1]);
    final handle = map.offsetBeatCents(1.2, 100);
    final rect = Rect.fromPoints(
      Offset(
        math.min(a.dx, handle.dx) - 6,
        math.min(a.dy, math.min(b.dy, handle.dy)) - 6,
      ),
      Offset(
        math.max(b.dx, handle.dx) + 6,
        math.max(a.dy, math.max(b.dy, handle.dy)) + 6,
      ),
    );
    // Golds in box — far dest gold stays out.
    final golds = map.indicesInRect(rect);
    expect(golds.contains(0), isTrue);
    expect(golds.contains(1), isTrue);
    expect(golds.contains(2), isFalse);
    // Teal handle in box selects handle only — not the far gold note.
    expect(map.handleIndicesInRect(rect), equals({2}));
    final bendOnly = Rect.fromCenter(center: handle, width: 14, height: 14);
    expect(map.indicesInRect(bendOnly), isEmpty);
    expect(map.handleIndicesInRect(bendOnly), equals({2}));
  });

  test('multi-move translates bend only when handle selected', () {
    final r = EditableRaga(
      id: 't',
      name: 't',
      scale: const [],
      points: [
        const CurvePoint(beat: 0, cents: 0),
        const CurvePoint(
          beat: 2,
          cents: 200,
          bendBeat: 1,
          bendCents: 100,
        ),
      ],
      gridLock: false,
    );
    final origins = {1: r.points[1]};
    r.movePointsFromOrigins(
      origins,
      1,
      50,
      translateBendIndices: const {},
    );
    expect(r.points[1].beat, closeTo(3, 1e-9));
    expect(r.points[1].cents, closeTo(250, 1e-9));
    expect(r.points[1].bendBeat, closeTo(1, 1e-9));
    expect(r.points[1].bendCents, closeTo(100, 1e-9));

    r.movePointsFromOrigins(
      {1: r.points[1]},
      1,
      0,
      translateBendIndices: {1},
    );
    expect(r.points[1].bendBeat, closeTo(2, 1e-9));
  });

  test('marquee selects gold when visible circle intersects box', () {
    final r = EditableRaga.shankarabharanamTemplate()..clearCurve();
    r.gridLock = false;
    r.points.addAll([
      CurvePoint(beat: 1, cents: 0),
      CurvePoint(beat: 1.02, cents: 180),
    ]);
    final vp = GridViewport();
    const size = Size(400, 300);
    final map = GridMapper(size: size, raga: r, viewport: vp);
    final mid = map.offsetFor(r.points[1]);
    // Box stops short of the center but overlaps the drawn node (~7px).
    final rect = Rect.fromLTRB(
      mid.dx - 20,
      mid.dy - 20,
      mid.dx - 4,
      mid.dy + 20,
    );
    expect(GridMapper.rectHits(rect, mid), isFalse);
    expect(
      GridMapper.circleHitsRect(rect, mid, GridMapper.marqueeHitRadius),
      isTrue,
    );
    expect(map.indicesInRect(rect), equals({1}));
  });

  test('raga store round-trips JSON', () async {
    final dir = await Directory.systemTemp.createTemp('gamaka_ragas_');
    final store = RagaStore(directory: dir);
    final r = EditableRaga.shankarabharanamTemplate().cloneWithNewId('My Raga');
    await store.save(r);
    final list = await store.list();
    expect(list.any((e) => e.name == 'My Raga'), isTrue);
    final loaded = list.firstWhere((e) => e.id == r.id);
    expect(loaded.points.length, r.points.length);
    await dir.delete(recursive: true);
  });
}
