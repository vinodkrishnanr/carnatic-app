import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../audio/audio_engine.dart';
import '../music/phrase.dart';
import '../music/pitch_envelope.dart';
import '../music/shankarabharanam.dart';
import '../music/swara.dart';
import '../theme/app_theme.dart';
import 'pitch_curve_painter.dart';

class PlayScreen extends StatefulWidget {
  const PlayScreen({super.key});

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  final AudioEngine _engine = AudioEngine();

  late Phrase _phrase;
  bool _withGamakas = false;
  bool _busy = false;
  bool _ready = false;
  String? _error;
  List<PitchPoint> _plot = const [];
  List<PitchPoint>? _barePlot;

  // Textbook Sa = 240 Hz first — exact JI frequencies match Carnatic tables.
  static const _saOptions = <(String, double)>[
    ('Sa · 240 Hz (textbook)', 240.00),
    ('C3 · 130.8 Hz', 130.81),
    ('D3 · 146.8 Hz', 146.83),
    ('E3 · 164.8 Hz', 164.81),
    ('F3 · 174.6 Hz', 174.61),
    ('G3 · 196.0 Hz', 196.00),
    ('A3 · 220.0 Hz', 220.00),
  ];
  int _saIndex = 0;

  double get _saHz => _saOptions[_saIndex].$2;

  @override
  void initState() {
    super.initState();
    _phrase = Shankarabharanam.exactScalePhrase();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _engine.init();
      await _engine.setSaHz(_saOptions[_saIndex].$2);
      _refreshPlots();
      if (mounted) {
        setState(() => _ready = true);
      }
      // Warm PCM cache so Play starts the voice immediately.
      unawaited(_prewarm());
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Audio init failed: $e');
      }
    }
  }

  void _refreshPlots() {
    // Envelope downsample only — do not render PCM on the UI isolate.
    final ornate = _phrase.buildEnvelope(withGamakas: true).downsample();
    final bare = _phrase.buildEnvelope(withGamakas: false).downsample();
    _plot = ornate;
    _barePlot = bare;
  }

  Future<void> _prewarm() async {
    try {
      await _engine.renderPhraseAsync(_phrase, withGamakas: _withGamakas);
    } catch (_) {
      // Prewarm is best-effort; Play will surface errors.
    }
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_busy || !_ready) return;
    setState(() => _busy = true);
    try {
      final result =
          await _engine.playPhrase(_phrase, withGamakas: _withGamakas);
      if (!mounted) return;
      setState(() {
        _plot = result.plot;
        _barePlot =
            _phrase.buildEnvelope(withGamakas: false).downsample();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    await _engine.stopPhrase();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phrases = Shankarabharanam.allPhrases(bpm: _phrase.beatsPerMinute);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1A3A3C),
              AppColors.teakDeep,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back,
                          color: AppColors.sand),
                    ),
                    Expanded(
                      child: Text(
                        Shankarabharanam.name,
                        style: theme.textTheme.headlineMedium,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Mēḷakarta ${Shankarabharanam.melakarta} · S R₂ G₃ M₁ P D₂ N₃ Ṡ · just intonation',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: CustomPaint(
                        painter: PitchCurvePainter(
                          points: _plot,
                          compare: _withGamakas ? _barePlot : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _withGamakas
                          ? 'Gold = gamaka contour · faint = bare swaras'
                          : 'Exact just pitches (no gamaka)',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.mist.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('Frequencies (Sa = ${_saHz.toStringAsFixed(1)} Hz)',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    _FrequencyTable(saHz: _saHz),
                    const SizedBox(height: 24),
                    Text('Phrase', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final p in phrases)
                          _Chip(
                            label: p.title,
                            selected: _phrase.id == p.id,
                            onTap: () {
                              setState(() {
                                _phrase = p;
                                // Exact scale is meant to be heard bare.
                                if (p.id == 'shankara_exact_scale') {
                                  _withGamakas = false;
                                }
                                _refreshPlots();
                              });
                              unawaited(_prewarm());
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text('Sa', style: theme.textTheme.labelLarge),
                    Slider(
                      value: _saIndex.toDouble(),
                      min: 0,
                      max: (_saOptions.length - 1).toDouble(),
                      divisions: _saOptions.length - 1,
                      label: _saOptions[_saIndex].$1,
                      onChanged: _ready
                          ? (v) async {
                              setState(() => _saIndex = v.round());
                              await _engine.setSaHz(_saHz);
                              _refreshPlots();
                              setState(() {});
                              unawaited(_prewarm());
                            }
                          : null,
                    ),
                    Text(
                      _saOptions[_saIndex].$1,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Gamakas', style: theme.textTheme.bodyLarge),
                      subtitle: Text(
                        _withGamakas
                            ? 'Ri/Da kampita · Ga/Ni nokku · Ma ardha'
                            : 'Steady exact Hz only',
                        style: theme.textTheme.bodyMedium,
                      ),
                      value: _withGamakas,
                      onChanged: (v) {
                        setState(() {
                          _withGamakas = v;
                          _refreshPlots();
                        });
                        unawaited(_prewarm());
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: Colors.redAccent),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _ready && !_busy ? _play : null,
                        style: TextButton.styleFrom(
                          backgroundColor: AppColors.gold,
                          foregroundColor: AppColors.teakDeep,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero,
                          ),
                        ),
                        child: Text(
                          _busy ? 'Rendering…' : 'Play',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: AppColors.teakDeep,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _ready ? _stop : null,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.sand,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                          side: BorderSide(color: AppColors.mist),
                        ),
                      ),
                      child: const Text('Stop'),
                    ),
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

class _FrequencyTable extends StatelessWidget {
  const _FrequencyTable({required this.saHz});

  final double saHz;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = Shankarabharanam.arohana;
    return Column(
      children: [
        for (final s in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    s.label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: AppColors.gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    s.fullName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.mist.withValues(alpha: 0.85),
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  '${s.hzAt(saHz).toStringAsFixed(1)} Hz',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _ratioLabel(s.ratio),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.mist.withValues(alpha: 0.65),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _ratioLabel(double r) {
    final known = <double, String>{
      1.0: '1/1',
      9 / 8: '9/8',
      5 / 4: '5/4',
      4 / 3: '4/3',
      3 / 2: '3/2',
      5 / 3: '5/3',
      15 / 8: '15/8',
      2.0: '2/1',
    };
    for (final e in known.entries) {
      if ((e.key - r).abs() < 1e-9) return e.value;
    }
    return r.toStringAsFixed(4);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.peacock
              : AppColors.teak.withValues(alpha: 0.6),
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
