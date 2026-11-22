import 'dart:io';

import '../music/editable_raga.dart';

/// Persists named ragas as JSON under ~/.local/share/gamaka/ragas (POSIX)
/// or %USERPROFILE%/AppData/Local/gamaka/ragas (Windows).
class RagaStore {
  RagaStore({Directory? directory}) : _override = directory;

  final Directory? _override;

  Future<Directory> root() async {
    final override = _override;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    final dir = Directory(
      Platform.isWindows
          ? '$home${Platform.pathSeparator}AppData${Platform.pathSeparator}Local${Platform.pathSeparator}gamaka${Platform.pathSeparator}ragas'
          : '$home/.local/share/gamaka/ragas',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<EditableRaga>> list() async {
    final dir = await root();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    final out = <EditableRaga>[];
    for (final f in files) {
      try {
        out.add(EditableRaga.decode(await f.readAsString()));
      } catch (_) {
        // Skip corrupt files.
      }
    }
    return out;
  }

  Future<File> _fileFor(EditableRaga raga) async {
    final dir = await root();
    final safe = raga.id.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}$safe.json');
  }

  Future<void> save(EditableRaga raga) async {
    final file = await _fileFor(raga);
    await file.writeAsString(raga.encode());
  }

  Future<void> delete(EditableRaga raga) async {
    final file = await _fileFor(raga);
    if (await file.exists()) await file.delete();
  }
}
