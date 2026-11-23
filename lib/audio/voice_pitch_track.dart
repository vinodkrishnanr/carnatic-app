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
    this.beatPhaseBeats = 0,
    this.beatsPerBar = 4,
  });

  final List<CurvePoint> points;
  final double beatsPerMinute;
  final double totalBeats;
  final Float32List waveform;
  final double durationSeconds;
  final double saHz;

  /// Seconds-of-silence / pickup removed so attacks align to the bar grid.
  final double beatPhaseBeats;

  /// Meter used for bar snapping (default 4/4).
  final int beatsPerBar;
}

/// Track singing voice F0 (not tanpura/drone), estimate tempo, build grid curve.
///
/// [saHzHint] is only used when [forceSaHz] is true. Sync should leave Sa
/// auto-detected from the recording (engine Sa is often wrong for the file).
///
/// Smart Sync: estimates a **beat-phase offset** (recordings rarely start on
/// the downbeat), then locks clear holds to beat + sargam when confidence is
/// high — never forces a wrong note/beat.
AudioImportResult importVoiceToCurve(
  DecodedAudio audio, {
  double? saHzHint,
  bool forceSaHz = false,
  List<double>? scaleRatios,
  int beatsPerBar = 4,
  double beatStep = 0.25,
}) {
  final frames = trackVoicePitch(audio);
  final bpm = estimateTempoBpm(audio, frames);
  final ratios = scaleRatios ?? _shankaraRatios;
  final estimated = estimateSaHz(frames, scaleRatios: ratios);
  final saHz = (forceSaHz && saHzHint != null)
      ? saHzHint
      : (estimated ?? saHzHint ?? 240.0);
  final phaseBeats = estimateBeatPhaseBeats(
    frames,
    bpm,
    beatsPerBar: beatsPerBar,
    beatStep: beatStep,
  );
  final points = framesToCurvePoints(
    frames,
    saHz: saHz,
    bpm: bpm,
    scaleRatios: ratios,
    beatPhaseBeats: phaseBeats,
    beatStep: beatStep,
  );
  var totalBeats = audio.durationSeconds * bpm / 60.0;
  if (points.isNotEmpty) {
    totalBeats = math.max(totalBeats, points.last.beat + 0.5);
  }
  // Round up to a whole bar so the grid reads in 4/4 (or [beatsPerBar]).
  final bar = beatsPerBar.toDouble().clamp(1.0, 16.0);
  totalBeats = math.max(bar, (totalBeats / bar).ceil() * bar);

  return AudioImportResult(
    points: points,
    beatsPerMinute: bpm,
    totalBeats: totalBeats,
    waveform: waveformPeaks(audio.samples, buckets: 480),
    durationSeconds: audio.durationSeconds,
    saHz: saHz,
    beatPhaseBeats: phaseBeats,
    beatsPerBar: beatsPerBar,
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
  return _octaveCorrect(_medianSmoothHz(out, radius: 3));
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

/// Śankarābharaṇam just ratios (default Sync scale).
const _shankaraRatios = <double>[
  1.0,
  9 / 8,
  5 / 4,
  4 / 3,
  3 / 2,
  5 / 3,
  15 / 8,
  2.0,
];

/// Fold [hz] into roughly one octave above Sa (mando → madhya).
double foldHzToSa(double hz, double saHz) {
  if (hz <= 0 || saHz <= 0) return hz;
  var h = hz;
  while (h < saHz * 0.72) {
    h *= 2;
  }
  while (h > saHz * 2.25) {
    h /= 2;
  }
  return h;
}

/// Pick Sa that best fits [scaleRatios] against voiced F0 (not a raw quartile —
/// quartile often lands on Ri for an ārohaṇa).
double? estimateSaHz(
  List<PitchFrame> frames, {
  List<double> scaleRatios = _shankaraRatios,
}) {
  final voiced = [
    for (final f in frames)
      if (f.voiced && f.hz > 0) f.hz,
  ];
  if (voiced.length < 8) return null;

  final hist = <int, int>{};
  for (final h in voiced) {
    final b = (h / 2).round() * 2;
    hist[b] = (hist[b] ?? 0) + 1;
  }
  final cands = <double>{};
  for (final e in hist.entries) {
    if (e.value < 3) continue;
    for (final f in const [0.5, 1.0, 2.0]) {
      final v = e.key * f;
      if (v >= 110 && v <= 320) {
        cands.add((v / 2).round() * 2.0);
      }
    }
  }
  if (cands.isEmpty) {
    final sorted = List<double>.from(voiced)..sort();
    final q = sorted[(sorted.length * 0.12).floor()].clamp(110.0, 320.0);
    return (q / 5).round() * 5.0;
  }

  double meanErr(double sa) {
    var err = 0.0;
    var n = 0;
    for (final h0 in voiced) {
      final h = foldHzToSa(h0, sa);
      final cents = 1200.0 * math.log(h / sa) / math.ln2;
      var best = 1e9;
      for (final r in scaleRatios) {
        final c = 1200.0 * math.log(r) / math.ln2;
        best = math.min(best, (cents - c).abs());
      }
      err += best;
      n++;
    }
    return n == 0 ? 1e9 : err / n;
  }

  double? bestSa;
  var bestErr = 1e9;
  for (final sa in cands) {
    final e = meanErr(sa);
    // Prefer lower Sa when errors are close (Ri vs Sa ambiguity).
    if (bestSa == null ||
        e < bestErr - 2 ||
        (e <= bestErr + 3 && sa < bestSa)) {
      bestErr = e;
      bestSa = sa;
    }
  }
  if (bestSa == null) return null;
  return (bestSa / 2).round() * 2.0;
}

/// Find how many beats of pickup/silence sit before the first bar.
///
/// Searches a phase in one bar that best aligns voiced onsets to [beatStep]
/// subdivisions. Returns 0 when evidence is weak (no hard-coded offset).
double estimateBeatPhaseBeats(
  List<PitchFrame> frames,
  double bpm, {
  int beatsPerBar = 4,
  double beatStep = 0.25,
}) {
  if (bpm <= 0 || frames.isEmpty) return 0;
  final onsets = <double>[];
  var prev = false;
  for (final f in frames) {
    if (f.voiced && !prev) onsets.add(f.seconds);
    prev = f.voiced;
  }
  if (onsets.length < 2) return 0;

  final beatSec = 60.0 / bpm;
  final barBeats = beatsPerBar.toDouble().clamp(1.0, 16.0);
  final step = beatStep <= 0 ? 0.25 : beatStep;
  final searchBeats = barBeats; // one bar of phase candidates
  const samples = 96;
  var bestPhase = 0.0;
  var bestScore = -1e9;
  var meanScore = 0.0;

  for (var s = 0; s < samples; s++) {
    final phaseBeats = (s / samples) * searchBeats;
    var score = 0.0;
    for (final t in onsets) {
      final beat = t / beatSec - phaseBeats;
      if (beat < -0.5) continue;
      final nearest = (beat / step).round() * step;
      final err = (beat - nearest).abs();
      // Tight Gaussian — only near-grid onsets contribute.
      score += math.exp(-(err * err) / (2 * 0.06 * 0.06));
      // Bonus for landing on whole beats (bar feel in 4/4).
      final wholeErr = (beat - beat.roundToDouble()).abs();
      if (wholeErr < 0.08) score += 0.35;
      // Slight bonus for bar downbeats.
      final barPos = beat % barBeats;
      if (barPos.abs() < 0.1 || (barBeats - barPos).abs() < 0.1) {
        score += 0.25;
      }
    }
    meanScore += score;
    if (score > bestScore) {
      bestScore = score;
      bestPhase = phaseBeats;
    }
  }
  meanScore /= samples;
  // Weak / flat evidence → don't invent a phase.
  if (bestScore < onsets.length * 0.35 || bestScore < meanScore * 1.15) {
    return 0;
  }
  return bestPhase;
}

List<CurvePoint> framesToCurvePoints(
  List<PitchFrame> frames, {
  required double saHz,
  required double bpm,
  List<double> scaleRatios = _shankaraRatios,
  double beatPhaseBeats = 0,
  double beatStep = 0.25,
}) {
  if (frames.isEmpty) return [];

  final scaleCents = [
    for (final r in scaleRatios) 1200.0 * math.log(r) / math.ln2,
  ];

  double centsOf(double hz) {
    final folded = foldHzToSa(hz, saHz);
    return 1200.0 * math.log(folded / saHz) / math.ln2;
  }

  double beatOf(double sec) => sec * bpm / 60.0 - beatPhaseBeats;

  // Build continuous voiced runs with cents (octave-folded to Sa).
  final series = <({double beat, double cents, bool voiced})>[];
  for (final f in frames) {
    series.add((
      beat: beatOf(f.seconds),
      cents: f.voiced ? centsOf(f.hz).clamp(-20.0, 1220.0) : 0.0,
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

  // Shift so the timeline starts at beat ≥ 0 after phase correction.
  final minBeat = points.map((p) => p.beat).reduce(math.min);
  final shift = minBeat < 0 ? -minBeat : 0.0;
  var cleaned = <CurvePoint>[
    for (final p in points)
      p.copyWith(
        beat: p.beat + shift,
        bendBeat: p.bendBeat == null ? null : p.bendBeat! + shift,
      ),
  ];

  // Deduplicate near-identical successive anchors.
  final deduped = <CurvePoint>[cleaned.first];
  for (var k = 1; k < cleaned.length; k++) {
    final a = deduped.last;
    final b = cleaned[k];
    if ((b.beat - a.beat).abs() < 0.04 && (b.cents - a.cents).abs() < 12) {
      deduped[deduped.length - 1] = b.copyWith(
        bendBeat: b.bendBeat ?? a.bendBeat,
        bendCents: b.bendCents ?? a.bendCents,
      );
    } else {
      deduped.add(b);
    }
  }

  return smartLockToGrid(
    deduped,
    scaleCents: scaleCents,
    beatStep: beatStep,
  );
}

/// Lock clear holds to beat + sargam; leave ambiguous / gliding pitches alone.
List<CurvePoint> smartLockToGrid(
  List<CurvePoint> points, {
  required List<double> scaleCents,
  double beatStep = 0.25,
  double beatTol = 0.11,
  double centsTol = 26,
}) {
  if (points.isEmpty) return points;
  final step = beatStep <= 0 ? 0.25 : beatStep;
  final out = <CurvePoint>[];

  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    final glideCorner = _isGlideCorner(points, i);
    var beat = p.beat;
    var cents = p.cents;
    double? bendBeat = p.bendBeat;
    double? bendCents = p.bendCents;

    final snapped = _nearestScaleCents(cents, scaleCents);
    final clearLane = snapped != null &&
        (cents - snapped).abs() <= (glideCorner ? 16.0 : centsTol) &&
        _scaleAmbiguity(cents, scaleCents) >= (glideCorner ? 14.0 : 12.0);

    // Pitch: snap only when unambiguously near a sargam lane.
    if (clearLane) {
      cents = snapped;
    }

    // Beat: snap when near a subdivision AND (clear swara OR not mid-gamaka).
    if (clearLane || !glideCorner) {
      final snappedBeat = (beat / step).round() * step;
      if ((beat - snappedBeat).abs() <= beatTol) {
        beat = snappedBeat;
      }
    }

    // Bend controls: leave free on glides; never force mid-gamaka to a lane.
    if (bendBeat != null &&
        bendCents != null &&
        i > 0 &&
        clearLane &&
        !_isGlideCorner(points, i - 1)) {
      final sb = (bendBeat / step).round() * step;
      if ((bendBeat - sb).abs() <= beatTol * 1.2) bendBeat = sb;
    }

    out.add(CurvePoint(
      beat: beat.clamp(0.0, 1e9),
      cents: cents,
      amp: p.amp,
      bendBeat: bendBeat,
      bendCents: bendCents,
    ));
  }
  return out;
}

/// True when both neighbors move away in pitch — mid-gamaka / glide corner.
bool _isGlideCorner(List<CurvePoint> points, int i) {
  if (i <= 0 || i >= points.length - 1) return false;
  final p = points[i];
  final dPrev = (p.cents - points[i - 1].cents).abs();
  final dNext = (points[i + 1].cents - p.cents).abs();
  return dPrev > 40 && dNext > 40;
}

double? _nearestScaleCents(double cents, List<double> scaleCents) {
  if (scaleCents.isEmpty) return null;
  var best = scaleCents.first;
  var bestD = (cents - best).abs();
  for (final c in scaleCents) {
    final d = (cents - c).abs();
    if (d < bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

/// Gap between best and second-best scale lane (large = unambiguous).
double _scaleAmbiguity(double cents, List<double> scaleCents) {
  if (scaleCents.length < 2) return 999;
  var best = 1e9;
  var second = 1e9;
  for (final c in scaleCents) {
    final d = (cents - c).abs();
    if (d < best) {
      second = best;
      best = d;
    } else if (d < second) {
      second = d;
    }
  }
  return second - best;
}

void _appendRunAsPoints(
  List<({double beat, double cents, bool voiced})> series,
  int start,
  int end,
  List<CurvePoint> out,
) {
  // Dense keypoints so gamakas survive; every edge gets a bend so playback
  // glides continuously. Unbent edges re-attack (Sa–Sa articulation) — that
  // made Sync sound choppy even when the F0 track was smooth.
  final idxs = <int>[start];
  var last = start;
  const holdTol = 10.0; // cents — keep a point when pitch moves
  const maxGapBeats = 0.06; // ~keep time resolution inside a held swara

  for (var i = start + 1; i <= end; i++) {
    final dc = (series[i].cents - series[last].cents).abs();
    final dt = series[i].beat - series[last].beat;
    final isCorner = i == end ||
        dc >= holdTol ||
        dt >= maxGapBeats ||
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
      // Control point = real F0 nearest the temporal midpoint (always set).
      final midBeat = (series[prevIx].beat + series[ix].beat) / 2;
      var best = (prevIx + ix) ~/ 2;
      var bestD = (series[best].beat - midBeat).abs();
      for (var m = prevIx; m <= ix; m++) {
        final d = (series[m].beat - midBeat).abs();
        if (d < bestD) {
          bestD = d;
          best = m;
        }
      }
      bendBeat = series[best].beat;
      bendCents = series[best].cents.clamp(-100.0, 1400.0);
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

/// Pull YIN octave jumps back toward a running reference pitch.
List<PitchFrame> _octaveCorrect(List<PitchFrame> frames) {
  if (frames.isEmpty) return frames;
  final out = List<PitchFrame>.from(frames);
  double? ref;
  for (var i = 0; i < out.length; i++) {
    final f = out[i];
    if (!f.voiced || f.hz <= 0) continue;
    var h = f.hz;
    if (ref != null) {
      while (h > ref * 1.85) {
        h /= 2;
      }
      while (h < ref * 0.54) {
        h *= 2;
      }
      ref = ref * 0.8 + h * 0.2;
    } else {
      ref = h;
    }
    if ((h - f.hz).abs() > 1) {
      out[i] = PitchFrame(seconds: f.seconds, hz: h, voiced: true);
    }
  }
  return out;
}
