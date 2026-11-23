import 'dart:math' as math;
import 'dart:typed_data';

import '../music/editable_raga.dart';
import 'audio_decode.dart';

/// One voiced F0 frame (Hz) after voice-band tracking.
class PitchFrame {
  const PitchFrame({
    required this.seconds,
    required this.hz,
    required this.voiced,
  });

  final double seconds;
  final double hz;
  final bool voiced;
}

class AudioImportResult {
  const AudioImportResult({
    required this.points,
    required this.beatsPerMinute,
    required this.totalBeats,
    required this.waveform,
    required this.durationSeconds,
    required this.saHz,
  });

  final List<CurvePoint> points;
  final double beatsPerMinute;
  final double totalBeats;
  final Float32List waveform;
  final double durationSeconds;
  final double saHz;
}

/// Track singing voice F0 (not tanpura/drone), estimate tempo, build grid curve.
AudioImportResult importVoiceToCurve(
  DecodedAudio audio, {
  double? saHzHint,
}) {
  final frames = trackVoicePitch(audio);
  final bpm = estimateTempoBpm(audio, frames);
  final saHz = saHzHint ?? estimateSaHz(frames) ?? 240.0;
  final points = framesToCurvePoints(
    frames,
    saHz: saHz,
    bpm: bpm,
  );
  var totalBeats = audio.durationSeconds * bpm / 60.0;
  if (points.isNotEmpty) {
    totalBeats = math.max(totalBeats, points.last.beat + 0.5);
  }
  totalBeats = math.max(1.0, (totalBeats * 4).round() / 4.0);

  return AudioImportResult(
    points: points,
    beatsPerMinute: bpm,
    totalBeats: totalBeats,
    waveform: waveformPeaks(audio.samples, buckets: 480),
    durationSeconds: audio.durationSeconds,
    saHz: saHz,
  );
}

/// YIN F0 in singing range (~110–900 Hz) after high-pass — skips low drone.
List<PitchFrame> trackVoicePitch(DecodedAudio audio) {
  final sr = audio.sampleRate;
  final hp = _highPass(audio.samples, sr, cutoffHz: 100);
  const hopMs = 10.0;
  final hop = math.max(1, (sr * hopMs / 1000).round());
  final win = math.max(hop * 2, (sr * 0.04).round()); // ~40 ms
  final fMin = 110.0; // above typical low Sa drone / rumble
  final fMax = 900.0;
  final minLag = (sr / fMax).floor();
  final maxLag = (sr / fMin).ceil();

  final out = <PitchFrame>[];
  for (var start = 0; start + win < hp.length; start += hop) {
    final t = start / sr;
    final slice = Float32List.sublistView(hp, start, start + win);
    final rms = _rms(slice);
    if (rms < 0.012) {
      out.add(PitchFrame(seconds: t, hz: 0, voiced: false));
      continue;
    }
    final hz = _yin(slice, sr, minLag, maxLag);
    // Reject very steady ultra-low candidates (drone bleed).
    final voiced = hz >= fMin && hz <= fMax;
    out.add(PitchFrame(seconds: t, hz: voiced ? hz : 0, voiced: voiced));
  }
  return _medianSmoothHz(out, radius: 2);
}

/// Tempo from onset strength autocorrelation (typical Carnatic 40–160 BPM).
double estimateTempoBpm(DecodedAudio audio, List<PitchFrame> frames) {
  final sr = audio.sampleRate;
  final hop = math.max(1, (sr * 0.01).round());
  final env = <double>[];
  for (var i = 0; i + hop < audio.samples.length; i += hop) {
    var e = 0.0;
    for (var j = i; j < i + hop; j++) {
      e += audio.samples[j] * audio.samples[j];
    }
    env.add(math.sqrt(e / hop));
  }
  if (env.length < 8) return 72.0;

  // Spectral-flux-like onset: positive energy diffs + voiced onsets.
  final onset = Float64List(env.length);
  for (var i = 1; i < env.length; i++) {
    final d = env[i] - env[i - 1];
    onset[i] = d > 0 ? d : 0.0;
  }
  for (final f in frames) {
    if (!f.voiced) continue;
    final idx = (f.seconds / 0.01).round().clamp(0, onset.length - 1);
    onset[idx] += 0.15;
  }

  final bpmMin = 40.0;
  final bpmMax = 160.0;
  final lagMin = (60.0 / bpmMax / 0.01).round();
  final lagMax = (60.0 / bpmMin / 0.01).round().clamp(lagMin + 1, onset.length ~/ 2);

  var bestLag = lagMin;
  var bestCorr = -1e9;
  for (var lag = lagMin; lag <= lagMax; lag++) {
    var corr = 0.0;
    var n = 0;
    for (var i = 0; i + lag < onset.length; i++) {
      corr += onset[i] * onset[i + lag];
      n++;
    }
    if (n == 0) continue;
    corr /= n;
    if (corr > bestCorr) {
      bestCorr = corr;
      bestLag = lag;
    }
  }

  var bpm = 60.0 / (bestLag * 0.01);
  // Prefer double/half if nearer common practice tempos.
  if (bpm < 50) bpm *= 2;
  if (bpm > 140) bpm /= 2;
  return (bpm * 2).round() / 2.0; // 0.5 BPM resolution
}

