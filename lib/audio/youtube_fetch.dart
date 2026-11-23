import 'dart:convert';
import 'dart:io';

/// True for youtube.com / youtu.be / music.youtube.com links.
bool isYoutubeUrl(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return false;
  return s.contains('youtube.com/') ||
      s.contains('youtu.be/') ||
      s.contains('music.youtube.com/') ||
      RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(s.trim());
}

/// Extract 11-char YouTube video id from watch / youtu.be / shorts / music URLs.
String? youtubeVideoId(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final patterns = <RegExp>[
    RegExp(r'[?&]v=([A-Za-z0-9_-]{11})'),
    RegExp(r'youtu\.be/([A-Za-z0-9_-]{11})'),
    RegExp(r'youtube\.com/shorts/([A-Za-z0-9_-]{11})'),
    RegExp(r'youtube\.com/embed/([A-Za-z0-9_-]{11})'),
    RegExp(r'youtube\.com/live/([A-Za-z0-9_-]{11})'),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(s);
    if (m != null) return m.group(1);
  }
  if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(s)) return s;
  return null;
}

/// Progress for YouTube fetch. [value] null = indeterminate; else 0–1.
typedef YoutubeFetchProgress = void Function(String message, double? value);

/// Our own YouTube audio fetch (no yt-dlp): Innertube → Piped → Invidious.
Future<String> downloadYoutubeAudio(
  String url, {
  YoutubeFetchProgress? onProgress,
}) async {
  void progress(String msg, [double? v]) => onProgress?.call(msg, v);

  if (!isYoutubeUrl(url) && youtubeVideoId(url) == null) {
    throw StateError('Not a YouTube URL.');
  }
  final id = youtubeVideoId(url);
  if (id == null) {
    throw StateError('Could not parse YouTube video id.');
  }

  final errors = <String>[];
  progress('Resolving video $id…', 0.05);

  // 1) Official-ish Innertube player clients (plain URLs, no JS n-sig).
  try {
    progress('Trying YouTube player API…', 0.12);
    final stream = await _innertubeBestAudio(id);
    if (stream != null) {
      progress('Got stream — downloading audio…', 0.35);
      return await _downloadStreamToTemp(
        stream.url,
        stream.ext,
        onProgress: onProgress,
      );
    }
    progress('Player API had no audio — trying Piped…', 0.2);
  } catch (e) {
    errors.add('innertube: $e');
    progress('Player API failed — trying Piped…', 0.2);
  }

  // 2) Piped public API instances (docs.piped.video).
  try {
    progress('Querying Piped mirrors…', 0.25);
    final stream = await _pipedBestAudio(id);
    if (stream != null) {
      progress('Got Piped stream — downloading…', 0.35);
      return await _downloadStreamToTemp(
        stream.url,
        stream.ext,
        onProgress: onProgress,
      );
    }
    progress('Piped had no audio — trying Invidious…', 0.28);
  } catch (e) {
    errors.add('piped: $e');
    progress('Piped failed — trying Invidious…', 0.28);
  }

  // 3) Invidious API (docs.invidious.io /api/v1/videos/:id).
  try {
    progress('Querying Invidious mirrors…', 0.3);
    final stream = await _invidiousBestAudio(id);
    if (stream != null) {
      progress('Got Invidious stream — downloading…', 0.35);
      return await _downloadStreamToTemp(
        stream.url,
        stream.ext,
        onProgress: onProgress,
      );
    }
  } catch (e) {
    errors.add('invidious: $e');
  }

  throw StateError(
    'Could not fetch YouTube audio for $id. '
    'YouTube may be blocking this network (bot check). '
    'Use Import audio with a local file, or retry later.\n'
    '${errors.take(3).join('\n')}',
  );
}

class _AudioStream {
  const _AudioStream({required this.url, required this.ext, this.bitrate = 0});
  final String url;
  final String ext;
  final int bitrate;
}

