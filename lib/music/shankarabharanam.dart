import 'gamaka.dart';
import 'phrase.dart';
import 'swara.dart';

/// Melakarta 29 — Śankarābharaṇam (S R2 G3 M1 P D2 N3 S).
///
/// Lakṣaṇa (sangeetham / Subbarama Dikshitar tradition):
/// - Ga₃ and Ni₃ are essentially **plain** (nokku only) — NOT wide kampita
///   (wide Ga/Ni kampita = Kalyāṇi).
/// - Ri₂ and Da₂ take **strong kampita** (svastāna gamaka).
/// - Ma₁ is plain, ardha-kampita, or dīrgha-kampita depending on phrase.
///
/// Exact just frequencies at Sa = 240 Hz:
/// Sa 240, Ri₂ 270, Ga₃ 300, Ma₁ 320, Pa 360, Da₂ 400, Ni₃ 450, Sȧ 480.
class Shankarabharanam {
  Shankarabharanam._();

  static const name = 'Śankarābharaṇam';
  static const melakarta = 29;

  /// Classic textbook Sa used for frequency tables.
  static const textbookSaHz = 240.0;

  static const arohana = <Swara>[
    Swara.sa,
    Swara.ri2,
    Swara.ga3,
    Swara.ma1,
    Swara.pa,
    Swara.da2,
    Swara.ni3,
    Swara.saHigh,
  ];

  static const avarohana = <Swara>[
    Swara.saHigh,
    Swara.ni3,
    Swara.da2,
    Swara.pa,
    Swara.ma1,
    Swara.ga3,
    Swara.ri2,
    Swara.sa,
  ];

  /// Hz for each scale degree at [saHz] (default textbook 240).
  static Map<Swara, double> frequencies({double saHz = textbookSaHz}) => {
        for (final s in arohana) s: s.hzAt(saHz),
      };

  /// Bare Ārohaṇa + Avarohaṇa held on exact just pitches (no gamaka).
  static Phrase exactScalePhrase({double bpm = 48}) {
    final notes = <PhraseNote>[
      for (final s in arohana)
        PhraseNote(
          swara: s,
          beats: s == Swara.sa || s == Swara.saHigh ? 2.0 : 1.6,
        ),
      // Brief pause feel on upper Sa before descent (held slightly longer).
      for (var i = 1; i < avarohana.length; i++)
        PhraseNote(
          swara: avarohana[i],
          beats: avarohana[i] == Swara.sa ? 2.4 : 1.6,
        ),
    ];
    return Phrase(
      id: 'shankara_exact_scale',
      title: 'Exact scale (Hz)',
      notes: notes,
      beatsPerMinute: bpm,
    );
  }

  static Phrase arohanaPhrase({double bpm = 56}) {
    final notes = <PhraseNote>[];
    for (var i = 0; i < arohana.length; i++) {
      final s = arohana[i];
      final prev = i > 0 ? arohana[i - 1] : null;
      final gamaka = switch (s) {
        Swara.ri2 || Swara.da2 => GamakaId.kampita,
        Swara.ga3 || Swara.ni3 => GamakaId.nokku,
        Swara.ma1 => GamakaId.ardhaKampita,
        Swara.pa || Swara.saHigh when prev != null => GamakaId.jaaruUp,
        _ => GamakaId.steady,
      };
      notes.add(PhraseNote(
        swara: s,
        beats: s == Swara.sa || s == Swara.saHigh ? 1.6 : 1.2,
        gamaka: gamaka,
        slideFrom: gamaka == GamakaId.jaaruUp ? prev : null,
      ));
    }
    return Phrase(
      id: 'shankara_arohana',
      title: 'Ārohaṇa',
      notes: notes,
      beatsPerMinute: bpm,
    );
  }

  static Phrase avarohanaPhrase({double bpm = 56}) {
    final notes = <PhraseNote>[];
    for (var i = 0; i < avarohana.length; i++) {
      final s = avarohana[i];
      final prev = i > 0 ? avarohana[i - 1] : null;
      final gamaka = switch (s) {
        Swara.ri2 || Swara.da2 => GamakaId.kampita,
        Swara.ga3 || Swara.ni3 => GamakaId.nokku,
        Swara.ma1 => GamakaId.ardhaKampita,
        Swara.pa || Swara.sa when prev != null => GamakaId.jaaruDown,
        _ => GamakaId.steady,
      };
      notes.add(PhraseNote(
        swara: s,
        beats: s == Swara.sa || s == Swara.saHigh ? 1.6 : 1.2,
        gamaka: gamaka,
        slideFrom: gamaka == GamakaId.jaaruDown ? prev : null,
      ));
    }
    return Phrase(
      id: 'shankara_avarohana',
      title: 'Avarohaṇa',
      notes: notes,
      beatsPerMinute: bpm,
    );
  }

  /// Characteristic san̄cāra with correct Śankarābharaṇam gamaka roles.
  static Phrase demoPhrase({double bpm = 60}) {
    return Phrase(
      id: 'shankara_demo',
      title: 'San̄cāra',
      beatsPerMinute: bpm,
      notes: const [
        PhraseNote(swara: Swara.sa, beats: 1.2),
        PhraseNote(
          swara: Swara.ri2,
          beats: 1.6,
          gamaka: GamakaId.kampita,
        ),
        PhraseNote(
          swara: Swara.ga3,
          beats: 1.4,
          gamaka: GamakaId.nokku,
        ),
        PhraseNote(
          swara: Swara.ma1,
          beats: 1.2,
          gamaka: GamakaId.ardhaKampita,
        ),
        PhraseNote(swara: Swara.pa, beats: 1.2),
        PhraseNote(
          swara: Swara.da2,
          beats: 1.6,
          gamaka: GamakaId.kampita,
        ),
        PhraseNote(
          swara: Swara.ni3,
          beats: 1.0,
          gamaka: GamakaId.nokku,
        ),
        PhraseNote(
          swara: Swara.saHigh,
          beats: 1.4,
          gamaka: GamakaId.jaaruUp,
          slideFrom: Swara.ni3,
        ),
        PhraseNote(
          swara: Swara.ni3,
          beats: 0.9,
          gamaka: GamakaId.jaaruDown,
          slideFrom: Swara.saHigh,
        ),
        PhraseNote(
          swara: Swara.da2,
          beats: 1.2,
          gamaka: GamakaId.kampita,
        ),
        PhraseNote(
          swara: Swara.pa,
          beats: 1.2,
          gamaka: GamakaId.jaaruDown,
          slideFrom: Swara.da2,
        ),
        PhraseNote(
          swara: Swara.ma1,
          beats: 1.0,
          gamaka: GamakaId.ardhaKampita,
        ),
        PhraseNote(
          swara: Swara.ga3,
          beats: 1.4,
          gamaka: GamakaId.nokku,
        ),
        PhraseNote(
          swara: Swara.ri2,
          beats: 1.2,
          gamaka: GamakaId.kampita,
        ),
        PhraseNote(swara: Swara.sa, beats: 2.2),
      ],
    );
  }

  static List<Phrase> allPhrases({double bpm = 56}) => [
        exactScalePhrase(bpm: bpm < 52 ? bpm : 48),
        arohanaPhrase(bpm: bpm),
        avarohanaPhrase(bpm: bpm),
        demoPhrase(bpm: bpm + 4),
      ];
}
