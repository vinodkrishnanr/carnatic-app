import 'dart:math' as math;
import 'dart:typed_data';

import 'package:carnatic_app/audio/audio_decode.dart';
import 'package:carnatic_app/audio/voice_pitch_track.dart';
import 'package:carnatic_app/audio/youtube_fetch.dart';
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
    final result = importVoiceToCurve(audio, saHzHint: 220);
    expect(result.points, isNotEmpty);
    expect(result.beatsPerMinute, greaterThan(60));
    expect(result.beatsPerMinute, lessThan(160));
    expect(result.waveform, isNotEmpty);
    expect(result.totalBeats, greaterThan(1));
    // Pitch rises after early points.
    final first = result.points.first.cents;
    final last = result.points.last.cents;
    expect(last, greaterThan(first + 50));
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