Future<_AudioStream?> _innertubeBestAudio(String videoId) async {
  final clients = <Map<String, Object>>[
    {
      'clientName': 'ANDROID_MUSIC',
      'clientVersion': '7.27.52',
      'userAgent':
          'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip',
      'key': 'AIzaSyAOghZGza2MQSZkYADUfLsz1Z4hY5O5fXU',
      'extra': {'androidSdkVersion': 34},
    },
    {
      'clientName': 'ANDROID',
      'clientVersion': '19.28.35',
      'userAgent':
          'com.google.android.youtube/19.28.35 (Linux; U; Android 14) gzip',
      'key': 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
      'extra': {'androidSdkVersion': 34},
    },
    {
      'clientName': 'IOS',
      'clientVersion': '19.45.4',
      'userAgent':
          'com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)',
      'key': 'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
      'extra': {
        'deviceMake': 'Apple',
        'deviceModel': 'iPhone16,2',
        'osName': 'iPhone',
        'osVersion': '17.5.1.21F90',
      },
    },
  ];

  for (final c in clients) {
    final client = <String, Object>{
      'clientName': c['clientName']!,
      'clientVersion': c['clientVersion']!,
      'hl': 'en',
      'gl': 'US',
      ...((c['extra'] as Map<String, Object>?) ?? const {}),
    };
    final body = {
      'context': {'client': client},
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
    final uri = Uri.parse(
      'https://www.youtube.com/youtubei/v1/player'
      '?key=${c['key']}&prettyPrint=false',
    );
    final resp = await _httpJson(
      uri,
      method: 'POST',
      body: body,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': c['userAgent'] as String,
        'X-YouTube-Client-Name':
            c['clientName'] == 'IOS' ? '5' : '3',
        'X-YouTube-Client-Version': c['clientVersion'] as String,
      },
    );
    if (resp == null) continue;
    final status =
        (resp['playabilityStatus'] as Map?)?.cast<String, dynamic>();
    final st = status?['status']?.toString();
    if (st != null && st != 'OK') continue;
    final streaming = (resp['streamingData'] as Map?)?.cast<String, dynamic>();
    if (streaming == null) continue;
    final formats = <Map<String, dynamic>>[
      ..._asMapList(streaming['adaptiveFormats']),
      ..._asMapList(streaming['formats']),
    ];
    final audio = <_AudioStream>[];
    for (final f in formats) {
      final mime = f['mimeType']?.toString() ?? '';
      if (!mime.startsWith('audio')) continue;
      final url = f['url']?.toString();
      if (url == null || url.isEmpty) continue; // skip signatureCipher (needs JS)
      final br = int.tryParse('${f['bitrate'] ?? 0}') ?? 0;
      audio.add(_AudioStream(url: url, ext: _extFromMime(mime), bitrate: br));
    }
    if (audio.isEmpty) continue;
    audio.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return audio.first;
  }
  return null;
}

Future<_AudioStream?> _pipedBestAudio(String videoId) async {
  final bases = await _pipedApiBases();
  for (final base in bases) {
    final resp = await _httpJson(
      Uri.parse('$base/streams/$videoId'),
      headers: {'User-Agent': 'Gamaka/1.0'},
    );
    if (resp == null) continue;
    final streams = _asMapList(resp['audioStreams']);
    final audio = <_AudioStream>[];
    for (final s in streams) {
      final url = s['url']?.toString();
      if (url == null || url.isEmpty) continue;
      final mime = s['mimeType']?.toString() ?? '';
      final br = int.tryParse('${s['bitrate'] ?? 0}') ?? 0;
      final fmt = s['format']?.toString().toLowerCase() ?? '';
      final ext = fmt.contains('m4a') || mime.contains('mp4')
          ? 'm4a'
          : (mime.contains('webm') ? 'webm' : _extFromMime(mime));
      audio.add(_AudioStream(url: url, ext: ext, bitrate: br));
    }
    if (audio.isEmpty) continue;
    audio.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return audio.first;
  }
  return null;
}

