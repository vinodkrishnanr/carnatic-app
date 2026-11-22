import 'dart:math' as math;
import 'dart:typed_data';

import '../music/pitch_envelope.dart';

/// Soft harmonic voice: phase-accumulator oscillator (no sin(2πft) resets).
class VoiceSynth {
  VoiceSynth({
    this.sampleRate = 48000,
    this.harmonics = const [1.0, 0.4, 0.18],
  });

  final int sampleRate;
  final List<double> harmonics;

  /// Renders interleaved stereo f32 PCM from a timed pitch envelope.
  ///
  /// Walks envelope points with a monotonic index (O(frames + points)),
  /// not a full scan per sample.
  Float32List render({
    required TimedPitchEnvelope envelope,
    required double saHz,
    double gain = 0.55,
    double targetPeak = 0.72,
  }) {
    final frames = math.max(1, (envelope.totalSeconds * sampleRate).ceil());
    final out = Float32List(frames * 2);
    var phase = 0.0;
    const twoPi = math.pi * 2.0;

    final pts = envelope.points;
    var seg = 0;
    var peak = 1e-9;

    for (var i = 0; i < frames; i++) {
      final t = i / sampleRate;

      while (seg < pts.length - 2 && t > pts[seg + 1].seconds) {
        seg++;
      }

      final a = pts[seg.clamp(0, pts.length - 1)];
      final b = pts[math.min(seg + 1, pts.length - 1)];
      final span = (b.seconds - a.seconds).abs() < 1e-12
          ? 1.0
          : (b.seconds - a.seconds);
      final u = ((t - a.seconds) / span).clamp(0.0, 1.0);
      final sCurve = u * u * (3 - 2 * u);
      final cents = a.cents + (b.cents - a.cents) * sCurve;
      final amp = a.amp + (b.amp - a.amp) * sCurve;

      final freq = saHz * math.pow(2.0, cents / 1200.0);
      final edge = _edgeFade(i, frames, sampleRate);

      var wave = 0.0;
      for (var h = 0; h < harmonics.length; h++) {
        wave += math.sin(phase * (h + 1)) * harmonics[h];
      }
      final sample = _softClip(wave) * amp * gain * edge;
      if (sample.abs() > peak) peak = sample.abs();

      out[i * 2] = sample;
      out[i * 2 + 1] = sample;

      phase += twoPi * freq / sampleRate;
      if (phase > twoPi * 16) phase -= twoPi * 16;
    }

    // Peak-normalize for a consistent listening level.
    final scale = targetPeak / peak;
    if ((scale - 1.0).abs() > 0.05) {
      for (var i = 0; i < out.length; i++) {
        out[i] = (out[i] * scale).clamp(-1.0, 1.0);
      }
    }
    return out;
  }

  static double _softClip(double x) {
    final ax = x.abs();
    return (x * (1 + 0.25 * ax) / (1 + ax + 0.25 * ax * ax)).clamp(-1.0, 1.0);
  }

  static double _edgeFade(int i, int frames, int sr) {
    final fade = (sr * 0.008).round().clamp(1, 400);
    if (i < fade) {
      final u = i / fade;
      return u * u * (3 - 2 * u);
    }
    if (i > frames - fade) {
      final u = (frames - i) / fade;
      return u * u * (3 - 2 * u);
    }
    return 1.0;
  }
}
