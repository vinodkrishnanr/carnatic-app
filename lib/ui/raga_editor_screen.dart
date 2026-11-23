import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/audio_decode.dart';
import '../audio/audio_engine.dart';
import '../audio/voice_pitch_track.dart';
import '../audio/wav_encoder.dart';
import '../audio/youtube_fetch.dart';
import '../music/editable_raga.dart';
import '../music/swara.dart';
import '../platform/audio_file_import.dart';
import '../storage/raga_store.dart';
import '../theme/app_theme.dart';
import 'raga_grid_painter.dart';
import 'waveform_painter.dart';

enum _EditTool { select, eraser }

class RagaEditorScreen extends StatefulWidget {
  const RagaEditorScreen({super.key, this.initial});

  final EditableRaga? initial;

  @override
  State<RagaEditorScreen> createState() => _RagaEditorScreenState();
}

class _RagaEditorScreenState extends State<RagaEditorScreen> {
  final _store = RagaStore();
  final _engine = AudioEngine();
  final _nameCtrl = TextEditingController();

  late EditableRaga _raga;
  List<EditableRaga> _saved = [];
  _EditTool _tool = _EditTool.select;
  int? _dragIndex;
  /// Destination point index when left-dragging an edge curve handle.
  int? _dragEdgeDest;
  bool _panning = false;
  Offset? _panLast;
  final _viewport = GridViewport();
  final List<String> _undoStack = [];
  static const _maxUndo = 40;
  DateTime? _lastLineTapAt;
  Offset? _lastLineTapPos;
  /// After double-click add on the gold line, drag creates edge bends.
  bool _autoBendOnDrag = false;
  bool _busy = false;
  bool _playing = false;
  bool _paused = false;
  /// Which source is active: grid phrase vs waveform strip.
  bool _wavePlayback = false;
  /// 0–1 playhead progress while audio is active.
  double _playhead = 0;
  Timer? _playheadTimer;
  bool _ready = false;
  String? _status;
  /// null = hide; otherwise 0–1 determinate or use [_fetchIndeterminate].
  double? _fetchProgress;
  bool _fetchIndeterminate = false;
  Float32List _waveform = Float32List(0);
  DecodedAudio? _loadedAudio;
  double _cropStart = 0;
  double _cropEnd = 1;
  /// Which crop handle is dragged: -1 none, 0 start, 1 end, 2 move range.
  int _cropDrag = -1;
  bool _cropToolActive = true;
  double? _detectedBpm;
  StreamSubscription<String>? _dropSub;
  bool _dropHighlight = false;

  static const _palette = <Swara>[
    Swara.sa,
    Swara.ri1,
    Swara.ri2,
    Swara.ga2,
    Swara.ga3,
    Swara.ma1,
    Swara.ma2,
    Swara.pa,
    Swara.da1,
    Swara.da2,
    Swara.ni2,
    Swara.ni3,
    Swara.saHigh,
  ];

