import 'gamaka.dart';
import 'pitch_envelope.dart';
import 'swara.dart';

class PhraseNote {
  const PhraseNote({
    required this.swara,
    required this.beats,
    this.gamaka = GamakaId.steady,
    this.slideFrom,
  });

  final Swara swara;
  final double beats;
  final GamakaId gamaka;

  /// When set with jaaru gamakas, starts the slide from this swara.
  final Swara? slideFrom;
}

class Phrase {
  const Phrase({
    required this.id,
    required this.title,
    required this.notes,
    this.beatsPerMinute = 72,
  });

  final String id;
  final String title;
  final List<PhraseNote> notes;
  final double beatsPerMinute;

  double get beatSeconds => 60.0 / beatsPerMinute;

  TimedPitchEnvelope buildEnvelope({required bool withGamakas}) {
    final segments = <PitchEnvelope>[];
    final durations = <double>[];

    for (final note in notes) {
      final gamaka = withGamakas ? note.gamaka : GamakaId.steady;
      final env = GamakaLibrary.absoluteOnSwara(
        note.swara,
        gamaka,
        from: note.slideFrom,
      );
      segments.add(env);
      durations.add(note.beats * beatSeconds);
    }

    return PitchEnvelope.stitch(segments, durations);
  }
}
