import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/audio_engine.dart';
import '../music/editable_raga.dart';
import '../music/swara.dart';
import '../storage/raga_store.dart';
import '../theme/app_theme.dart';
import 'raga_grid_painter.dart';

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
  bool _ready = false;
  String? _status;

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
    _viewport.cents0 = _raga.minCents;
    _viewport.clampTo(_raga);
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
    _nameCtrl.dispose();
    _engine.dispose();
    super.dispose();
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

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _status = 'Give the raga a name before saving.');
      return;
    }
    _raga.name = name;
    if (_raga.id.startsWith('template_')) {
      _raga = _raga.cloneWithNewId(name);
      _nameCtrl.text = name;
    }
    await _store.save(_raga);
    _saved = await _store.list();
    setState(() => _status = 'Saved “${_raga.name}”.');
  }

  Future<void> _play() async {
    if (!_ready || _busy) return;
    if (_raga.points.isEmpty) {
      setState(() => _status = 'Add points first (right-click).');
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
        _status = null;
      });
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    await _engine.stopPhrase();
    if (mounted) {
      setState(() {
        _playing = false;
        _busy = false;
      });
    }
  }

  Future<void> _load(EditableRaga r) async {
    setState(() {
      _raga = EditableRaga.decode(r.encode());
      _nameCtrl.text = _raga.name;
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
                    TextButton(
                      onPressed: _ready && !_busy ? _play : null,
                      child: Text(_busy ? '…' : 'Play',
                          style: theme.textTheme.labelLarge),
                    ),
                    TextButton(
                      onPressed: _stop,
                      child: Text(
                        'Stop',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: _playing ? AppColors.gold : AppColors.mist,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: _save,
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.gold,
                        foregroundColor: AppColors.teakDeep,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                      child: Text(
                        'Save',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: AppColors.teakDeep,
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
                  'Click note to hear · scroll zoom · pan empty · drag point · blue handle bends · double-click line adds · right-click empty undo',
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
                      return Listener(
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
                          ),
                        ),
                      );
                    },
                  ),
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
