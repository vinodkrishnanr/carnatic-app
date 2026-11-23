import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../music/phrase.dart';
import '../music/pitch_envelope.dart';
import 'voice_synth.dart';
import 'wav_encoder.dart';

class PhraseRenderResult {
  const PhraseRenderResult({
    required this.pcm,
    required this.envelope,
    required this.plot,
  });

  final Float32List pcm;
  final TimedPitchEnvelope envelope;
  final List<PitchPoint> plot;
}

Float32List _renderPcmIsolate(Map<String, Object> args) {
  final seconds = args['seconds'] as Float64List;
  final cents = args['cents'] as Float64List;
  final amps = args['amps'] as Float64List;
  final totalSeconds = args['totalSeconds'] as double;
  final saHz = args['saHz'] as double;
  final sampleRate = args['sampleRate'] as int;
  final n = seconds.length;
  final points = <TimedPitchPoint>[
    for (var i = 0; i < n; i++)
      TimedPitchPoint(seconds: seconds[i], cents: cents[i], amp: amps[i]),
  ];
  final envelope = TimedPitchEnvelope(points, totalSeconds: totalSeconds);
  return VoiceSynth(sampleRate: sampleRate).render(
    envelope: envelope,
    saHz: saHz,
  );
}

/// Owns SoLoud lifecycle and phrase playback (no drone).
class AudioEngine {
  AudioEngine({this.sampleRate = 48000});

  final int sampleRate;
  final VoiceSynth _voice = VoiceSynth(sampleRate: 48000);

  bool _ready = false;
  bool get isReady => _ready;

  AudioSource? _phraseSource;
  SoundHandle? _phraseHandle;

  /// Bumped on every play/stop so an in-flight render cannot overwrite a newer play.
  int _playEpoch = 0;

  double saHz = 220.0;

  final Map<String, PhraseRenderResult> _cache = {};

  Future<void> init() async {
    if (_ready) return;
    await SoLoud.instance.init(
      sampleRate: sampleRate,
      bufferSize: 1024,
      channels: Channels.stereo,
    );
    SoLoud.instance.setMaxActiveVoiceCount(32);
    _ready = true;
  }

  Future<void> dispose() async {
    await stopPhrase();
    if (_phraseSource != null) {
      await SoLoud.instance.disposeSource(_phraseSource!);
      _phraseSource = null;
    }
    if (_ready) {
      await SoLoud.instance.deinitAsync();
      _ready = false;
    }
  }

  Future<void> setSaHz(double hz) async {
    // Allow textbook Sa=240 and common Carnatic Sa range.
    saHz = hz.clamp(110.0, 480.0);
    _cache.clear();
  }

  String _cacheKey(Phrase phrase, bool withGamakas) =>
      '${phrase.id}|$withGamakas|${saHz.toStringAsFixed(2)}|${phrase.beatsPerMinute}';

  PhraseRenderResult renderPhrase(Phrase phrase, {required bool withGamakas}) {
    final key = _cacheKey(phrase, withGamakas);
    final cached = _cache[key];
    if (cached != null) return cached;

    final envelope = phrase.buildEnvelope(withGamakas: withGamakas);
    final pcm = _voice.render(envelope: envelope, saHz: saHz);
    final result = PhraseRenderResult(
      pcm: pcm,
      envelope: envelope,
      plot: envelope.downsample(count: 240),
    );
    _cache[key] = result;
    return result;
  }

  Future<PhraseRenderResult> renderPhraseAsync(
    Phrase phrase, {
    required bool withGamakas,
  }) async {
    final key = _cacheKey(phrase, withGamakas);
    final cached = _cache[key];
    if (cached != null) return cached;

    final envelope = phrase.buildEnvelope(withGamakas: withGamakas);
    final pts = envelope.points;
    final seconds = Float64List(pts.length);
    final cents = Float64List(pts.length);
    final amps = Float64List(pts.length);
    for (var i = 0; i < pts.length; i++) {
      seconds[i] = pts[i].seconds;
      cents[i] = pts[i].cents;
      amps[i] = pts[i].amp;
    }

    final pcm = await compute(_renderPcmIsolate, <String, Object>{
      'seconds': seconds,
      'cents': cents,
      'amps': amps,
      'totalSeconds': envelope.totalSeconds,
      'saHz': saHz,
      'sampleRate': sampleRate,
    });

    final result = PhraseRenderResult(
      pcm: pcm,
      envelope: envelope,
      plot: envelope.downsample(count: 240),
    );
    _cache[key] = result;
    return result;
  }

