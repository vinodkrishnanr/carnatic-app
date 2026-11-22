import 'dart:io';
import 'package:carnatic_app/audio/voice_synth.dart';
import 'package:carnatic_app/audio/wav_encoder.dart';
import 'package:carnatic_app/music/shankarabharanam.dart';
import 'package:carnatic_app/music/swara.dart';

void main() {
  const sa = 240.0;
  final freqs = Shankarabharanam.frequencies(saHz: sa);
  print('Śankarābharaṇam exact JI @ Sa=$sa Hz:');
  for (final s in Shankarabharanam.arohana) {
    print('  ${s.label.padRight(4)} ${freqs[s]!.toStringAsFixed(1)} Hz  (${_r(s.ratio)})');
  }
  final phrase = Shankarabharanam.exactScalePhrase();
  final env = phrase.buildEnvelope(withGamakas: false);
  final pcm = VoiceSynth().render(envelope: env, saHz: sa);
  final wav = encodeWavInt16(interleavedStereo: pcm, sampleRate: 48000);
  final out = File('tool/shankarabharanam_exact_240.wav');
  out.writeAsBytesSync(wav);
  print('wrote ${out.path} (${wav.length} bytes, ${env.totalSeconds.toStringAsFixed(1)}s)');
}

String _r(double r) {
  final known = {1.0:'1/1', 9/8:'9/8', 5/4:'5/4', 4/3:'4/3', 3/2:'3/2', 5/3:'5/3', 15/8:'15/8', 2.0:'2/1'};
  for (final e in known.entries) {
    if ((e.key - r).abs() < 1e-9) return e.value;
  }
  return r.toStringAsFixed(4);
}
