import 'pitch_envelope.dart';
import 'swara.dart';

/// Named ornament templates. Control points are relative to the target swara
/// (cents offset from the swara's absolute cents, then added at expand time).
enum GamakaId {
  steady,
  /// Wide oscillation — Ri₂ / Da₂ in Shankarabharanam (not Ga/Ni).
  kampita,
  /// Mild shake — Madhyama ardha-kampita.
  ardhaKampita,
  jaaruUp,
  jaaruDown,
  /// Brief stress / touch above the swara — Ga₃ / Ni₃ in Shankarabharanam.
  nokku,
}

class GamakaLibrary {
  GamakaLibrary._();

  /// Relative cents envelopes (offset from nominal swara).
  static PitchEnvelope relative(GamakaId id, {Swara? from, Swara? to}) {
    switch (id) {
      case GamakaId.steady:
        return PitchEnvelope(const [
          PitchPoint(t: 0.0, cents: 0, amp: 0.0),
          PitchPoint(t: 0.04, cents: 0, amp: 1.0),
          PitchPoint(t: 0.92, cents: 0, amp: 1.0),
          PitchPoint(t: 1.0, cents: 0, amp: 0.0),
        ]);

      case GamakaId.kampita:
        // Strong svastāna oscillation (Ri / Da in Śankarābharaṇam).
        return PitchEnvelope(const [
          PitchPoint(t: 0.0, cents: -70, amp: 0.0),
          PitchPoint(t: 0.08, cents: -85, amp: 0.9),
          PitchPoint(t: 0.22, cents: 40, amp: 1.0),
          PitchPoint(t: 0.36, cents: -55, amp: 1.0),
          PitchPoint(t: 0.50, cents: 28, amp: 1.0),
          PitchPoint(t: 0.64, cents: -35, amp: 1.0),
          PitchPoint(t: 0.78, cents: 14, amp: 1.0),
          PitchPoint(t: 0.90, cents: -6, amp: 0.95),
          PitchPoint(t: 1.0, cents: 0, amp: 0.0),
        ]);

      case GamakaId.ardhaKampita:
        return PitchEnvelope(const [
          PitchPoint(t: 0.0, cents: -18, amp: 0.0),
          PitchPoint(t: 0.10, cents: -28, amp: 0.9),
          PitchPoint(t: 0.28, cents: 16, amp: 1.0),
          PitchPoint(t: 0.48, cents: -20, amp: 1.0),
          PitchPoint(t: 0.68, cents: 10, amp: 1.0),
          PitchPoint(t: 0.88, cents: -4, amp: 0.95),
          PitchPoint(t: 1.0, cents: 0, amp: 0.0),
        ]);

      case GamakaId.jaaruUp:
        final start =
            from != null && to != null ? (from.cents - to.cents) : -180.0;
        return PitchEnvelope([
          PitchPoint(t: 0.0, cents: start, amp: 0.0),
          PitchPoint(t: 0.05, cents: start * 0.92, amp: 0.7),
          PitchPoint(t: 0.55, cents: start * 0.18, amp: 1.0),
          PitchPoint(t: 0.85, cents: 0, amp: 1.0),
          const PitchPoint(t: 1.0, cents: 0, amp: 0.15),
        ]);

      case GamakaId.jaaruDown:
        final start =
            from != null && to != null ? (from.cents - to.cents) : 180.0;
        return PitchEnvelope([
          PitchPoint(t: 0.0, cents: start, amp: 0.0),
          PitchPoint(t: 0.05, cents: start * 0.92, amp: 0.7),
          PitchPoint(t: 0.55, cents: start * 0.18, amp: 1.0),
          PitchPoint(t: 0.85, cents: 0, amp: 1.0),
          const PitchPoint(t: 1.0, cents: 0, amp: 0.15),
        ]);

      case GamakaId.nokku:
        // Brief stress — keeps Ga/Ni essentially plain (vs Kalyāṇi's kampita).
        return PitchEnvelope(const [
          PitchPoint(t: 0.0, cents: 0, amp: 0.0),
          PitchPoint(t: 0.06, cents: 0, amp: 1.0),
          PitchPoint(t: 0.18, cents: 32, amp: 1.0),
          PitchPoint(t: 0.32, cents: -8, amp: 0.98),
          PitchPoint(t: 0.50, cents: 0, amp: 1.0),
          PitchPoint(t: 0.92, cents: 0, amp: 0.9),
          PitchPoint(t: 1.0, cents: 0, amp: 0.0),
        ]);
    }
  }

  /// Lift a relative envelope onto an absolute swara cent.
  static PitchEnvelope absoluteOnSwara(
    Swara swara,
    GamakaId id, {
    Swara? from,
  }) {
    final rel = relative(id, from: from, to: swara);
    final base = swara.cents;
    return PitchEnvelope([
      for (final p in rel.points)
        PitchPoint(t: p.t, cents: base + p.cents, amp: p.amp),
    ]);
  }
}
