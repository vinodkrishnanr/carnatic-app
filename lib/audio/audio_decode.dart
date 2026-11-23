import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Decode WAV/MP3 (any ffmpeg-readable file) to mono float32 PCM.
class DecodedAudio {
  const DecodedAudio({
    required this.samples,
    required this.sampleRate,
    required this.durationSeconds,
  });

  final Float32List samples;
  final int sampleRate;
  final double durationSeconds;
}

/// Uses system `ffmpeg` (no extra Dart package). Throws if missing/fails.
Future<DecodedAudio> decodeAudioFile(
  String path, {
  int sampleRate = 16000,
}) async {
  final ffmpeg = await whichCommand('ffmpeg');
  if (ffmpeg == null) {
    throw StateError('ffmpeg not found — install ffmpeg to import audio.');
  }
  final result = await Process.run(
    ffmpeg,
    [
      '-nostdin',
      '-i',
      path,
      '-ac',
      '1',
      '-ar',
      '$sampleRate',
      '-f',
      'f32le',
      '-v',
      'error',
      'pipe:1',
    ],
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) {
    final err = result.stderr is String
        ? result.stderr as String
        : String.fromCharCodes(result.stderr as List<int>);
    throw StateError('Could not decode audio: ${err.trim()}');
  }
  final raw = result.stdout as List<int>;
  if (raw.length < 4) {
    throw StateError('Decoded audio is empty.');
  }
  final bytes = Uint8List.fromList(raw);
  final bd = ByteData.sublistView(bytes);
  final n = bytes.length ~/ 4;
  final samples = Float32List(n);
  for (var i = 0; i < n; i++) {
    samples[i] = bd.getFloat32(i * 4, Endian.little);
  }
  return DecodedAudio(
    samples: samples,
    sampleRate: sampleRate,
    durationSeconds: n / sampleRate,
  );
}

/// Peak envelope for waveform display (absolute max per bucket).
Float32List waveformPeaks(Float32List mono, {int buckets = 400}) {
  if (mono.isEmpty || buckets < 1) return Float32List(0);
  final out = Float32List(buckets);
  final step = mono.length / buckets;
  for (var b = 0; b < buckets; b++) {
    final start = (b * step).floor();
    final end = math.min(mono.length, ((b + 1) * step).ceil());
    var peak = 0.0;
    for (var i = start; i < end; i++) {
      final a = mono[i].abs();
      if (a > peak) peak = a;
    }
    out[b] = peak;
  }
  return out;
}

Future<String?> whichCommand(String cmd) async {
  final r = await Process.run('which', [cmd]);
  if (r.exitCode != 0) return null;
  final p = (r.stdout as String).trim();
  return p.isEmpty ? null : p;
}
