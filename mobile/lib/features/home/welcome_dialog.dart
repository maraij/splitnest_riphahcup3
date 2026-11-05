import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/models.dart';
import '../../core/widgets/member_avatar.dart';

/// Welcome popup, shown on Home once per login session (after balances
/// have loaded, so the balance line is never a wrong/zero guess).
/// Theme-primary header area, themed body, gold divider.
/// Dismissed with "Got it".
Future<void> showWelcomeDialog(
  BuildContext context, {
  required Member member,
  required BalanceRow balance,
}) {
  final colors = StatusColors.of(context);
  final net = double.tryParse(balance.net) ?? 0;
  final (String line, Color color) = net > 0
      ? ('You are owed PKR ${balance.net}', colors.success)
      : net < 0
          ? (
              'You owe PKR ${balance.net.replaceFirst('-', '')}',
              colors.error,
            )
          : ('Settled up — PKR 0.00', colors.success);
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.primary,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(SplitNestTheme.cardRadius),
              ),
            ),
            child: Column(
              children: [
                Text(
                  'Welcome to SplitNest',
                  style: SplitNestTheme.titleStyle.copyWith(
                    color: Theme.of(ctx).colorScheme.onPrimary,
                    fontSize: 20,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Container(
                  width: 48,
                  height: 4,
                  decoration: BoxDecoration(
                    color: SplitNestTheme.goldAccent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                MemberAvatar(
                  memberId: member.id,
                  name: member.name,
                  radius: 32,
                ),
                const SizedBox(height: 12),
                Text(
                  'You are using SplitNest as ${member.name} (${member.id})',
                  style: SplitNestTheme.sectionStyle,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  line,
                  style: SplitNestTheme.bodyStyle.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
