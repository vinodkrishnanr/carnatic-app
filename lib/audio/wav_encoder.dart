import 'dart:typed_data';

/// Encode interleaved float32 stereo PCM as a 16-bit WAV for [SoLoud.loadMem].
Uint8List encodeWavInt16({
  required Float32List interleavedStereo,
  required int sampleRate,
}) {
  final frames = interleavedStereo.length ~/ 2;
  final dataSize = frames * 2 * 2; // 16-bit stereo
  final bytes = BytesBuilder(copy: false);

  void writeString(String s) => bytes.add(s.codeUnits);
  void writeUint32(int v) {
    bytes.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  }

  void writeUint16(int v) {
    bytes.add([v & 0xff, (v >> 8) & 0xff]);
  }

  writeString('RIFF');
  writeUint32(36 + dataSize);
  writeString('WAVE');
  writeString('fmt ');
  writeUint32(16);
  writeUint16(1); // PCM
  writeUint16(2); // stereo
  writeUint32(sampleRate);
  writeUint32(sampleRate * 2 * 2); // byte rate
  writeUint16(4); // block align
  writeUint16(16); // bits
  writeString('data');
  writeUint32(dataSize);

  final pcm = ByteData(dataSize);
  for (var i = 0; i < frames; i++) {
    for (var c = 0; c < 2; c++) {
      final f = interleavedStereo[i * 2 + c].clamp(-1.0, 1.0);
      final s = (f * 32767.0).round().clamp(-32768, 32767);
      pcm.setInt16((i * 2 + c) * 2, s, Endian.little);
    }
  }
  bytes.add(pcm.buffer.asUint8List());
  return bytes.toBytes();
}