  @override
  void initState() {
    super.initState();
    _raga = widget.initial != null
        ? EditableRaga.decode(widget.initial!.encode())
        : EditableRaga.shankarabharanamTemplate();
    _nameCtrl.text = _raga.name;
    _detectedBpm = _raga.beatsPerMinute;
    _viewport.cents0 = _raga.minCents;
    _viewport.clampTo(_raga);
    AudioFileImport.instance.ensureListening();
    _dropSub = AudioFileImport.instance.paths.listen(_importAudioPath);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _engine.init();
      await _engine.setSaHz(240);
      _saved = await _store.list();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _status = 'Audio init failed: $e');
    }
  }

  @override
  void dispose() {
    _playheadTimer?.cancel();
    _dropSub?.cancel();
    _nameCtrl.dispose();
    _engine.dispose();
    super.dispose();
  }

  void _startPlayheadTicker() {
    _playheadTimer?.cancel();
    _playheadTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted) return;
      final p = _engine.playbackProgress;
      if (p == null) {
        if (_playing && !_paused) {
          setState(() {
            _playing = false;
            _paused = false;
            _wavePlayback = false;
            _playhead = 0;
          });
          _playheadTimer?.cancel();
          _playheadTimer = null;
        }
        return;
      }
      if (p != _playhead) {
        setState(() => _playhead = p);
      }
    });
  }

  void _stopPlayheadTicker({bool reset = true}) {
    _playheadTimer?.cancel();
    _playheadTimer = null;
    if (reset) _playhead = 0;
  }

  Future<void> _pickAndImport() async {
    final path = await AudioFileImport.instance.pickAudioFile();
    if (path != null) await _importAudioPath(path);
  }

  Future<void> _promptYoutubeUrl() async {
    if (_busy) return;
    // Prefer OS entry dialog — Flutter Linux CapsLock sync can CRITICAL-assert
    // in FlKeyEmbedderResponder when typing in a TextField.
    var url = await AudioFileImport.instance.pickYoutubeUrl();
    if (url == null && mounted) {
      url = await showDialog<String>(
        context: context,
        builder: (ctx) => const _YoutubeUrlDialog(),
      );
    }
    if (url == null || url.isEmpty) return;
    await _importYoutubeUrl(url);
  }

  Future<void> _importYoutubeUrl(String url) async {
    if (_busy) return;
    if (!isYoutubeUrl(url)) {
      setState(() => _status = 'Paste a valid YouTube URL.');
      return;
    }
    setState(() {
      _busy = true;
      _fetchProgress = 0;
      _fetchIndeterminate = false;
      _status = 'Starting YouTube fetch…';
    });
    try {
      final path = await downloadYoutubeAudio(
        url,
        onProgress: (msg, value) {
          if (!mounted) return;
          setState(() {
            _status = msg;
            if (value == null) {
              _fetchIndeterminate = true;
              _fetchProgress = null;
            } else {
              _fetchIndeterminate = false;
              _fetchProgress = value.clamp(0.0, 1.0);
            }
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _status = 'Building waveform…';
        _fetchProgress = 0.98;
        _fetchIndeterminate = false;
      });
      await _loadWaveformFromPath(path, label: 'YouTube');
      if (mounted) {
        setState(() {
          _fetchProgress = 1.0;
          _fetchIndeterminate = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'YouTube import failed: $e';
          _fetchProgress = null;
          _fetchIndeterminate = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _fetchProgress = null;
          _fetchIndeterminate = false;
        });
      }
    }
  }

  Future<void> _importAudioPath(String path) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _dropHighlight = false;
      _status = 'Loading waveform…';
    });
    try {
      await _loadWaveformFromPath(path, label: 'file');
    } catch (e) {
      if (mounted) setState(() => _status = 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadWaveformFromPath(String path, {required String label}) async {
    final decoded = await decodeAudioFile(path);
    if (!mounted) return;
    setState(() {
      _loadedAudio = decoded;
      _waveform = waveformPeaks(decoded.samples, buckets: 480);
      _cropStart = 0;
      _cropEnd = 1;
      _cropToolActive = true;
      _detectedBpm = null;
      _status =
          'Crop the waveform (${decoded.durationSeconds.toStringAsFixed(1)}s), then Sync';
    });
  }

  DecodedAudio _croppedAudio() {
    final a = _loadedAudio!;
    final n = a.samples.length;
    var i0 = (_cropStart * n).floor().clamp(0, n - 1);
    var i1 = (_cropEnd * n).ceil().clamp(i0 + 1, n);
    if (i1 - i0 < a.sampleRate ~/ 10) {
      // At least ~0.1s.
      i1 = math.min(n, i0 + a.sampleRate ~/ 10);
    }
    final slice = Float32List.fromList(a.samples.sublist(i0, i1));
    return DecodedAudio(
      samples: slice,
      sampleRate: a.sampleRate,
      durationSeconds: slice.length / a.sampleRate,
    );
  }

  Future<void> _syncFromWaveform() async {
    if (_busy || _loadedAudio == null) return;
    setState(() {
      _busy = true;
      _status = 'Syncing voice → grid…';
    });
    try {
      final cropped = _croppedAudio();
      // Refresh waveform to the cropped region.
      final wave = waveformPeaks(cropped.samples, buckets: 480);
      final map = await compute(_importIsolate, <String, Object>{
        'samples': cropped.samples,
        'sampleRate': cropped.sampleRate,
        'durationSeconds': cropped.durationSeconds,
        'saHz': _engine.saHz,
      });
      if (!mounted) return;
      final pointsJson = (map['points'] as List).cast<Map<dynamic, dynamic>>();
      final points = [
        for (final j in pointsJson)
          CurvePoint.fromJson(Map<String, dynamic>.from(j)),
      ];
      final bpm = (map['bpm'] as num).toDouble();
      final totalBeats = (map['totalBeats'] as num).toDouble();
      final saHz = (map['saHz'] as num).toDouble();
      _checkpoint();
      setState(() {
        _loadedAudio = cropped;
        _waveform = wave;
        _cropStart = 0;
        _cropEnd = 1;
        _raga.points
          ..clear()
          ..addAll(points);
        _raga.beatsPerMinute = bpm;
        _raga.totalBeats = totalBeats;
        _raga.gridLock = false;
        _detectedBpm = bpm;
        _viewport.zoom = 1.0;
        _viewport.beat0 = 0;
        _viewport.cents0 = _raga.minCents;
        _viewport.clampTo(_raga);
        _status =
            'Synced → ${points.length} points · ${bpm.toStringAsFixed(1)} BPM';
      });
      await _engine.setSaHz(saHz);
    } catch (e) {
      if (mounted) setState(() => _status = 'Sync failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onWavePointerDown(PointerDownEvent e, Size size) {
    if (_loadedAudio == null || !_cropToolActive || size.width <= 0) return;
    final t = (e.localPosition.dx / size.width).clamp(0.0, 1.0);
    final x0 = _cropStart * size.width;
    final x1 = _cropEnd * size.width;
    const hit = 14.0;
    if ((e.localPosition.dx - x0).abs() <= hit) {
      _cropDrag = 0;
    } else if ((e.localPosition.dx - x1).abs() <= hit) {
      _cropDrag = 1;
    } else if (e.localPosition.dx >= x0 && e.localPosition.dx <= x1) {
      _cropDrag = 2;
      _cropDragAnchor = t;
      _cropDragStart0 = _cropStart;
      _cropDragStart1 = _cropEnd;
    } else {
      // Click outside → start a new selection from this point.
      setState(() {
        _cropStart = t;
        _cropEnd = t;
        _cropDrag = 1;
      });
    }
  }

  double _cropDragAnchor = 0;
  double _cropDragStart0 = 0;
  double _cropDragStart1 = 1;

  void _onWavePointerMove(PointerMoveEvent e, Size size) {
    if (_cropDrag < 0 || size.width <= 0) return;
    final t = (e.localPosition.dx / size.width).clamp(0.0, 1.0);
    setState(() {
      if (_cropDrag == 0) {
        _cropStart = t.clamp(0.0, _cropEnd - 0.01);
      } else if (_cropDrag == 1) {
        _cropEnd = t.clamp(_cropStart + 0.01, 1.0);
      } else if (_cropDrag == 2) {
        final span = _cropDragStart1 - _cropDragStart0;
        var s = _cropDragStart0 + (t - _cropDragAnchor);
        s = s.clamp(0.0, 1.0 - span);
        _cropStart = s;
        _cropEnd = s + span;
      }
    });
  }

  void _onWavePointerUp(PointerUpEvent e) => _cropDrag = -1;

  List<(double, String)> get _lanes => [
        for (final s in _raga.scale) (s.cents, s.label),
      ];

  GridMapper _mapper(Size size) =>
      GridMapper(size: size, raga: _raga, viewport: _viewport);

  void _checkpoint() {
    _undoStack.add(_raga.encode());
    if (_undoStack.length > _maxUndo) {
      _undoStack.removeAt(0);
    }
  }

  void _undoLast() {
    if (_undoStack.isEmpty) {
      setState(() => _status = 'Nothing to undo');
      return;
    }
    final prev = _undoStack.removeLast();
    setState(() {
      _raga = EditableRaga.decode(prev);
      _nameCtrl.text = _raga.name;
      _dragIndex = null;
      _dragEdgeDest = null;
      _panning = false;
      _panLast = null;
      _status = 'Undid last change';
    });
  }

  void _onScroll(PointerScrollEvent e, Size size) {
    if (e.scrollDelta.dy == 0) return;
    // Scroll up → zoom in; scroll down → zoom out. Anchor under cursor.
    final factor = e.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12;
    setState(() {
      _viewport.zoomAt(
        raga: _raga,
        size: size,
        local: e.localPosition,
        factor: factor,
      );
    });
  }

  void _onPointerDown(PointerDownEvent e, Size size) {
    final map = _mapper(size);
    final beat = map.beatAt(e.localPosition);
    final cents = map.centsAt(e.localPosition);
    final secondary = (e.buttons & kSecondaryMouseButton) != 0;
    final primary = (e.buttons & kPrimaryMouseButton) != 0;
    final hitPoint = map.nearestPointIndex(e.localPosition);
    final hitHandle =
        hitPoint == null ? map.nearestHandleDestIndex(e.localPosition) : null;
    final hitLine = hitPoint == null && hitHandle == null
        ? map.nearestLineDestIndex(e.localPosition)
        : null;

    if (secondary) {
      // Right-click empty grid (not on point/handle/line) → undo.
      _dragIndex = null;
      _dragEdgeDest = null;
      _panning = false;
      _panLast = null;
      _autoBendOnDrag = false;
      if (hitPoint == null && hitHandle == null && hitLine == null) {
        _undoLast();
      }
      return;
    }

    if (!primary) return;

    if (_tool == _EditTool.eraser) {
      _checkpoint();
      setState(() {
        _raga.eraseNear(beat, cents);
        _dragIndex = null;
        _dragEdgeDest = null;
        _panning = false;
        _panLast = null;
        _autoBendOnDrag = false;
      });
      return;
    }

    // Left: point → blue handle (bend) → gold line (double-click adds) → pan.
    if (hitPoint != null) {
      _lastLineTapAt = null;
      _lastLineTapPos = null;
      _autoBendOnDrag = false;
      _checkpoint();
      final noteCents = _raga.points[hitPoint].cents;
      // Preview pitch on click; drag still moves the point.
      if (_ready) {
        unawaited(_engine.previewCents(noteCents));
      }
      setState(() {
        _dragIndex = hitPoint;
        _dragEdgeDest = null;
        _panning = false;
        _panLast = null;
        _status = null;
      });
      return;
    }

    if (hitHandle != null) {
      _lastLineTapAt = null;
      _lastLineTapPos = null;
      _autoBendOnDrag = false;
      _checkpoint();
      setState(() {
        _dragIndex = null;
        _dragEdgeDest = hitHandle;
        _panning = false;
        _panLast = null;
        _raga.setEdgeBend(hitHandle, beat, cents);
        _status = null;
      });
      return;
    }

    if (hitLine != null) {
      final now = DateTime.now();
      final isDouble = _lastLineTapAt != null &&
          _lastLineTapPos != null &&
          now.difference(_lastLineTapAt!) <
              const Duration(milliseconds: 350) &&
          (e.localPosition - _lastLineTapPos!).distance < 14;
      if (isDouble) {
        _lastLineTapAt = null;
        _lastLineTapPos = null;
        _checkpoint();
        final idx =
            _raga.addPoint(CurvePoint(beat: beat, cents: cents));
        setState(() {
          _dragIndex = idx >= 0 ? idx : null;
          _dragEdgeDest = null;
          _panning = false;
          _panLast = null;
          _autoBendOnDrag = idx >= 0;
          _status = null;
        });
        return;
      }
      _lastLineTapAt = now;
      _lastLineTapPos = e.localPosition;
      return;
    }

    _lastLineTapAt = null;
    _lastLineTapPos = null;
    _autoBendOnDrag = false;
    setState(() {
      _dragIndex = null;
      _dragEdgeDest = null;
      _panning = true;
      _panLast = e.localPosition;
      _status = null;
    });
  }

  void _onPointerMove(PointerMoveEvent e, Size size) {
    if (_tool == _EditTool.eraser &&
        (e.buttons & kPrimaryMouseButton) != 0) {
      final map = _mapper(size);
      setState(() {
        _raga.eraseNear(map.beatAt(e.localPosition), map.centsAt(e.localPosition));
      });
      return;
    }

    if ((e.buttons & kPrimaryMouseButton) == 0) return;

    if (_panning && _panLast != null) {
      final delta = e.localPosition - _panLast!;
      setState(() {
        _viewport.panBy(raga: _raga, size: size, pixelDelta: delta);
        _panLast = e.localPosition;
      });
      return;
    }

    final map = _mapper(size);
    final edgeDest = _dragEdgeDest;
    if (edgeDest != null) {
      setState(() {
        _raga.setEdgeBend(
          edgeDest,
          map.beatAt(e.localPosition),
          map.centsAt(e.localPosition),
        );
      });
      return;
    }

    final idx = _dragIndex;
    if (idx == null) return;

    setState(() {
      _raga.movePoint(
        idx,
        CurvePoint(
          beat: map.beatAt(e.localPosition),
          cents: map.centsAt(e.localPosition),
        ),
      );
      if (_autoBendOnDrag) {
        _raga.autoBendAroundPoint(idx);
      }
    });
  }

  void _clearDrag() {
    if (_dragIndex != null || _dragEdgeDest != null || _panning) {
      setState(() {
        if (_dragIndex != null || _dragEdgeDest != null) {
          _raga.sortPoints();
        }
        _dragIndex = null;
        _dragEdgeDest = null;
        _panning = false;
        _panLast = null;
        _autoBendOnDrag = false;
      });
    }
  }

  void _onPointerUp(PointerUpEvent e) => _clearDrag();

  Future<void> _saveGridToStore() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      throw StateError('Give the raga a name before saving the grid.');
    }
    _raga.name = name;
    if (_raga.id.startsWith('template_')) {
      _raga = _raga.cloneWithNewId(name);
      _nameCtrl.text = name;
    }
    await _store.save(_raga);
    _saved = await _store.list();
  }

  Future<void> _saveWaveformToDisk(String path) async {
    if (_loadedAudio == null) {
      throw StateError('No waveform loaded.');
    }
    final cropped = _croppedAudio();
    final wav = encodeWavMonoInt16(
      mono: cropped.samples,
      sampleRate: cropped.sampleRate,
    );
    var out = path;
    if (!out.toLowerCase().endsWith('.wav')) out = '$out.wav';
    await File(out).writeAsBytes(wav, flush: true);
  }

  Future<void> _promptSaveDialog() async {
    if (_busy) return;
    final hasWave = _loadedAudio != null;
    final hasGrid = _raga.points.isNotEmpty;
    if (!hasWave && !hasGrid) {
      setState(() => _status = 'Nothing to save yet.');
      return;
    }
    final choice = await showDialog<_SaveChoice>(
      context: context,
      builder: (ctx) => _SaveDialog(
        canSaveWaveform: hasWave,
        canSaveGrid: hasGrid,
      ),
    );
    if (choice == null || (!choice.waveform && !choice.grid)) return;

    setState(() => _busy = true);
    try {
      final parts = <String>[];
      if (choice.grid) {
        await _saveGridToStore();
        // Also export JSON to disc when user asked for grid.
        final safe = (_nameCtrl.text.trim().isEmpty
                ? 'raga'
                : _nameCtrl.text.trim())
            .replaceAll(RegExp(r'[^\w\-]+'), '_');
        final jsonPath = await AudioFileImport.instance.pickSavePath(
          title: 'Save grid JSON',
          defaultName: '$safe.json',
          filter: 'JSON | *.json',
        );
        if (jsonPath != null) {
          var p = jsonPath;
          if (!p.toLowerCase().endsWith('.json')) p = '$p.json';
          await File(p).writeAsString(_raga.encode(), flush: true);
          parts.add('grid → $p');
        } else {
          parts.add('grid → library');
        }
      }
      if (choice.waveform) {
        final safe = (_nameCtrl.text.trim().isEmpty
                ? 'waveform'
                : _nameCtrl.text.trim())
            .replaceAll(RegExp(r'[^\w\-]+'), '_');
        final wavPath = await AudioFileImport.instance.pickSavePath(
          title: 'Save waveform WAV',
          defaultName: '$safe.wav',
          filter: 'WAV | *.wav',
        );
        if (wavPath != null) {
          await _saveWaveformToDisk(wavPath);
          parts.add('waveform → $wavPath');
        }
      }
      if (!mounted) return;
      setState(() {
        _status = parts.isEmpty
            ? 'Save cancelled.'
            : 'Saved ${parts.join(' · ')}';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _syncPlayStateFromEngine() {
    final live = _engine.isPhrasePlaying;
    if (!live) {
      _playing = false;
      _paused = false;
      _wavePlayback = false;
      return;
    }
    _playing = true;
    _paused = _engine.isPhrasePaused;
  }

  Future<void> _playGrid() async {
    if (!_ready || _busy) return;
    _syncPlayStateFromEngine();
    if (_playing && !_wavePlayback) {
      if (_paused) {
        _engine.resumePhrase();
        _startPlayheadTicker();
        setState(() {
          _paused = false;
          _status = null;
        });
      } else {
        _engine.pausePhrase();
        setState(() {
          _paused = true;
          _status = 'Paused';
        });
      }
      return;
    }
    if (_raga.points.isEmpty) {
      setState(() => _status = 'Add points first (double-click the gold line).');
      return;
    }
    setState(() => _busy = true);
    try {
      await _engine.playEnvelope(
        _raga.toEnvelope(),
        label: _raga.id,
      );
      if (!mounted) return;
      setState(() {
        _playing = true;
        _paused = false;
        _wavePlayback = false;
        _playhead = 0;
        _status = null;
      });
      _startPlayheadTicker();
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playWaveform() async {
    if (!_ready || _busy || _loadedAudio == null) return;
    _syncPlayStateFromEngine();
    if (_playing && _wavePlayback) {
      if (_paused) {
        _engine.resumePhrase();
        _startPlayheadTicker();
        setState(() {
          _paused = false;
          _status = null;
        });
      } else {
        _engine.pausePhrase();
        setState(() {
          _paused = true;
          _status = 'Waveform paused';
        });
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final cropped = _croppedAudio();
      await _engine.playMono(
        mono: cropped.samples,
        pcmSampleRate: cropped.sampleRate,
        label: 'waveform',
      );
      if (!mounted) return;
      setState(() {
        _playing = true;
        _paused = false;
        _wavePlayback = true;
        _playhead = 0;
        _status = null;
      });
      _startPlayheadTicker();
    } catch (e) {
      if (mounted) setState(() => _status = 'Wave play failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    await _engine.stopPhrase();
    _stopPlayheadTicker();
    if (mounted) {
      setState(() {
        _playing = false;
        _paused = false;
        _wavePlayback = false;
        _playhead = 0;
        _busy = false;
      });
    }
  }

  Future<void> _load(EditableRaga r) async {
    setState(() {
      _raga = EditableRaga.decode(r.encode());
      _nameCtrl.text = _raga.name;
      _detectedBpm = _raga.beatsPerMinute;
      _viewport.zoom = 1.0;
      _viewport.beat0 = 0;
      _viewport.cents0 = _raga.minCents;
      _viewport.clampTo(_raga);
      _status = 'Loaded “${_raga.name}”.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A3A3C), AppColors.teakDeep],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back, color: AppColors.sand),
                    ),
                    Expanded(
                      child: Text('Raga editor',
                          style: theme.textTheme.headlineMedium),
                    ),
                    if (_detectedBpm != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '${_detectedBpm!.toStringAsFixed(_detectedBpm! == _detectedBpm!.roundToDouble() ? 0 : 1)} BPM',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: AppColors.gold,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    _WaveIconBtn(
                      icon: _playing && !_wavePlayback && !_paused
                          ? Icons.pause
                          : Icons.play_arrow,
                      tooltip: _playing && !_wavePlayback && !_paused
                          ? 'Pause grid'
                          : 'Play grid',
                      selected: _playing && !_wavePlayback,
                      onTap: _ready && !_busy ? _playGrid : null,
                    ),
                    _WaveIconBtn(
                      icon: Icons.stop,
                      tooltip: 'Stop',
                      selected: _playing,
                      onTap: _playing || _paused ? _stop : null,
                    ),
                    _WaveIconBtn(
                      icon: Icons.save,
                      tooltip: 'Save waveform / grid',
                      selected: true,
                      onTap: _busy ? null : _promptSaveDialog,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Drop audio → crop waveform → Sync · click note · zoom · pan · bend handles · right-click empty undo',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _nameCtrl,
                  style: theme.textTheme.titleLarge,
                  decoration: InputDecoration(
                    labelText: 'Raga name',
                    labelStyle: theme.textTheme.labelLarge,
                    enabledBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: AppColors.mist),
                    ),
                    focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: AppColors.gold),
                    ),
                  ),
                  onChanged: (v) => _raga.name = v,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _dropHighlight
                                ? AppColors.gold
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerSignal: (e) {
                            if (e is PointerScrollEvent) _onScroll(e, size);
                          },
                          onPointerDown: (e) => _onPointerDown(e, size),
                          onPointerMove: (e) => _onPointerMove(e, size),
                          onPointerUp: _onPointerUp,
                          onPointerCancel: (_) => _clearDrag(),
                          child: CustomPaint(
                            size: size,
                            painter: RagaGridPainter(
                              raga: _raga,
                              laneLabels: _lanes,
                              viewport: _viewport,
                              activeEdgeDest: _dragEdgeDest,
                              playheadBeat: _playing && !_wavePlayback
                                  ? _playhead * _raga.totalBeats
                                  : null,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _WaveIconBtn(
                          icon: _playing && _wavePlayback && !_paused
                              ? Icons.pause
                              : Icons.play_arrow,
                          tooltip: _playing && _wavePlayback && !_paused
                              ? 'Pause waveform'
                              : 'Play waveform',
                          selected: _playing && _wavePlayback,
                          onTap: _loadedAudio != null && _ready && !_busy
                              ? _playWaveform
                              : null,
                        ),
                        _WaveIconBtn(
                          icon: Icons.stop,
                          tooltip: 'Stop',
                          selected: _playing && _wavePlayback,
                          onTap: _playing || _paused ? _stop : null,
                        ),
                        _WaveIconBtn(
                          icon: Icons.content_cut,
                          tooltip: 'Crop selection',
                          selected: _cropToolActive && _loadedAudio != null,
                          onTap: _loadedAudio == null
                              ? null
                              : () => setState(
                                    () => _cropToolActive = !_cropToolActive,
                                  ),
                        ),
                        _WaveIconBtn(
                          icon: Icons.crop_free,
                          tooltip: 'Select all',
                          onTap: _loadedAudio == null
                              ? null
                              : () => setState(() {
                                    _cropStart = 0;
                                    _cropEnd = 1;
                                    _cropToolActive = true;
                                  }),
                        ),
                        _WaveIconBtn(
                          icon: Icons.restart_alt,
                          tooltip: 'Reset crop',
                          onTap: _loadedAudio == null
                              ? null
                              : () => setState(() {
                                    _cropStart = 0;
                                    _cropEnd = 1;
                                  }),
                        ),
                        _WaveIconBtn(
                          icon: Icons.link,
                          tooltip: 'Load YouTube URL',
                          onTap: _busy ? null : _promptYoutubeUrl,
                        ),
                        _WaveIconBtn(
                          icon: Icons.save_alt,
                          tooltip: 'Save waveform / grid',
                          onTap: _busy ? null : _promptSaveDialog,
                        ),
                        const Spacer(),
                        _WaveIconBtn(
                          icon: Icons.sync,
                          tooltip: 'Sync crop → grid',
                          selected: _loadedAudio != null,
                          onTap: _loadedAudio != null && !_busy
                              ? _syncFromWaveform
                              : null,
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 72,
                      child: LayoutBuilder(
                        builder: (context, c) {
                          final size = Size(c.maxWidth, c.maxHeight);
                          return Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (e) =>
                                _onWavePointerDown(e, size),
                            onPointerMove: (e) =>
                                _onWavePointerMove(e, size),
                            onPointerUp: _onWavePointerUp,
                            onPointerCancel: (_) => _cropDrag = -1,
                            child: CustomPaint(
                              size: size,
                              painter: WaveformPainter(
                                peaks: _waveform,
                                cropStart: _cropStart,
                                cropEnd: _cropEnd,
                                showSelection: _loadedAudio != null &&
                                    _cropToolActive,
                                playhead: _playing && _wavePlayback
                                    ? _playhead
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _ToolChip(
                          label: 'Move',
                          selected: _tool == _EditTool.select,
                          onTap: () =>
                              setState(() => _tool = _EditTool.select),
                        ),
                        const SizedBox(width: 8),
                        _ToolChip(
                          label: 'Erase',
                          selected: _tool == _EditTool.eraser,
                          onTap: () =>
                              setState(() => _tool = _EditTool.eraser),
                        ),
                        const SizedBox(width: 8),
                        _ToolChip(
                          label: 'Import audio',
                          selected: false,
                          onTap: _busy ? () {} : _pickAndImport,
                        ),
                        const SizedBox(width: 8),
                        _ToolChip(
                          label: 'YouTube',
                          selected: false,
                          onTap: _busy ? () {} : _promptYoutubeUrl,
                        ),
                        const SizedBox(width: 8),
                        _ToolChip(
                          label: 'Seed scale',
                          selected: false,
                          onTap: () => setState(() {
                            _checkpoint();
                            _raga.seedScaleOutline();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _ToolChip(
                          label: 'Clear',
                          selected: false,
                          onTap: () => setState(() {
                            _checkpoint();
                            _raga.clearCurve();
                            _waveform = Float32List(0);
                            _loadedAudio = null;
                            _detectedBpm = null;
                            _cropStart = 0;
                            _cropEnd = 1;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Grid lock',
                          style: theme.textTheme.bodyLarge),
                      subtitle: Text(
                        _raga.gridLock
                            ? 'Micro / Mini / Semi snap pitch (Y) and beat columns (X)'
                            : 'Free-flow continuous pitch & beat',
                        style: theme.textTheme.bodyMedium,
                      ),
                      value: _raga.gridLock,
                      onChanged: (v) => setState(() => _raga.gridLock = v),
                    ),
                    if (_raga.gridLock)
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final snap in ToneSnap.values)
                            _ToolChip(
                              label: snap.label,
                              selected: _raga.toneSnap == snap,
                              onTap: () =>
                                  setState(() => _raga.toneSnap = snap),
                            ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    Text('Scale (Y lanes)', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in _palette)
                          FilterChip(
                            label: Text(s.label),
                            selected: _raga.scale.contains(s),
                            onSelected: (on) {
                              setState(() {
                                if (on) {
                                  if (!_raga.scale.contains(s)) {
                                    _raga.scale.add(s);
                                    _raga.scale.sort(
                                      (a, b) => a.cents.compareTo(b.cents),
                                    );
                                  }
                                } else {
                                  _raga.scale.remove(s);
                                }
                              });
                            },
                            selectedColor: AppColors.peacock,
                            checkmarkColor: AppColors.gold,
                            labelStyle: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.sand,
                            ),
                            side: BorderSide(
                              color: _raga.scale.contains(s)
                                  ? AppColors.gold
                                  : AppColors.mist.withValues(alpha: 0.4),
                            ),
                            backgroundColor:
                                AppColors.teak.withValues(alpha: 0.7),
                          ),
                      ],
                    ),
                    if (_saved.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text('Saved ragas', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 40,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _saved.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final r = _saved[i];
                            return _ToolChip(
                              label: r.name,
                              selected: r.id == _raga.id,
                              onTap: () => _load(r),
                            );
                          },
                        ),
                      ),
                    ],
                    if (_status != null) ...[
                      const SizedBox(height: 6),
                      Text(_status!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: AppColors.goldSoft)),
                    ],
                    if (_busy &&
                        (_fetchProgress != null || _fetchIndeterminate)) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _fetchIndeterminate ? null : _fetchProgress,
                        minHeight: 4,
                        color: AppColors.gold,
                        backgroundColor:
                            AppColors.mist.withValues(alpha: 0.25),
                      ),
                      if (!_fetchIndeterminate && _fetchProgress != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${((_fetchProgress ?? 0) * 100).round()}%',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: AppColors.gold,
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Isolate entry: voice pitch + tempo → serializable map.
Map<String, Object> _importIsolate(Map<String, Object> args) {
  final samples = args['samples'] as Float32List;
  final sampleRate = args['sampleRate'] as int;
  final durationSeconds = args['durationSeconds'] as double;
  final saHzHint = args['saHz'] as double;
  final decoded = DecodedAudio(
    samples: samples,
    sampleRate: sampleRate,
    durationSeconds: durationSeconds,
  );
  final imported = importVoiceToCurve(decoded, saHzHint: saHzHint);
  return {
    'points': [for (final p in imported.points) p.toJson()],
    'bpm': imported.beatsPerMinute,
    'totalBeats': imported.totalBeats,
    'saHz': imported.saHz,
    'waveform': imported.waveform,
  };
}

/// Owns [TextEditingController] for the YouTube prompt (dispose with State).
class _YoutubeUrlDialog extends StatefulWidget {
  const _YoutubeUrlDialog();

  @override
  State<_YoutubeUrlDialog> createState() => _YoutubeUrlDialogState();
}

class _YoutubeUrlDialogState extends State<_YoutubeUrlDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_ctrl.text.trim());

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim();
    if (t == null || t.isEmpty) return;
    setState(() => _ctrl.text = t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppColors.teakDeep,
      title: Text('YouTube URL', style: theme.textTheme.titleLarge),
      content: TextField(
        controller: _ctrl,
        // Avoid autofocus — reduces CapsLock sync assert on Linux embedder.
        autofocus: false,
        style: theme.textTheme.bodyLarge,
        decoration: const InputDecoration(
          hintText: 'https://www.youtube.com/watch?v=…',
          hintStyle: TextStyle(color: AppColors.mist),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _paste,
          child: const Text('Paste'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Load', style: TextStyle(color: AppColors.gold)),
        ),
      ],
    );
  }
}

class _SaveChoice {
  const _SaveChoice({required this.waveform, required this.grid});
  final bool waveform;
  final bool grid;
}

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({
    required this.canSaveWaveform,
    required this.canSaveGrid,
  });

  final bool canSaveWaveform;
  final bool canSaveGrid;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late bool _waveform;
  late bool _grid;

  @override
  void initState() {
    super.initState();
    _waveform = widget.canSaveWaveform;
    _grid = widget.canSaveGrid;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppColors.teakDeep,
      title: Text('Save to disc', style: theme.textTheme.titleLarge),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Choose what to write to disc.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _waveform,
            onChanged: widget.canSaveWaveform
                ? (v) => setState(() => _waveform = v ?? false)
                : null,
            title: Text(
              'Waveform (WAV)',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: widget.canSaveWaveform
                    ? AppColors.sand
                    : AppColors.mist,
              ),
            ),
            subtitle: Text(
              widget.canSaveWaveform
                  ? 'Cropped selection as audio file'
                  : 'No audio loaded',
              style: theme.textTheme.bodySmall,
            ),
            activeColor: AppColors.gold,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          CheckboxListTile(
            value: _grid,
            onChanged: widget.canSaveGrid
                ? (v) => setState(() => _grid = v ?? false)
                : null,
            title: Text(
              'Grid (raga JSON)',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: widget.canSaveGrid ? AppColors.sand : AppColors.mist,
              ),
            ),
            subtitle: Text(
              widget.canSaveGrid
                  ? 'Editable pitch curve + library entry'
                  : 'No points on the grid',
              style: theme.textTheme.bodySmall,
            ),
            activeColor: AppColors.gold,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: (_waveform || _grid)
              ? () => Navigator.of(context).pop(
                    _SaveChoice(waveform: _waveform, grid: _grid),
                  )
              : null,
          child: const Text('Save', style: TextStyle(color: AppColors.gold)),
        ),
      ],
    );
  }
}

class _WaveIconBtn extends StatelessWidget {
  const _WaveIconBtn({
    required this.icon,
    required this.tooltip,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(
        icon,
        size: 20,
        color: !enabled
            ? AppColors.mist.withValues(alpha: 0.35)
            : selected
                ? AppColors.gold
                : AppColors.sand,
      ),
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.peacock
              : AppColors.teak.withValues(alpha: 0.65),
          border: Border(
            bottom: BorderSide(
              color: selected ? AppColors.gold : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: selected ? AppColors.sand : AppColors.mist,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
        ),
      ),
    );
  }
}
