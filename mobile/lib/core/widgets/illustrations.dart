import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Lightweight Flutter-drawn animated illustrations (CustomPainter +
/// one-shot TweenAnimationBuilder). No new dependency, no stock photos,
/// no emoji. Colours come from the current theme (primary/secondary +
/// gold), so the art follows light and dark mode.
///
/// Motion is deliberately ONE-SHOT (fade/draw-in + a single slow float
/// swell, ~2.4s) rather than an infinite loop: an endlessly repeating
/// controller would keep scheduling frames on every screen that shows
/// an illustration, which costs battery and breaks pumpAndSettle in
/// widget tests. The entry motion reads the same to the eye.

/// Shared-home motif: a teal house outline with a nest at its base and
/// three gold coins floating above it. Used on splash and login.
class NestIllustration extends StatelessWidget {
  const NestIllustration({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 2400),
        curve: Curves.easeInOut,
        builder: (context, t, child) {
          // One slow float swell: up 5px and back, over the same 2.4s.
          final dy = -5 * math.sin(math.pi * t);
          return Transform.translate(
            offset: Offset(0, dy),
            child: Opacity(
              opacity: 0.35 + 0.65 * t,
              child: CustomPaint(
                painter: _NestPainter(
                  progress: t,
                  primary: Theme.of(context).colorScheme.primary,
                  secondary: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NestPainter extends CustomPainter {
  _NestPainter({
    required this.progress,
    required this.primary,
    required this.secondary,
  });

  /// 0 → 1 draw-in progress.
  final double progress;

  /// Theme colours (teal/light-teal in light mode, plum/mauve in
  /// dark mode) — passed in so the art follows the theme.
  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final teal = Paint()
      ..color = primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.045
      ..strokeCap = StrokeCap.round;
    final tealLight = Paint()
      ..color = secondary
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.035
      ..strokeCap = StrokeCap.round;
    final gold = Paint()
      ..color = SplitNestTheme.goldAccent
      ..style = PaintingStyle.fill;

    // House roof + walls, drawn in as progress grows (top first).
    final roof = Path()
      ..moveTo(w * 0.08, h * 0.46)
      ..lineTo(w * 0.5, h * 0.14)
      ..lineTo(w * 0.92, h * 0.46);
    final walls = Path()
      ..moveTo(w * 0.16, h * 0.44)
      ..lineTo(w * 0.16, h * 0.74)
      ..lineTo(w * 0.84, h * 0.74)
      ..lineTo(w * 0.84, h * 0.44);
    final roofPortion = PathMetricsHelper.extract(roof, progress);
    final wallPortion =
        PathMetricsHelper.extract(walls, (progress * 1.4 - 0.4).clamp(0, 1));
    canvas.drawPath(roofPortion, teal);
    canvas.drawPath(wallPortion, tealLight);

    // Nest: three stacked arcs at the base, drawn after the walls.
    final nestP = (progress * 1.6 - 0.6).clamp(0, 1);
    if (nestP > 0) {
      for (var i = 0; i < 3; i++) {
        final y = h * (0.74 + i * 0.055);
        final sweep = math.pi * nestP;
        canvas.drawArc(
          Rect.fromCenter(
            center: Offset(w * 0.5, y - h * 0.05),
            width: w * (0.62 - i * 0.1),
            height: h * 0.16,
          ),
          0,
          sweep,
          false,
          i.isEven ? teal : tealLight,
        );
      }
    }

    // Three gold coins, popping in one by one above the nest.
    for (var i = 0; i < 3; i++) {
      final coinP = (progress * 3 - 1.4 - i * 0.35).clamp(0, 1);
      if (coinP <= 0) continue;
      final cx = w * (0.32 + i * 0.18);
      final cy = h * (0.62 - (i == 1 ? 0.06 : 0.0)) - 4 * math.sin(math.pi * coinP);
      final r = w * 0.075 * (0.6 + 0.4 * coinP);
      canvas.drawCircle(Offset(cx, cy), r, gold);
      canvas.drawCircle(
        Offset(cx, cy),
        r * 0.55,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.02,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NestPainter old) =>
      old.progress != progress;
}

/// Small helper: take the first [fraction] of a path's length.
class PathMetricsHelper {
  static Path extract(Path path, double fraction) {
    final out = Path();
    if (fraction <= 0) return out;
    for (final metric in path.computeMetrics()) {
      out.addPath(
        metric.extractPath(0, metric.length * fraction.clamp(0, 1)),
        Offset.zero,
      );
    }
    return out;
  }
}

/// Which empty-state illustration to draw.
enum EmptyArtKind { basket, receipt, settled }

/// Small animated illustration for empty states (shopping, expenses,
/// settled-up balances) — a gentle fade + float-in, then still.
class EmptyStateIllustration extends StatelessWidget {
  const EmptyStateIllustration({
    super.key,
    required this.kind,
    this.size = 96,
  });

  final EmptyArtKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1400),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          final dy = -4 * math.sin(math.pi * t);
          return Transform.translate(
            offset: Offset(0, dy),
            child: Opacity(
              opacity: t,
              child: CustomPaint(
              painter: _EmptyPainter(
                kind: kind,
                t: t,
                primary: Theme.of(context).colorScheme.primary,
                secondary: Theme.of(context).colorScheme.secondary,
              ),
            ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyPainter extends CustomPainter {
  _EmptyPainter({
    required this.kind,
    required this.t,
    required this.primary,
    required this.secondary,
  });

  final EmptyArtKind kind;
  final double t;

  /// Theme colours — passed in so the art follows light/dark mode.
  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final teal = Paint()
      ..color = primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.045
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final tealLight = Paint()
      ..color = secondary
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.04
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final gold = Paint()
      ..color = SplitNestTheme.goldAccent
      ..style = PaintingStyle.fill;

    switch (kind) {
      case EmptyArtKind.basket:
        // Shopping basket: trapezoid + handle arc.
        final body = Path()
          ..moveTo(w * 0.18, h * 0.42)
          ..lineTo(w * 0.82, h * 0.42)
          ..lineTo(w * 0.72, h * 0.86)
          ..lineTo(w * 0.28, h * 0.86)
          ..close();
        canvas.drawPath(PathMetricsHelper.extract(body, t), teal);
        final handle = Path()
          ..moveTo(w * 0.3, h * 0.42)
          ..quadraticBezierTo(w * 0.5, h * 0.14, w * 0.7, h * 0.42);
        canvas.drawPath(
          PathMetricsHelper.extract(handle, (t * 1.5 - 0.5).clamp(0, 1)),
          tealLight,
        );
        if (t > 0.7) {
          canvas.drawCircle(Offset(w * 0.5, h * 0.3), w * 0.06, gold);
        }
      case EmptyArtKind.receipt:
        // Receipt: rounded rect + folded corner + text lines.
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.26, h * 0.12, w * 0.48, h * 0.76),
          Radius.circular(w * 0.06),
        );
        canvas.drawRRect(rrect, teal);
        final fold = Path()
          ..moveTo(w * 0.74, h * 0.12)
          ..lineTo(w * 0.74, h * 0.28)
          ..lineTo(w * 0.6, h * 0.12)
          ..close();
        canvas.drawPath(fold, tealLight);
        for (var i = 0; i < 3; i++) {
          final lineP = (t * 2 - 0.6 - i * 0.25).clamp(0, 1);
          if (lineP <= 0) continue;
          final y = h * (0.42 + i * 0.14);
          canvas.drawLine(
            Offset(w * 0.36, y),
            Offset(w * (0.36 + 0.28 * lineP), y),
            tealLight,
          );
        }
      case EmptyArtKind.settled:
        // Settled-up: circle + check mark, gold coin accent.
        canvas.drawCircle(
          Offset(w * 0.5, h * 0.5),
          w * 0.32 * t,
          teal,
        );
        final check = Path()
          ..moveTo(w * 0.34, h * 0.52)
          ..lineTo(w * 0.47, h * 0.66)
          ..lineTo(w * 0.68, h * 0.36);
        canvas.drawPath(
          PathMetricsHelper.extract(check, (t * 1.6 - 0.6).clamp(0, 1)),
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * 0.055
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
        if (t > 0.8) {
          canvas.drawCircle(Offset(w * 0.78, h * 0.2), w * 0.08, gold);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _EmptyPainter old) =>
      old.kind != kind || old.t != t;
}
