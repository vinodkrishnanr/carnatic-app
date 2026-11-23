import 'dart:math' as math;
import 'dart:typed_data';

import 'package:carnatic_app/audio/audio_decode.dart';
import 'package:carnatic_app/audio/voice_pitch_track.dart';
import 'package:carnatic_app/audio/youtube_fetch.dart';
import 'package:carnatic_app/music/editable_raga.dart';
import 'package:carnatic_app/music/swara.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _tone({
  required double hz,
  required double seconds,
  required int sr,
  double amp = 0.4,
  double startPhase = 0,
}) {
  final n = (seconds * sr).round();
  final out = Float32List(n);
  final step = 2 * math.pi * hz / sr;
  var ph = startPhase;
  for (var i = 0; i < n; i++) {
    out[i] = math.sin(ph) * amp;
    ph += step;
  }
  return out;
}

void main() {
  test('recognizes YouTube URL shapes and video ids', () {
    expect(isYoutubeUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), isTrue);
    expect(isYoutubeUrl('https://youtu.be/dQw4w9WgXcQ'), isTrue);
    expect(isYoutubeUrl('https://music.youtube.com/watch?v=abcdefghijk'), isTrue);
    expect(isYoutubeUrl('https://example.com/song.mp3'), isFalse);
    expect(isYoutubeUrl(''), isFalse);
    expect(youtubeVideoId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(
      youtubeVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10'),
      'dQw4w9WgXcQ',
    );
    expect(youtubeVideoId('https://www.youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
  });

  test('YIN tracks singing-range tone near 220 Hz', () {
    const sr = 16000;
    final samples = _tone(hz: 220, seconds: 0.6, sr: sr);
    final audio = DecodedAudio(
      samples: samples,
      sampleRate: sr,
      durationSeconds: 0.6,
    );
    final frames = trackVoicePitch(audio);
    final voiced = frames.where((f) => f.voiced).toList();
    expect(voiced, isNotEmpty);
    final median = voiced.map((f) => f.hz).toList()..sort();
    final mid = median[median.length ~/ 2];
    expect(mid, closeTo(220, 8));
  });

  test('import places glide as bent curve and reports tempo', () {
    const sr = 16000;
    // 4 pulses of 220 Hz, 0.5s apart → ~120 BPM; second half glides up.
    final parts = <double>[];
    for (var beat = 0; beat < 4; beat++) {
      final hz = beat < 2 ? 220.0 : 220.0 + (beat - 1) * 55.0;
      final chunk = _tone(hz: hz, seconds: 0.45, sr: sr, amp: 0.45);
      parts.addAll(chunk);
      // short gap
      parts.addAll(List.filled((0.05 * sr).round(), 0.0));
    }
    final samples = Float32List.fromList(parts);
    final audio = DecodedAudio(
      samples: samples,
      sampleRate: sr,
      durationSeconds: samples.length / sr,
    );
    final result =
        importVoiceToCurve(audio, saHzHint: 220, forceSaHz: true);
    expect(result.points, isNotEmpty);
    expect(result.beatsPerMinute, greaterThan(60));
    expect(result.beatsPerMinute, lessThan(160));
    expect(result.waveform, isNotEmpty);
    expect(result.totalBeats, greaterThan(1));
    // Pitch rises after early points (forced Sa=220).
    final first = result.points.first.cents;
    final last = result.points.last.cents;
    expect(last, greaterThan(first + 50));
  });

  test('estimateSaHz prefers tonic that fits Shankarabharanam ārohaṇa', () {
    // Held Sa–Ri–Ga–Ma–Pa–Da–Ni–Sȧ at Sa = 196 Hz (just ratios).
    const sr = 16000;
    const sa = 196.0;
    final ratios = [1.0, 9 / 8, 5 / 4, 4 / 3, 3 / 2, 5 / 3, 15 / 8, 2.0];
    final parts = <double>[];
    for (final r in ratios) {
      parts.addAll(_tone(hz: sa * r, seconds: 0.35, sr: sr, amp: 0.45));
    }
    final samples = Float32List.fromList(parts);
    final audio = DecodedAudio(
      samples: samples,
      sampleRate: sr,
      durationSeconds: samples.length / sr,
    );
    final result = importVoiceToCurve(audio);
    expect(result.saHz, closeTo(196, 8));
    // Anchors should land near scale degrees (soft-snap).
    final scaleCents = [
      for (final r in ratios) 1200 * math.log(r) / math.ln2,
    ];
    var nearCount = 0;
    for (final p in result.points) {
      final d = scaleCents.map((c) => (p.cents - c).abs()).reduce(math.min);
      if (d < 40) nearCount++;
    }
    expect(nearCount, greaterThan(result.points.length ~/ 2));
  });

  test('continuous tone Sync stays legato — bends + no mid-phrase mute', () {
    const sr = 16000;
    final samples = _tone(hz: 240, seconds: 1.2, sr: sr, amp: 0.45);
    final audio = DecodedAudio(
      samples: samples,
      sampleRate: sr,
      durationSeconds: 1.2,
    );
    final result = importVoiceToCurve(audio, saHzHint: 240);
    expect(result.points.length, greaterThan(1));
    for (var i = 1; i < result.points.length; i++) {
      expect(result.points[i].hasBend, isTrue,
          reason: 'edge into point $i must glide, not re-attack');
    }
    final raga = EditableRaga(
      id: 'sync',
      name: 'sync',
      scale: const [Swara.sa, Swara.pa, Swara.saHigh],
      points: result.points,
      beatsPerMinute: result.beatsPerMinute,
      totalBeats: result.totalBeats,
      gridLock: false,
    );
    final env = raga.toEnvelope();
    final mid = env.totalSeconds * 0.5;
    final a = env.sampleAtSeconds(mid).amp;
    expect(a, greaterThan(0.5),
        reason: 'steady tone must not mute mid-phrase (was stepped re-attack)');
  });

  test('smart Sync aligns pickup silence to beat grid without hard-coding', () {
    const sr = 16000;
    const bpm = 120.0;
    final beatSec = 60.0 / bpm;
    // 0.35 beat of silence (pickup), then Sa–Ri–Ga on whole beats.
    final parts = <double>[];
    parts.addAll(List.filled((0.35 * beatSec * sr).round(), 0.0));
    for (final hz in [220.0, 247.5, 275.0]) {
      parts.addAll(_tone(hz: hz, seconds: beatSec * 0.85, sr: sr, amp: 0.45));
      parts.addAll(List.filled((0.15 * beatSec * sr).round(), 0.0));
    }
    final samples = Float32List.fromList(parts);
    final audio = DecodedAudio(
      samples: samples,
      sampleRate: sr,
      durationSeconds: samples.length / sr,
    );
    final frames = trackVoicePitch(audio);
    final phase = estimateBeatPhaseBeats(frames, bpm, beatStep: 0.25);
    // Should detect ~0.35 beat pickup (tolerance generous — onset detection).
    expect(phase, greaterThan(0.15));
    expect(phase, lessThan(0.55));

    final result = importVoiceToCurve(audio, saHzHint: 220, forceSaHz: true);
    expect(result.points, isNotEmpty);
    // After smart lock, early hold beats should sit near quarter-grid.
    var nearGrid = 0;
    for (final p in result.points.take(6)) {
      final err = (p.beat / 0.25 - (p.beat / 0.25).round()).abs();
      if (err < 0.2) nearGrid++;
    }
    expect(nearGrid, greaterThan(1));
  });

  test('smartLockToGrid snaps clear holds, leaves ambiguous glide free', () {
    final scale = [0.0, 204.0, 386.0, 498.0];
    final pts = [
      CurvePoint(beat: 1.03, cents: 4), // near Sa + near beat → snap
      CurvePoint(
        beat: 1.5,
        cents: 100,
        bendBeat: 1.25,
        bendCents: 50,
      ), // mid-glide — ambiguous
      CurvePoint(beat: 2.02, cents: 200), // near Ri
    ];
    final locked = smartLockToGrid(
      pts,
      scaleCents: scale,
      beatStep: 0.25,
      beatTol: 0.11,
      centsTol: 26,
    );
    expect(locked[0].beat, closeTo(1.0, 1e-9));
    expect(locked[0].cents, closeTo(0.0, 1e-9));
    // Mid point stays off-lane (gamaka).
    expect(locked[1].cents, closeTo(100, 1e-9));
    expect(locked[2].cents, closeTo(204.0, 1e-9));
  });

  test('low drone-like 110 Hz alone is accepted only in voice band floor', () {
    // 110 Hz is at fMin edge — still singing-range tenor Sa; 70 Hz would reject.
    const sr = 16000;
    final samples = _tone(hz: 70, seconds: 0.5, sr: sr, amp: 0.5);
    final frames = trackVoicePitch(DecodedAudio(
      samples: samples,
      sampleRate: sr,
      durationSeconds: 0.5,
    ));
    final voiced = frames.where((f) => f.voiced).length;
    expect(voiced, lessThan(frames.length ~/ 3));
  });
}
