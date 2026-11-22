import 'package:carnatic_app/audio/voice_synth.dart';
import 'package:carnatic_app/music/pitch_envelope.dart';
import 'package:carnatic_app/music/shankarabharanam.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('voice render is fast and peak-normalized', () {
    final phrase = Shankarabharanam.demoPhrase();
    final env = phrase.buildEnvelope(withGamakas: true);
    final sw = Stopwatch()..start();
    final pcm = VoiceSynth().render(envelope: env, saHz: 220);
    sw.stop();
    var peak = 0.0;
    for (var i = 0; i < pcm.length; i += 2) {
      final a = pcm[i].abs();
      if (a > peak) peak = a;
    }
    expect(sw.elapsedMilliseconds, lessThan(2000));
    expect(peak, greaterThan(0.5));
  });

  test('gamaka envelope is continuous, not stepped plateaus only', () {
    final phrase = Shankarabharanam.demoPhrase(bpm: 72);
    final ornate = phrase.buildEnvelope(withGamakas: true);
    final bare = phrase.buildEnvelope(withGamakas: false);

    expect(ornate.totalSeconds, greaterThan(1));
    expect(ornate.points.length, greaterThan(bare.points.length));

    // Sample mid-kampita region should move away from a flat swara.
    final samples = ornate.downsample(count: 100);
    var variance = 0.0;
    final mean =
        samples.fold<double>(0, (a, p) => a + p.cents) / samples.length;
    for (final p in samples) {
      final d = p.cents - mean;
      variance += d * d;
    }
    variance /= samples.length;
    expect(variance, greaterThan(1000),
        reason: 'ornamented phrase should show pitch motion');
  });

  test('hzFromCents respects octave', () {
    expect(PitchEnvelope.hzFromCents(220, 1200), closeTo(440, 0.01));
    expect(PitchEnvelope.hzFromCents(220, 702), closeTo(220 * 1.5, 0.5));
  });
}
