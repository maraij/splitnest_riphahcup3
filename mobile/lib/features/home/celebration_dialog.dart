/// Savings celebration: shown ONCE per login, AFTER the welcome
/// popup is dismissed (never stacked with it), only when the
/// logged-in member saved money — saved = fair share (budget / 3)
/// minus their share, and only while the house is under budget.
/// Animated gold coins (Flutter-drawn, theme colours, no emoji).
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/models.dart';

Future<void> showCelebrationDialog(
  BuildContext context, {
  required Member member,
  required double savedAmount,
  required VoidCallback onViewMonthly,
  // Month-over-month improvement (last month's share minus this
  // month's share, from real recorded history). Null when there is
  // no last-month history or no improvement — then the celebration
  // shows WITHOUT the comparison line and WITHOUT poppers.
  double? monthOverMonthSaved,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Party poppers: one-shot confetti burst in theme
            // colours (gold / teal / navy, Flutter-drawn, no emoji).
            // Only when the MoM comparison is real and positive.
            if (monthOverMonthSaved != null) ...[
              const _Poppers(),
              const SizedBox(height: 8),
            ],
            // Animated coins: fade + scale in together (400ms).
            // easeOutBack overshoots past 1.0 for the pop — Opacity
            // must be clamped to [0, 1] or it throws.
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutBack,
              builder: (context, t, child) => Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.7 + 0.3 * t, child: child),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Container(
                      width: 36,
                      height: 36,
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
                      ),
                      child: const Icon(
                        Icons.star,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Great job, ${member.name}!',
              style: SplitNestTheme.titleStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'You saved PKR ${savedAmount.toStringAsFixed(2)} this month',
              style: SplitNestTheme.bodyStyle.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(ctx).colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            const Text(
              'Your share stayed under your fair share of the budget.',
              style: SplitNestTheme.supportingStyle,
              textAlign: TextAlign.center,
            ),
            if (monthOverMonthSaved != null) ...[
              const SizedBox(height: 8),
              Text(
                'You saved PKR ${monthOverMonthSaved.toStringAsFixed(2)} more than last month!',
                style: SplitNestTheme.bodyStyle.copyWith(
                  fontWeight: FontWeight.w700,
                  color: SplitNestTheme.goldAccent,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  // Push only after the dialog route is gone:
                  // pushing in the same frame as the pop leaves the
                  // dialog's focus scope dirty outside its build
                  // scope (scheduler assertion).
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => onViewMonthly());
                },
                child: const Text('View monthly summary'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One-shot party-popper burst: small Flutter-drawn confetti pieces
/// (gold circles, teal rectangles, navy dots) that drift down and
/// fade once (700ms, staggered). No emoji, theme colours only.
/// Keyed so tests can assert it only appears with a real MoM win.
class _Poppers extends StatelessWidget {
  const _Poppers();

  static const _pieces = [
    (Color(0xFFC9A227), true), // gold circle
    (Color(0xFF0F766E), false), // teal rectangle
    (Color(0xFF1D2D44), true), // navy dot
    (Color(0xFFC9A227), false), // gold rectangle
    (Color(0xFF14B8A6), true), // light teal circle
    (Color(0xFF1D2D44), false), // navy rectangle
    (Color(0xFFC9A227), true), // gold circle
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('celebration-poppers'),
      height: 28,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _pieces.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: Duration(milliseconds: 500 + i * 60),
              curve: Curves.easeOut,
              builder: (context, t, child) => Opacity(
                opacity: (1 - t).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, -6 + 14 * t),
                  child: Transform.rotate(angle: t * 0.8, child: child),
                ),
              ),
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: _pieces[i].$1,
                  shape: _pieces[i].$2
                      ? BoxShape.circle
                      : BoxShape.rectangle,
                  borderRadius: _pieces[i].$2
                      ? null
                      : BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
