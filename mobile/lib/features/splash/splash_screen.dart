import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/illustrations.dart';

/// Splash page: SplitNest logo centred on white, wordmark underneath,
/// then the app auto-advances (after ~1.8s) to the login page.
/// Shown in every build, including web — it is a Flutter widget,
/// not a native-only splash.
///
/// HONEST LIMIT: the v2 logo is a single WebP image — its nest lines
/// and coins are baked in and cannot be animated separately. So the
/// animation is: the whole logo fades + scales in, then three separate
/// Flutter-drawn gold coins drop in one by one beneath it (they are
/// their own widgets, not the logo's coins), then the whole logo does
/// one soft pulse swell. No fake "line-draw" effect: overlaid curves
/// would misalign with the baked-in nest lines and look hacked.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final reduceMotion = animationsDisabled(context);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated shared-home illustration (draw-in + gentle
              // float) above the logo.
              const NestIllustration(size: 110),
              const SizedBox(height: 8),
              // Entrance: fade + scale-in (400ms, ease-out).
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.94 + 0.06 * t,
                    child: child,
                  ),
                ),
                // Pulse: one gentle swell while the splash shows.
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 1600),
                  curve: Curves.easeInOut,
                  builder: (context, t, child) => Transform.scale(
                    scale: 1 + 0.03 * math.sin(t * math.pi),
                    child: child,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(32),
                    child: Image.asset(
                      'assets/splitnest-logo-v2.webp',
                      width: 160,
                      height: 160,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Three separate gold coins, dropping in one by one
              // beneath the logo (own widgets — not the logo's coins).
              _GoldCoinRow(reduceMotion: reduceMotion),
              const SizedBox(height: 16),
              Text(
                'SplitNest',
                style: SplitNestTheme.titleStyle.copyWith(
                  fontSize: 30,
                  color: SplitNestTheme.ink,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: 48,
                height: 4,
                decoration: BoxDecoration(
                  color: SplitNestTheme.goldAccent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Shared living, settled simply.',
                style: SplitNestTheme.supportingStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Row of three Flutter-drawn gold coins (gradient disc + shine).
/// They drop in one by one (staggered) — one-shot, test-safe.
class _GoldCoinRow extends StatelessWidget {
  const _GoldCoinRow({required this.reduceMotion});

  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 1200),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                _GoldCoin(progress: (t - i * 0.22).clamp(0.0, 1.0) / 0.56),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _GoldCoin extends StatelessWidget {
  const _GoldCoin({required this.progress});

  /// 0 → 1 drop-in progress for this coin.
  final double progress;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    return Opacity(
      opacity: p,
      child: Transform.translate(
        offset: Offset(0, -14 * (1 - p)),
        child: Transform.scale(
          scale: 0.7 + 0.3 * p,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF7DC8F),
                  SplitNestTheme.goldAccent,
                  Color(0xFFC9971F),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.65),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: SplitNestTheme.goldAccent.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.8),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
