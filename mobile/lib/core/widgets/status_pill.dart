import 'package:flutter/material.dart';

import '../theme.dart';

/// Budget status pill: icon + text label, never colour alone.
/// Backend statuses: "Under Budget", "On Track", "Near Limit";
/// over 100% used is shown as "Over Budget".
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.status,
    required this.usedPercent,
  });

  final String status;
  final double usedPercent;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final over = usedPercent > 100;
    final label = over ? 'Over Budget' : status;
    final (Color color, IconData icon) = over
        ? (colors.error, Icons.warning_amber_rounded)
        : status == 'Near Limit'
            ? (colors.warning, Icons.trending_up_rounded)
            : status == 'On Track'
                ? (colors.success, Icons.check_circle_outline)
                : (colors.success, Icons.check_circle_outline);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
