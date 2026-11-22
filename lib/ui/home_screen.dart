import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import 'play_screen.dart';
import 'raga_editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: AnimatedBuilder(
        animation: _breath,
        builder: (context, _) {
          final glow = 0.35 + _breath.value * 0.25;
          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.35),
                radius: 1.15,
                colors: [
                  AppColors.peacock.withValues(alpha: glow),
                  AppColors.teakDeep,
                  const Color(0xFF080504),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(flex: 2),
                    Text(
                      'GAMAKA',
                      style: theme.textTheme.displayLarge?.copyWith(
                        fontSize: 52,
                        color: AppColors.sand,
                        height: 0.95,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Draw scale and gamakas on a beat × sargam grid, then save as your raga.',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: AppColors.mist.withValues(alpha: 0.9),
                      ),
                    ),
                    const Spacer(flex: 3),
                    _HeroCta(
                      label: 'Edit a raga',
                      onPressed: () {
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            transitionDuration:
                                const Duration(milliseconds: 480),
                            pageBuilder: (context, anim, secondaryAnim) =>
                                FadeTransition(
                              opacity: anim,
                              child: const RagaEditorScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PlayScreen(),
                          ),
                        );
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.sand,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                          side: BorderSide(color: AppColors.mist),
                        ),
                      ),
                      child: const Text('Listen to Śankarābharaṇam'),
                    ),
                    const SizedBox(height: 36),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HeroCta extends StatelessWidget {
  const _HeroCta({required this.onPressed, required this.label});

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.teakDeep,
          backgroundColor: AppColors.gold,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
          ),
        ),
        child: Text(
          label,
          style: GoogleFontsSafe.label(context),
        ),
      ),
    );
  }
}

/// Tiny helper so we don't import google_fonts in every button.
class GoogleFontsSafe {
  static TextStyle label(BuildContext context) {
    return Theme.of(context).textTheme.labelLarge!.copyWith(
          color: AppColors.teakDeep,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        );
  }
}
