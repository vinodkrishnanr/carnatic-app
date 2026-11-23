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
  /// Selected grid anchor indices (live list).
  final Set<int> _selectedPoints = {};
  /// Origins at multi-select drag start (index → point).
  Map<int, CurvePoint>? _multiDragOrigins;
  Offset? _multiDragStartLocal;
  bool _panning = false;
  Offset? _panLast;
  final _viewport = GridViewport();
  final List<String> _undoStack = [];
  static const _maxUndo = 40;
  /// Last surface used for Space play/pause.
  bool _focusWave = false;
  final _editorFocus = FocusNode(debugLabel: 'ragaEditor');
  final _nameFocus = FocusNode(debugLabel: 'ragaName');
  DateTime? _lastLineTapAt;
  Offset? _lastLineTapPos;
  /// After double-click add on the gold line, drag creates edge bends.
  bool _autoBendOnDrag = false;
  bool _busy = false;
  bool _playing = false;
  bool _paused = false;
  /// Which source is active: grid phrase vs waveform strip.
  bool _wavePlayback = false;
  /// 0–1 playhead within the cropped waveform.
  double _wavePlayhead = 0;
  /// 0–1 playhead along the grid phrase.
  double _gridPlayhead = 0;
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
  /// Wave pointer down — click (no drag) seeks the playhead.
  Offset? _waveDownPos;
  double _waveDownT = 0;
  bool _waveDidDrag = false;
  bool _wavePanning = false;
  Offset? _wavePanLast;
  final _waveViewport = WaveformViewport();
  /// Vertical size of the waveform strip (grid takes the rest).
  double _waveStripHeight = 96;
  static const _waveStripMin = 48.0;
  static const _waveStripMax = 360.0;
  bool _splitting = false;
  /// Grid empty-space down — click seeks; drag pans.
  Offset? _gridDownPos;
  double _gridDownBeat = 0;
  bool _gridDidPan = false;
  double? _detectedBpm;
  StreamSubscription<String>? _dropSub;
  bool _dropHighlight = false;
  static const _clickSlop = 6.0;

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
    // Global handler so Space/Delete/Ctrl+Z work even after clicking the
    // CustomPaint (which does not take Flutter focus by itself).
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
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
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _playheadTimer?.cancel();
    _dropSub?.cancel();
    _nameCtrl.dispose();
    _nameFocus.dispose();
    _editorFocus.dispose();
    _engine.dispose();
    super.dispose();
  }

  bool get _isTypingInField => _nameFocus.hasFocus;

  /// Click → make grid/waveform active (Space/Delete target) + reclaim focus.
  void _activateSurface({required bool wave}) {
    final changed = _focusWave != wave;
    _focusWave = wave;
    // Drop name-field focus so Space is not typed as text / ignored.
    if (_nameFocus.hasFocus) _nameFocus.unfocus();
    _editorFocus.requestFocus();
    if (changed && mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorFocus.requestFocus();
      });
    }
  }

  bool _isSpaceKey(KeyEvent event) {
    return event.logicalKey == LogicalKeyboardKey.space ||
        event.physicalKey == PhysicalKeyboardKey.space ||
        event.character == ' ';
  }

  bool _onHardwareKey(KeyEvent event) {
    // Ignore key-up and auto-repeat (Space would toggle play every tick).
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;
    if (_isTypingInField) return false;

    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (_isSpaceKey(event)) {
      _onSpaceShortcut();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _onUndoShortcut();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyA) {
      _onSelectAllShortcut();
      return true;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _onDeleteShortcut();
      return true;
    }
    return false;
  }

  KeyEventResult _onEditorKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_isTypingInField) return KeyEventResult.ignored;
    if (_isSpaceKey(event)) {
      _onSpaceShortcut();
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _onUndoShortcut();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyA) {
      _onSelectAllShortcut();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _onDeleteShortcut();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _selectAllPoints() {
    setState(() {
      _selectedPoints
        ..clear()
        ..addAll(Iterable.generate(_raga.points.length));
      _status = _selectedPoints.isEmpty
          ? 'No points to select'
          : 'Selected ${_selectedPoints.length} points';
    });
  }

  /// Select-all for the active surface (grid points or full waveform crop).
  void _selectAllWaveform() {
    if (_loadedAudio == null) {
      setState(() => _status = 'No waveform to select');
      return;
    }
    setState(() {
      _cropStart = 0;
      _cropEnd = 1;
      _cropToolActive = true;
      _status = 'Waveform selected (full)';
    });
  }

  void _onSelectAllShortcut() {
    if (_isTypingInField) return;
    if (_focusWave) {
      _selectAllWaveform();
    } else {
      _selectAllPoints();
    }
  }

  DateTime? _lastSpaceAt;

  void _onSpaceShortcut() {
    if (_isTypingInField) return;
    if (!_ready) {
      setState(() => _status = 'Audio not ready yet');
      return;
    }
    // Dedupe Focus + HardwareKeyboard both seeing the same key.
    final now = DateTime.now();
    if (_lastSpaceAt != null &&
        now.difference(_lastSpaceAt!) < const Duration(milliseconds: 100)) {
      return;
    }
    _lastSpaceAt = now;
    // Allow pause/resume even if a prior render left _busy briefly.
    if (_busy && !_playing) return;
    if (_focusWave) {
      if (_loadedAudio == null) {
        setState(() => _status = 'No waveform loaded');
        return;
      }
      unawaited(_playWaveform());
    } else {
      unawaited(_playGrid());
    }
  }

  void _onUndoShortcut() {
    if (_isTypingInField) return;
    _undoLast();
  }

  void _onDeleteShortcut() {
    if (_isTypingInField || _busy) return;
    if (_focusWave) {
      _deleteWaveform();
    } else {
      _deleteGridSelection();
    }
  }

  /// Delete selected grid points; if none selected, clear the whole curve.
  void _deleteGridSelection() {
    if (_raga.points.isEmpty) {
      setState(() => _status = 'Nothing to delete on the grid');
      return;
    }
    _checkpoint();
    setState(() {
      if (_selectedPoints.isNotEmpty) {
        final n = _selectedPoints.length;
        _raga.eraseIndices(_selectedPoints);
        _selectedPoints.clear();
        _status = 'Deleted $n point${n == 1 ? '' : 's'}';
      } else {
        _raga.clearCurve();
        _selectedPoints.clear();
        _status = 'Cleared grid points';
      }
      _dragIndex = null;
      _dragEdgeDest = null;
      _multiDragOrigins = null;
      _multiDragStartLocal = null;
    });
  }

  /// Remove loaded waveform (crop/Sync source). Does not erase the grid.
  void _deleteWaveform() {
    if (_loadedAudio == null && _waveform.isEmpty) {
      setState(() => _status = 'No waveform to delete');
      return;
    }
    if (_playing && _wavePlayback) {
      unawaited(_stop());
    }
    setState(() {
      _waveform = Float32List(0);
      _loadedAudio = null;
      _cropStart = 0;
      _cropEnd = 1;
      _waveViewport.reset();
      _wavePlayhead = 0;
      _detectedBpm = _raga.points.isEmpty ? null : _detectedBpm;
      _status = 'Waveform removed';
    });
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
          });
          _playheadTimer?.cancel();
          _playheadTimer = null;
        }
        return;
      }
      setState(() {
        if (_wavePlayback) {
          if (p != _wavePlayhead) _wavePlayhead = p;
        } else {
          if (p != _gridPlayhead) _gridPlayhead = p;
        }
      });
    });
  }

  void _stopPlayheadTicker({bool reset = true}) {
    _playheadTimer?.cancel();
    _playheadTimer = null;
    if (reset) {
      _wavePlayhead = 0;
      _gridPlayhead = 0;
    }
  }

  /// Snap waveform playhead to [t] in full-file 0–1 (maps into crop).
  void _seekWaveToFileT(double fileT) {
    final span = (_cropEnd - _cropStart).clamp(1e-6, 1.0);
    final local = ((fileT - _cropStart) / span).clamp(0.0, 1.0);
    _seekWave(local);
  }

  /// Snap waveform playhead to [local] 0–1 within the crop.
  void _seekWave(double local) {
    final t = local.clamp(0.0, 1.0);
    final seekAudio = (_playing || _paused) && _wavePlayback;
    setState(() {
      _wavePlayhead = t;
      _wavePlayback = true;
    });
    if (seekAudio) _engine.seekPhrase(t);
  }

  /// Snap grid playhead to absolute [beat].
  void _seekGrid(double beat) {
    final total = _raga.totalBeats <= 0 ? 1.0 : _raga.totalBeats;
    final t = (beat / total).clamp(0.0, 1.0);
    final seekAudio = (_playing || _paused) && !_wavePlayback;
    setState(() {
      _gridPlayhead = t;
      _wavePlayback = false;
    });
    if (seekAudio) _engine.seekPhrase(t);
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
      _waveViewport.reset();
      _wavePlayhead = 0;
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
      // Do not force engine Sa — detect tonic from the recording.
      final map = await compute(_importIsolate, <String, Object>{
        'samples': cropped.samples,
        'sampleRate': cropped.sampleRate,
        'durationSeconds': cropped.durationSeconds,
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
      final phaseBeats = (map['beatPhaseBeats'] as num?)?.toDouble() ?? 0;
      _checkpoint();
      setState(() {
        _loadedAudio = cropped;
        _waveform = wave;
        _cropStart = 0;
        _cropEnd = 1;
        _waveViewport.reset();
        _wavePlayhead = 0;
        _raga.points
          ..clear()
          ..addAll(points);
        _raga.beatsPerMinute = bpm;
        _raga.totalBeats = totalBeats;
        _raga.gridLock = true;
        _raga.toneSnap = ToneSnap.mini;
        _detectedBpm = bpm;
        _viewport.zoom = 1.0;
        _viewport.beat0 = 0;
        _viewport.cents0 = _raga.minCents;
        _viewport.clampTo(_raga);
        final phaseMs = phaseBeats > 0.02
            ? ' · pickup ${(phaseBeats * 60 / bpm * 1000).round()} ms'
            : '';
        _status =
            'Synced → ${points.length} points · Sa ${saHz.toStringAsFixed(0)} Hz · ${bpm.toStringAsFixed(1)} BPM · grid lock$phaseMs';
      });
      await _engine.setSaHz(saHz);
    } catch (e) {
      if (mounted) setState(() => _status = 'Sync failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onWaveScroll(PointerScrollEvent e, Size size) {
    if (_loadedAudio == null || size.width <= 0) return;
    final dy = e.scrollDelta.dy;
    if (dy == 0) return;
    final factor = dy < 0 ? 1.12 : 1 / 1.12;
    setState(() {
      _waveViewport.zoomAt(size: size, local: e.localPosition, factor: factor);
    });
  }

  void _onWavePointerDown(PointerDownEvent e, Size size) {
    _activateSurface(wave: true);
    if (_loadedAudio == null || size.width <= 0) return;
    if ((e.buttons & kPrimaryMouseButton) == 0) return;
    final t = _waveViewport.timeAt(e.localPosition, size);
    _waveDownPos = e.localPosition;
    _waveDownT = t;
    _waveDidDrag = false;
    _wavePanning = false;
    _wavePanLast = null;
    _cropDrag = -1;

    if (_cropToolActive) {
      final x0 = _waveViewport.xFor(_cropStart, size);
      final x1 = _waveViewport.xFor(_cropEnd, size);
      const hit = 14.0;
      if ((e.localPosition.dx - x0).abs() <= hit) {
        _cropDrag = 0;
        return;
      }
      if ((e.localPosition.dx - x1).abs() <= hit) {
        _cropDrag = 1;
        return;
      }
      // When zoomed, interior drag must pan — crop often spans the whole
      // file (0–1), which would otherwise steal every drag as "move crop".
      final zoomed = _waveViewport.zoom > 1.01;
      if (!zoomed) {
        final left = math.min(x0, x1);
        final right = math.max(x0, x1);
        if (e.localPosition.dx >= left && e.localPosition.dx <= right) {
          // Fit view only: drag moves the crop window; click still seeks.
          _cropDrag = 2;
          _cropDragAnchor = t;
          _cropDragStart0 = _cropStart;
          _cropDragStart1 = _cropEnd;
          return;
        }
      }
    }
    // Empty space (and zoomed interior): click seeks; drag pans.
    _wavePanning = true;
    _wavePanLast = e.localPosition;
  }

  double _cropDragAnchor = 0;
  double _cropDragStart0 = 0;
  double _cropDragStart1 = 1;

  void _onWavePointerMove(PointerMoveEvent e, Size size) {
    if (_waveDownPos == null || size.width <= 0) return;
    final dist = (e.localPosition - _waveDownPos!).distance;
    if (dist > _clickSlop) _waveDidDrag = true;

    if (_wavePanning && _wavePanLast != null) {
      if (!_waveDidDrag) return;
      final delta = e.localPosition - _wavePanLast!;
      setState(() {
        _waveViewport.panBy(size: size, pixelDelta: delta);
        _wavePanLast = e.localPosition;
      });
      return;
    }

    if (!_cropToolActive || _cropDrag < 0) return;
    if (!_waveDidDrag && _cropDrag == 2) return; // still a potential click-seek

    final t = _waveViewport.timeAt(e.localPosition, size);

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

  void _onWavePointerUp(PointerUpEvent e) {
    // Click (no drag) → snap blue playhead. Handle / pan drags never seek.
    final clicked = !_waveDidDrag &&
        _waveDownPos != null &&
        _cropDrag != 0 &&
        _cropDrag != 1;
    if (clicked) {
      _seekWaveToFileT(_waveDownT);
    }
    _cropDrag = -1;
    _waveDownPos = null;
    _waveDidDrag = false;
    _wavePanning = false;
    _wavePanLast = null;
  }

  void _clearWaveDrag() {
    _cropDrag = -1;
    _waveDownPos = null;
    _waveDidDrag = false;
    _wavePanning = false;
    _wavePanLast = null;
  }

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
      _multiDragOrigins = null;
      _multiDragStartLocal = null;
      _selectedPoints.clear();
      _panning = false;
      _panLast = null;
      _status = 'Undid last change';
    });
  }

  void _remapSelectionAfterSort(Iterable<CurvePoint> kept) {
    final keys = kept
        .map((p) => (p.beat, p.cents, p.bendBeat, p.bendCents))
        .toSet();
    _selectedPoints
      ..clear()
      ..addAll([
        for (var i = 0; i < _raga.points.length; i++)
          if (keys.contains((
            _raga.points[i].beat,
            _raga.points[i].cents,
            _raga.points[i].bendBeat,
            _raga.points[i].bendCents,
          )))
            i,
      ]);
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
    _activateSurface(wave: false);
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
      _multiDragOrigins = null;
      _multiDragStartLocal = null;
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
        if (_selectedPoints.isNotEmpty &&
            (hitPoint == null || _selectedPoints.contains(hitPoint))) {
          _raga.eraseIndices(_selectedPoints);
          _selectedPoints.clear();
        } else {
          _raga.eraseNear(beat, cents);
          _selectedPoints.clear();
        }
        _dragIndex = null;
        _dragEdgeDest = null;
        _multiDragOrigins = null;
        _multiDragStartLocal = null;
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
      final keepMulti =
          _selectedPoints.length > 1 && _selectedPoints.contains(hitPoint);
      setState(() {
        if (!keepMulti) {
          _selectedPoints
            ..clear()
            ..add(hitPoint);
        }
        _dragIndex = hitPoint;
        _dragEdgeDest = null;
        _panning = false;
        _panLast = null;
        if (_selectedPoints.length > 1) {
          _multiDragOrigins = {
            for (final i in _selectedPoints)
              if (i >= 0 && i < _raga.points.length) i: _raga.points[i],
          };
          _multiDragStartLocal = e.localPosition;
        } else {
          _multiDragOrigins = null;
          _multiDragStartLocal = null;
        }
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
        _selectedPoints.clear();
        _dragIndex = null;
        _dragEdgeDest = hitHandle;
        _multiDragOrigins = null;
        _multiDragStartLocal = null;
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
          _selectedPoints
            ..clear()
            ..addAll(idx >= 0 ? [idx] : const <int>[]);
          _dragIndex = idx >= 0 ? idx : null;
          _dragEdgeDest = null;
          _multiDragOrigins = null;
          _multiDragStartLocal = null;
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
    // Empty space: click seeks playhead; drag pans. Clears multi-selection.
    _gridDownPos = e.localPosition;
    _gridDownBeat = beat;
    _gridDidPan = false;
    setState(() {
      _selectedPoints.clear();
      _dragIndex = null;
      _dragEdgeDest = null;
      _multiDragOrigins = null;
      _multiDragStartLocal = null;
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
      if (!_gridDidPan) {
        if (_gridDownPos != null &&
            (e.localPosition - _gridDownPos!).distance > _clickSlop) {
          _gridDidPan = true;
          _panLast = e.localPosition; // commit pan without jump
        }
        return;
      }
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

    final origins = _multiDragOrigins;
    final startLocal = _multiDragStartLocal;
    if (origins != null && origins.length > 1 && startLocal != null) {
      final startBeat = map.beatAt(startLocal);
      final startCents = map.centsAt(startLocal);
      final dBeat = map.beatAt(e.localPosition) - startBeat;
      final dCents = map.centsAt(e.localPosition) - startCents;
      setState(() {
        _raga.movePointsFromOrigins(origins, dBeat, dCents);
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
    // Empty-grid click (no pan) → snap blue playhead to that beat.
    if (_panning && !_gridDidPan && _gridDownPos != null) {
      _seekGrid(_gridDownBeat);
    }
    _gridDownPos = null;
    _gridDidPan = false;
    if (_dragIndex != null || _dragEdgeDest != null || _panning) {
      setState(() {
        if (_dragIndex != null || _dragEdgeDest != null) {
          final kept = [
            for (final i in _selectedPoints)
              if (i >= 0 && i < _raga.points.length) _raga.points[i],
          ];
          _raga.sortPoints();
          if (kept.isNotEmpty) {
            _remapSelectionAfterSort(kept);
          }
        }
        _dragIndex = null;
        _dragEdgeDest = null;
        _multiDragOrigins = null;
        _multiDragStartLocal = null;
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
    // Pause/resume only when grid audio is already the active source.
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
    // Claim busy immediately so Space/wave cannot start a parallel play.
    _busy = true;
    setState(() {
      _wavePlayback = false;
      _status = 'Playing grid…';
    });
    try {
      // Switching from waveform → stop wave voice before synth render.
      if (_playing) await _engine.stopPhrase();
      final startAt = _gridPlayhead;
      final played = await _engine.playEnvelope(
        _raga.toEnvelope(),
        label: _raga.id,
      );
      if (!mounted) return;
      if (played == null) {
        setState(() => _status = 'Grid play cancelled');
        return;
      }
      setState(() {
        _playing = true;
        _paused = false;
        _wavePlayback = false;
        _status = null;
      });
      if (startAt > 0) _engine.seekPhrase(startAt);
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
    // Pause/resume only when waveform audio is already the active source.
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
    _busy = true;
    setState(() {
      _wavePlayback = true;
      _status = 'Playing waveform…';
    });
    try {
      // Switching from grid → hard-stop synth so it cannot keep sounding
      // under the waveform playhead.
      await _engine.stopPhrase();
      final cropped = _croppedAudio();
      final startAt = _wavePlayhead;
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
        _status = null;
      });
      if (startAt > 0) _engine.seekPhrase(startAt);
      _startPlayheadTicker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Wave play failed: $e';
          _wavePlayback = false;
          _playing = false;
        });
      }
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
        _busy = false;
      });
    }
  }

  Future<void> _load(EditableRaga r) async {
    setState(() {
      _raga = EditableRaga.decode(r.encode());
      _nameCtrl.text = _raga.name;
      _detectedBpm = _raga.beatsPerMinute;
      _selectedPoints.clear();
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
      body: Focus(
        focusNode: _editorFocus,
        autofocus: true,
        onKeyEvent: _onEditorKeyEvent,
        child: Container(
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
                          icon: const Icon(Icons.arrow_back,
                              color: AppColors.sand),
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
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'Click to activate · Space play · Ctrl+A select all · Delete · Ctrl+Z undo',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: TextField(
                      controller: _nameCtrl,
                      focusNode: _nameFocus,
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
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                    child: Row(
                      children: [
                        _WaveIconBtn(
                          icon: _playing && !_wavePlayback && !_paused
                              ? Icons.pause
                              : Icons.play_arrow,
                          tooltip: _playing && !_wavePlayback && !_paused
                              ? 'Pause grid (Space)'
                              : 'Play grid (Space)',
                          selected: _playing && !_wavePlayback,
                          onTap: _ready && !_busy
                              ? () {
                                  _activateSurface(wave: false);
                                  unawaited(_playGrid());
                                }
                              : null,
                        ),
                        _WaveIconBtn(
                          icon: Icons.stop,
                          tooltip: 'Stop',
                          selected: _playing && !_wavePlayback,
                          onTap: _playing || _paused ? _stop : null,
                        ),
                        _WaveIconBtn(
                          icon: Icons.undo,
                          tooltip: 'Undo (Ctrl+Z)',
                          onTap: _undoStack.isEmpty ? null : _undoLast,
                        ),
                        _WaveIconBtn(
                          icon: Icons.select_all,
                          tooltip: 'Select all points (Ctrl+A)',
                          selected: _selectedPoints.isNotEmpty &&
                              _selectedPoints.length == _raga.points.length &&
                              _raga.points.isNotEmpty,
                          onTap: _raga.points.isEmpty
                              ? null
                              : () {
                                  _activateSurface(wave: false);
                                  _selectAllPoints();
                                },
                        ),
                        _WaveIconBtn(
                          icon: Icons.delete_outline,
                          tooltip:
                              'Delete selection (Delete) · no selection clears grid',
                          onTap: _raga.points.isEmpty
                              ? null
                              : () {
                                  _activateSurface(wave: false);
                                  _deleteGridSelection();
                                },
                        ),
                        _WaveIconBtn(
                          icon: Icons.save,
                          tooltip: 'Save waveform / grid',
                          selected: true,
                          onTap: _busy ? null : _promptSaveDialog,
                        ),
                        const Spacer(),
                        Text(
                          _focusWave ? '' : 'ACTIVE',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: AppColors.gold,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                        if (_selectedPoints.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              '${_selectedPoints.length} selected',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: AppColors.goldSoft,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = Size(
                              constraints.maxWidth, constraints.maxHeight);
                          final gridActive = !_focusWave;
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              color: gridActive
                                  ? Colors.white.withValues(alpha: 0.07)
                                  : Colors.black.withValues(alpha: 0.12),
                              border: Border.all(
                                color: _dropHighlight
                                    ? AppColors.gold
                                    : gridActive
                                        ? AppColors.gold.withValues(alpha: 0.45)
                                        : Colors.transparent,
                                width: gridActive ? 1.5 : 1,
                              ),
                            ),
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerSignal: (e) {
                                if (e is PointerScrollEvent) {
                                  _onScroll(e, size);
                                }
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
                                  playheadBeat:
                                      _gridPlayhead * _raga.totalBeats,
                                  selectedIndices: Set<int>.from(
                                    _selectedPoints,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              // Draggable border between grid and waveform.
              MouseRegion(
                cursor: SystemMouseCursors.resizeUpDown,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (_) => setState(() => _splitting = true),
                  onVerticalDragUpdate: (d) {
                    setState(() {
                      _waveStripHeight = (_waveStripHeight - d.delta.dy)
                          .clamp(_waveStripMin, _waveStripMax);
                    });
                  },
                  onVerticalDragEnd: (_) =>
                      setState(() => _splitting = false),
                  onVerticalDragCancel: () =>
                      setState(() => _splitting = false),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      height: 10,
                      child: Center(
                        child: Container(
                          height: 3,
                          decoration: BoxDecoration(
                            color: _splitting
                                ? AppColors.gold
                                : AppColors.mist.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
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
                              ? () {
                                  _activateSurface(wave: true);
                                  unawaited(_playWaveform());
                                }
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
                          tooltip: 'Select all (Ctrl+A)',
                          onTap: _loadedAudio == null
                              ? null
                              : () {
                                  _activateSurface(wave: true);
                                  _selectAllWaveform();
                                },
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
                          icon: Icons.delete_outline,
                          tooltip: 'Delete waveform (Delete)',
                          onTap: _loadedAudio == null && _waveform.isEmpty
                              ? null
                              : () {
                                  _activateSurface(wave: true);
                                  _deleteWaveform();
                                },
                        ),
                        _WaveIconBtn(
                          icon: Icons.save_alt,
                          tooltip: 'Save waveform / grid',
                          onTap: _busy ? null : _promptSaveDialog,
                        ),
                        const Spacer(),
                        Text(
                          _focusWave ? 'ACTIVE' : '',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: AppColors.gold,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(width: 8),
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
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: _focusWave
                            ? Colors.white.withValues(alpha: 0.07)
                            : Colors.black.withValues(alpha: 0.12),
                        border: Border.all(
                          color: _focusWave
                              ? AppColors.gold.withValues(alpha: 0.45)
                              : Colors.transparent,
                          width: _focusWave ? 1.5 : 1,
                        ),
                      ),
                      child: SizedBox(
                        height: _waveStripHeight,
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final size = Size(c.maxWidth, c.maxHeight);
                            return Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerSignal: (e) {
                                if (e is PointerScrollEvent) {
                                  _onWaveScroll(e, size);
                                }
                              },
                              onPointerDown: (e) =>
                                  _onWavePointerDown(e, size),
                              onPointerMove: (e) =>
                                  _onWavePointerMove(e, size),
                              onPointerUp: _onWavePointerUp,
                              onPointerCancel: (_) => _clearWaveDrag(),
                              child: CustomPaint(
                                size: size,
                                painter: WaveformPainter(
                                  peaks: _waveform,
                                  cropStart: _cropStart,
                                  cropEnd: _cropEnd,
                                  showSelection: _loadedAudio != null &&
                                      _cropToolActive,
                                  playhead: _loadedAudio != null
                                      ? _wavePlayhead
                                      : null,
                                  viewport: _waveViewport,
                                ),
                              ),
                            );
                          },
                        ),
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
                            _waveViewport.reset();
                            _wavePlayhead = 0;
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
    ),
    );
  }
}

/// Isolate entry: voice pitch + tempo → serializable map.
Map<String, Object> _importIsolate(Map<String, Object> args) {
  final samples = args['samples'] as Float32List;
  final sampleRate = args['sampleRate'] as int;
  final durationSeconds = args['durationSeconds'] as double;
  final decoded = DecodedAudio(
    samples: samples,
    sampleRate: sampleRate,
    durationSeconds: durationSeconds,
  );
  // Auto-detect Sa from pitch (engine Sa was wrongly forcing 220 Hz).
  final imported = importVoiceToCurve(decoded);
  return {
    'points': [for (final p in imported.points) p.toJson()],
    'bpm': imported.beatsPerMinute,
    'beatPhaseBeats': imported.beatPhaseBeats,
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
    // Keep toolbar icons from taking keyboard focus — otherwise Space
    // activates the focused button instead of play/pause.
    return ExcludeFocus(
      child: IconButton(
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
      ),
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