double? estimateSaHz(List<PitchFrame> frames) {
  final voiced = [
    for (final f in frames)
      if (f.voiced && f.hz > 0) f.hz,
  ];
  if (voiced.length < 8) return null;
  voiced.sort();
  // Lower quartile of voiced pitches ≈ Sa neighbourhood for many phrases.
  final q = voiced[(voiced.length * 0.18).floor()];
  // Snap toward common practice Sa (round to nearest 5 Hz in 110–320).
  final clamped = q.clamp(110.0, 320.0);
  return (clamped / 5).round() * 5.0;
}

List<CurvePoint> framesToCurvePoints(
  List<PitchFrame> frames, {
  required double saHz,
  required double bpm,
}) {
  if (frames.isEmpty) return [];

  double centsOf(double hz) => 1200.0 * math.log(hz / saHz) / math.ln2;
  double beatOf(double sec) => sec * bpm / 60.0;

  // Build continuous voiced runs with cents.
  final series = <({double beat, double cents, bool voiced})>[];
  for (final f in frames) {
    series.add((
      beat: beatOf(f.seconds),
      cents: f.voiced ? centsOf(f.hz) : 0.0,
      voiced: f.voiced,
    ));
  }

  final points = <CurvePoint>[];
  var i = 0;
  while (i < series.length) {
    if (!series[i].voiced) {
      i++;
      continue;
    }
    // Find end of voiced run.
    var j = i;
    while (j + 1 < series.length && series[j + 1].voiced) {
      j++;
    }
    _appendRunAsPoints(series, i, j, points);
    i = j + 1;
  }

  if (points.isEmpty) return points;

  // Ensure start silence marker if first voiced is late? Skip — keep sounding.

  // Deduplicate near-identical successive anchors.
  final cleaned = <CurvePoint>[points.first];
  for (var k = 1; k < points.length; k++) {
    final a = cleaned.last;
    final b = points[k];
    if ((b.beat - a.beat).abs() < 0.04 && (b.cents - a.cents).abs() < 12) {
      cleaned[cleaned.length - 1] = b.copyWith(
        bendBeat: b.bendBeat ?? a.bendBeat,
        bendCents: b.bendCents ?? a.bendCents,
      );
    } else {
      cleaned.add(b);
    }
  }
  return cleaned;
}

void _appendRunAsPoints(
  List<({double beat, double cents, bool voiced})> series,
  int start,
  int end,
  List<CurvePoint> out,
) {
  // Adaptive RDP-ish: keep corners + midpoints of glides.
  final idxs = <int>[start];
  var last = start;
  const holdTol = 18.0; // cents — stay = hold
  const glideTol = 35.0;

  for (var i = start + 1; i <= end; i++) {
    final dc = (series[i].cents - series[last].cents).abs();
    final dt = series[i].beat - series[last].beat;
    final rate = dt > 1e-6 ? dc / dt : dc;
    final isCorner = i == end ||
        (dc > holdTol && rate > glideTol) ||
        (i > start + 1 &&
            _turning(series[i - 2].cents, series[i - 1].cents, series[i].cents));
    if (isCorner && i != last) {
      idxs.add(i);
      last = i;
    }
  }
  if (idxs.last != end) idxs.add(end);

  for (var k = 0; k < idxs.length; k++) {
    final ix = idxs[k];
    final beat = series[ix].beat;
    final cents = series[ix].cents.clamp(-100.0, 1400.0);
    double? bendBeat;
    double? bendCents;
    if (k > 0) {
      final prevIx = idxs[k - 1];
      final mid = (prevIx + ix) ~/ 2;
      final prevC = series[prevIx].cents;
      final curC = series[ix].cents;
      final midC = series[mid].cents;
      final linearMid = (prevC + curC) / 2;
      // Curved if mid pitch leaves the straight line.
      if ((midC - linearMid).abs() > 15 ||
          (curC - prevC).abs() > holdTol && (ix - prevIx) >= 3) {
        bendBeat = series[mid].beat;
        bendCents = midC.clamp(-100.0, 1400.0);
      }
    }
    out.add(CurvePoint(
      beat: beat,
      cents: cents,
      amp: 1.0,
      bendBeat: bendBeat,
      bendCents: bendCents,
    ));
  }
}