Future<_AudioStream?> _invidiousBestAudio(String videoId) async {
  const bases = [
    'https://inv.nadeko.net',
    'https://invidious.nerdvpn.de',
    'https://yewtu.be',
    'https://invidious.privacyredirect.com',
    'https://iv.ggtyler.dev',
  ];
  for (final base in bases) {
    final resp = await _httpJson(
      Uri.parse('$base/api/v1/videos/$videoId'),
      headers: {'User-Agent': 'Gamaka/1.0'},
    );
    if (resp == null) continue;
    final formats = _asMapList(resp['adaptiveFormats']);
    final audio = <_AudioStream>[];
    for (final f in formats) {
      final type = f['type']?.toString() ?? '';
      if (!type.startsWith('audio')) continue;
      final url = f['url']?.toString();
      if (url == null || url.isEmpty) continue;
      final br = int.tryParse('${f['bitrate'] ?? 0}') ?? 0;
      audio.add(_AudioStream(url: url, ext: _extFromMime(type), bitrate: br));
    }
    if (audio.isEmpty) continue;
    audio.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return audio.first;
  }
  return null;
}

Future<List<String>> _pipedApiBases() async {
  const fallback = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://pipedapi.reallyaweso.me',
    'https://api.piped.private.coffee',
    'https://pipedapi.ducks.party',
  ];
  try {
    final resp = await _httpJson(
      Uri.parse(
        'https://raw.githubusercontent.com/TeamPiped/piped-uptime/master/history/summary.json',
      ),
      headers: {'User-Agent': 'Gamaka/1.0'},
    );
    if (resp is! List) return fallback;
    final up = <String>[];
    for (final raw in resp) {
      if (raw is! Map) continue;
      if (raw['status']?.toString() != 'up') continue;
      final u = raw['url']?.toString() ?? '';
      if (!u.contains('/healthcheck')) continue;
      up.add(u.replaceAll('/healthcheck', ''));
    }
    return up.isEmpty ? fallback : [...up, ...fallback];
  } catch (_) {
    return fallback;
  }
}

Future<String> _downloadStreamToTemp(
  String url,
  String ext, {
  YoutubeFetchProgress? onProgress,
}) async {
  final dir = await Directory.systemTemp.createTemp('carnatic_yt_');
  final path = '${dir.path}/audio.${ext.isEmpty ? 'm4a' : ext}';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 Gamaka/1.0');
    final res = await req.close().timeout(const Duration(seconds: 120));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Audio download HTTP ${res.statusCode}');
    }
    final total = res.contentLength; // -1 if unknown
    final sink = File(path).openWrite();
    var received = 0;
    var lastPct = -1;
    await for (final chunk in res) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) {
        final pct = ((received / total) * 100).floor();
        if (pct != lastPct && (pct % 2 == 0 || pct == 100)) {
          lastPct = pct;
          final frac = 0.35 + 0.60 * (received / total).clamp(0.0, 1.0);
          final mb = received / (1024 * 1024);
          final tmb = total / (1024 * 1024);
          onProgress?.call(
            'Downloading audio… $pct% (${mb.toStringAsFixed(1)} / ${tmb.toStringAsFixed(1)} MB)',
            frac,
          );
        }
      } else if (received % (256 * 1024) < chunk.length) {
        final mb = received / (1024 * 1024);
        onProgress?.call(
          'Downloading audio… ${mb.toStringAsFixed(1)} MB',
          null,
        );
      }
    }
    await sink.close();
    onProgress?.call('Download complete — decoding waveform…', 0.97);
  } finally {
    client.close(force: true);
  }
  final f = File(path);
  if (!f.existsSync() || f.lengthSync() < 256) {
    throw StateError('Downloaded audio is empty.');
  }
  return path;
}

Future<dynamic> _httpJson(
  Uri uri, {
  String method = 'GET',
  Map<String, Object?>? body,
  Map<String, String>? headers,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final req = await (method == 'POST'
        ? client.postUrl(uri)
        : client.getUrl(uri));
    headers?.forEach(req.headers.set);
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return null;
    }
    if (text.isEmpty) return null;
    return jsonDecode(text);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

List<Map<String, dynamic>> _asMapList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}

String _extFromMime(String mime) {
  final m = mime.toLowerCase();
  if (m.contains('mp4') || m.contains('m4a') || m.contains('aac')) return 'm4a';
  if (m.contains('webm') || m.contains('opus')) return 'webm';
  if (m.contains('mp3') || m.contains('mpeg')) return 'mp3';
  return 'm4a';
}