  Future<PhraseRenderResult> playPhrase(
    Phrase phrase, {
    required bool withGamakas,
  }) async {
    if (!_ready) await init();
    await stopPhrase();
    final rendered =
        await renderPhraseAsync(phrase, withGamakas: withGamakas);
    await _playPcm(rendered.pcm, label: phrase.id);
    return rendered;
  }

  /// Short tone at [cents] above Sa — note click preview in the editor.
  Future<void> previewCents(double cents, {double seconds = 0.45}) async {
    if (!_ready) await init();
    await stopPhrase();
    final env = TimedPitchEnvelope(
      [
        TimedPitchPoint(seconds: 0, cents: cents, amp: 0),
        TimedPitchPoint(seconds: 0.02, cents: cents, amp: 1.0),
        TimedPitchPoint(seconds: seconds - 0.06, cents: cents, amp: 1.0),
        TimedPitchPoint(seconds: seconds, cents: cents, amp: 0),
      ],
      totalSeconds: seconds,
    );
    // Short clip — render on this isolate for low latency.
    final pcm = _voice.render(envelope: env, saHz: saHz);
    await _playPcm(pcm, label: 'preview');
  }

  /// Play an arbitrary pitch envelope (raga editor curves).
  Future<PhraseRenderResult?> playEnvelope(
    TimedPitchEnvelope envelope, {
    String label = 'curve',
  }) async {
    if (!_ready) await init();
    final epoch = ++_playEpoch;
    await stopPhrase();
    if (epoch != _playEpoch) return null;

    final pts = envelope.points;
    final seconds = Float64List(pts.length);
    final cents = Float64List(pts.length);
    final amps = Float64List(pts.length);
    for (var i = 0; i < pts.length; i++) {
      seconds[i] = pts[i].seconds;
      cents[i] = pts[i].cents;
      amps[i] = pts[i].amp;
    }

    final pcm = await compute(_renderPcmIsolate, <String, Object>{
      'seconds': seconds,
      'cents': cents,
      'amps': amps,
      'totalSeconds': envelope.totalSeconds,
      'saHz': saHz,
      'sampleRate': sampleRate,
    });
    // A newer playMono/playEnvelope/stop invalidated this render.
    if (epoch != _playEpoch) return null;

    final result = PhraseRenderResult(
      pcm: pcm,
      envelope: envelope,
      plot: envelope.downsample(count: 240),
    );
    await _playPcm(pcm, label: label, epoch: epoch);
    if (epoch != _playEpoch) return null;
    return result;
  }

  /// Play mono PCM (e.g. cropped waveform) at [pcmSampleRate].
  Future<void> playMono({
    required Float32List mono,
    required int pcmSampleRate,
    String label = 'wave',
  }) async {
    if (!_ready) await init();
    final epoch = ++_playEpoch;
    await stopPhrase();
    if (epoch != _playEpoch) return;
    final wav = encodeWavMonoInt16(mono: mono, sampleRate: pcmSampleRate);
    await _playWavBytes(wav, label: label, epoch: epoch);
  }

  Future<void> _playPcm(
    Float32List pcm, {
    required String label,
    int? epoch,
  }) async {
    final wav = encodeWavInt16(
      interleavedStereo: pcm,
      sampleRate: sampleRate,
    );
    await _playWavBytes(wav, label: label, epoch: epoch);
  }