bool _turning(double a, double b, double c) {
  final d1 = b - a;
  final d2 = c - b;
  return d1.sign != d2.sign && d1.abs() > 12 && d2.abs() > 12;
}

Float32List _highPass(Float32List x, int sr, {required double cutoffHz}) {
  // One-pole high-pass.
  final rc = 1 / (2 * math.pi * cutoffHz);
  final dt = 1 / sr;
  final alpha = rc / (rc + dt);
  final y = Float32List(x.length);
  var prevX = 0.0;
  var prevY = 0.0;
  for (var i = 0; i < x.length; i++) {
    final yi = alpha * (prevY + x[i] - prevX);
    y[i] = yi;
    prevX = x[i];
    prevY = yi;
  }
  return y;
}

double _rms(Float32List x) {
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return math.sqrt(s / x.length);
}

/// Classic YIN — returns Hz or 0 if unvoiced.
double _yin(Float32List buf, int sr, int minLag, int maxLag) {
  final n = buf.length;
  maxLag = math.min(maxLag, n ~/ 2);
  if (maxLag <= minLag + 2) return 0;

  final d = Float64List(maxLag + 1);
  for (var tau = 1; tau <= maxLag; tau++) {
    var sum = 0.0;
    final lim = n - tau;
    for (var i = 0; i < lim; i++) {
      final diff = buf[i] - buf[i + tau];
      sum += diff * diff;
    }
    d[tau] = sum;
  }

  // Cumulative mean normalized difference.
  final cmnd = Float64List(maxLag + 1);
  cmnd[0] = 1;
  var running = 0.0;
  for (var tau = 1; tau <= maxLag; tau++) {
    running += d[tau];
    cmnd[tau] = running > 1e-12 ? d[tau] * tau / running : 1.0;
  }

  const threshold = 0.15;
  var tau = minLag;
  while (tau + 1 <= maxLag) {
    if (cmnd[tau] < threshold) {
      while (tau + 1 <= maxLag && cmnd[tau + 1] < cmnd[tau]) {
        tau++;
      }
      break;
    }
    tau++;
  }
  if (tau >= maxLag || cmnd[tau] >= threshold) return 0;

  // Parabolic interpolation.
  final x0 = tau < 1 ? tau : tau - 1;
  final x2 = tau + 1 > maxLag ? tau : tau + 1;
  double better = tau.toDouble();
  if (x0 != tau && x2 != tau) {
    final s0 = cmnd[x0];
    final s1 = cmnd[tau];
    final s2 = cmnd[x2];
    final denom = 2 * (2 * s1 - s2 - s0);
    if (denom.abs() > 1e-12) {
      better = tau + (s2 - s0) / denom;
    }
  }
  if (better < 1) return 0;
  return sr / better;
}

List<PitchFrame> _medianSmoothHz(List<PitchFrame> frames, {int radius = 2}) {
  if (frames.isEmpty) return frames;
  final out = List<PitchFrame>.from(frames);
  for (var i = 0; i < frames.length; i++) {
    if (!frames[i].voiced) continue;
    final vals = <double>[];
    for (var j = i - radius; j <= i + radius; j++) {
      if (j < 0 || j >= frames.length) continue;
      if (frames[j].voiced) vals.add(frames[j].hz);
    }
    if (vals.isEmpty) continue;
    vals.sort();
    out[i] = PitchFrame(
      seconds: frames[i].seconds,
      hz: vals[vals.length ~/ 2],
      voiced: true,
    );
  }
  return out;
}
