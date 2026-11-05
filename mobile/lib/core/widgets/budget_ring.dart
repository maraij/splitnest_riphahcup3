import 'package:flutter/material.dart';

import '../theme.dart';
import 'entrance.dart';

/// Budget usage ring: progress circle with the % used in the centre.
/// Animates from 0 to the used percent (700ms, ease-out) instead of
/// jumping to it; jumps straight there when reduced motion is on.
/// Colour follows the budget status (green → amber → red) and the
/// percentage is always printed, so the ring is never the only signal.
class BudgetRing extends StatelessWidget {
  const BudgetRing({
    super.key,
    required this.usedPercent,
    this.size = 132,
  });

  final double usedPercent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = StatusColors.of(context);
    final color = usedPercent > 100
        ? colors.error
        : usedPercent >= 84
            ? colors.warning
            : colors.success;
    final duration = animationsDisabled(context)
        ? Duration.zero
        : const Duration(milliseconds: 700);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: usedPercent),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        final fraction = (value / 100).clamp(0.0, 1.0);
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: size,
                height: size,
                child: CircularProgressIndicator(
                  value: fraction,
                  strokeWidth: 11,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                  strokeCap: StrokeCap.round,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${value.toStringAsFixed(1)}%',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Text(
                    'used',
                    style: TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