  Future<void> _playWavBytes(
    Uint8List wav, {
    required String label,
    int? epoch,
  }) async {
    if (epoch != null && epoch != _playEpoch) return;

    // Kill every voice — a stale handle can leave the synth audible under a
    // new waveform playhead.
    try {
      SoLoud.instance.stopAll();
    } catch (_) {}
    if (_phraseSource != null) {
      try {
        await SoLoud.instance.disposeSource(_phraseSource!);
      } catch (_) {}
      _phraseSource = null;
    }
    _phraseHandle = null;

    if (epoch != null && epoch != _playEpoch) return;

    final stamp = DateTime.now().microsecondsSinceEpoch;
    _phraseSource = await SoLoud.instance.loadMem(
      'phrase_${label}_$stamp.wav',
      wav,
    );
    if (epoch != null && epoch != _playEpoch) {
      try {
        await SoLoud.instance.disposeSource(_phraseSource!);
      } catch (_) {}
      _phraseSource = null;
      return;
    }
    _phraseHandle = SoLoud.instance.play(
      _phraseSource!,
      volume: 1.0,
    );

    if (!SoLoud.instance.getIsValidVoiceHandle(_phraseHandle!)) {
      throw StateError(
        'Phrase voice failed to start (SoLoud returned an invalid handle).',
      );
    }
  }

  Future<void> stopPhrase() async {
    _playEpoch++;
    try {
      SoLoud.instance.stopAll();
    } catch (_) {}
    if (_phraseHandle != null) {
      try {
        if (SoLoud.instance.getIsValidVoiceHandle(_phraseHandle!)) {
          await SoLoud.instance.stop(_phraseHandle!);
        }
      } catch (_) {}
    }
    _phraseHandle = null;
    if (_phraseSource != null) {
      try {
        await SoLoud.instance.disposeSource(_phraseSource!);
      } catch (_) {}
      _phraseSource = null;
    }
  }

  /// Pause active playback (no-op if nothing is playing).
  void pausePhrase() {
    final h = _phraseHandle;
    if (h == null) return;
    if (!SoLoud.instance.getIsValidVoiceHandle(h)) {
      _phraseHandle = null;
      return;
    }
    SoLoud.instance.setPause(h, true);
  }

  /// Resume a paused voice.
  void resumePhrase() {
    final h = _phraseHandle;
    if (h == null) return;
    if (!SoLoud.instance.getIsValidVoiceHandle(h)) {
      _phraseHandle = null;
      return;
    }
    SoLoud.instance.setPause(h, false);
  }

  bool get isPhrasePlaying {
    if (_phraseHandle == null) return false;
    return SoLoud.instance.getIsValidVoiceHandle(_phraseHandle!);
  }

  bool get isPhrasePaused {
    final h = _phraseHandle;
    if (h == null) return false;
    if (!SoLoud.instance.getIsValidVoiceHandle(h)) return false;
    return SoLoud.instance.getPause(h);
  }

  /// Playhead 0–1 for the active voice, or null if nothing is playing.
  double? get playbackProgress {
    final h = _phraseHandle;
    final src = _phraseSource;
    if (h == null || src == null) return null;
    if (!SoLoud.instance.getIsValidVoiceHandle(h)) return null;
    final len = SoLoud.instance.getLength(src);
    if (len.inMicroseconds <= 0) return null;
    final pos = SoLoud.instance.getPosition(h);
    return (pos.inMicroseconds / len.inMicroseconds).clamp(0.0, 1.0);
  }

  /// Seek the active voice to [progress] (0–1). No-op if nothing is loaded.
  void seekPhrase(double progress) {
    final h = _phraseHandle;
    final src = _phraseSource;
    if (h == null || src == null) return;
    if (!SoLoud.instance.getIsValidVoiceHandle(h)) {
      _phraseHandle = null;
      return;
    }
    final len = SoLoud.instance.getLength(src);
    if (len.inMicroseconds <= 0) return;
    final t = progress.clamp(0.0, 1.0);
    final us = (len.inMicroseconds * t).round();
    SoLoud.instance.seek(h, Duration(microseconds: us));
  }
}
