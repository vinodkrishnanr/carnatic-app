import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// OS file drop (Linux GTK) + file-picker fallback for WAV/MP3 import.
class AudioFileImport {
  AudioFileImport._();
  static final instance = AudioFileImport._();

  static const _channel = MethodChannel('carnatic_app/file_drop');
  final _controller = StreamController<String>.broadcast();

  Stream<String> get paths => _controller.stream;
  bool _listening = false;

  void ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pathsDropped') {
        final list = (call.arguments as List?)?.cast<Object?>() ?? const [];
        for (final raw in list) {
          final p = raw?.toString() ?? '';
          if (_isAudioPath(p)) _controller.add(p);
        }
      }
      return null;
    });
  }

  /// Native text entry for a YouTube URL (avoids Flutter Linux CapsLock
  /// embedder assertion when typing in a TextField).
  Future<String?> pickYoutubeUrl() async {
    var initial = '';
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final t = clip?.text?.trim() ?? '';
      if (t.contains('youtu')) initial = t;
    } catch (_) {}

    if (Platform.isLinux) {
      final zenity = await Process.run('which', ['zenity']);
      if (zenity.exitCode == 0) {
        final args = <String>[
          '--entry',
          '--title=YouTube URL',
          '--text=Paste a YouTube link',
          '--width=520',
        ];
        if (initial.isNotEmpty) {
          args.addAll(['--entry-text', initial]);
        }
        final r = await Process.run('zenity', args);
        if (r.exitCode == 0) {
          final v = (r.stdout as String).trim();
          return v.isEmpty ? null : v;
        }
        return null;
      }
      final kdialog = await Process.run('which', ['kdialog']);
      if (kdialog.exitCode == 0) {
        final r = await Process.run('kdialog', [
          '--inputbox',
          'Paste a YouTube link',
          initial,
          '--title',
          'YouTube URL',
        ]);
        if (r.exitCode == 0) {
          final v = (r.stdout as String).trim();
          return v.isEmpty ? null : v;
        }
        return null;
      }
    }
    return null;
  }

  /// Zenity / kdialog file chooser when drop isn’t used.
  Future<String?> pickAudioFile() async {
    if (Platform.isLinux) {
      final zenity = await Process.run('which', ['zenity']);
      if (zenity.exitCode == 0) {
        final r = await Process.run('zenity', [
          '--file-selection',
          '--title=Import voice audio',
          '--file-filter=Audio | *.wav *.mp3 *.flac *.ogg *.m4a',
        ]);
        if (r.exitCode == 0) {
          final p = (r.stdout as String).trim();
          if (_isAudioPath(p)) return p;
        }
        return null;
      }
      final kdialog = await Process.run('which', ['kdialog']);
      if (kdialog.exitCode == 0) {
        final r = await Process.run('kdialog', [
          '--getopenfilename',
          '.',
          'Audio (*.wav *.mp3 *.flac *.ogg *.m4a)',
        ]);
        if (r.exitCode == 0) {
          final p = (r.stdout as String).trim();
          if (_isAudioPath(p)) return p;
        }
      }
    }
    return null;
  }

  /// Save-as dialog. Returns path or null. [defaultName] e.g. `raga.wav`.
  Future<String?> pickSavePath({
    required String title,
    required String defaultName,
    String filter = 'All | *',
  }) async {
    if (Platform.isLinux) {
      final zenity = await Process.run('which', ['zenity']);
      if (zenity.exitCode == 0) {
        final r = await Process.run('zenity', [
          '--file-selection',
          '--save',
          '--confirm-overwrite',
          '--title=$title',
          '--filename=$defaultName',
          '--file-filter=$filter',
        ]);
        if (r.exitCode == 0) {
          final p = (r.stdout as String).trim();
          return p.isEmpty ? null : p;
        }
        return null;
      }
      final kdialog = await Process.run('which', ['kdialog']);
      if (kdialog.exitCode == 0) {
        final r = await Process.run('kdialog', [
          '--getsavefilename',
          defaultName,
          filter,
          '--title',
          title,
        ]);
        if (r.exitCode == 0) {
          final p = (r.stdout as String).trim();
          return p.isEmpty ? null : p;
        }
      }
    }
    // Fallback: write under Downloads / home.
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return '$home${Platform.pathSeparator}$defaultName';
  }

  bool _isAudioPath(String p) {
    if (p.isEmpty) return false;
    final lower = p.toLowerCase();
    return lower.endsWith('.wav') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.m4a');
  }

  void dispose() {
    _controller.close();
  }
}
