import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/models.dart';
import '../../state/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets/budget_ring.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/member_avatar.dart';
import '../../core/widgets/money_text.dart';
import '../../core/widgets/status_pill.dart';
import 'celebration_dialog.dart';
import 'insights_cards.dart';
import 'welcome_dialog.dart';

/// Home tab: circular Monthly Budget ring in the centre, the logged-in
/// member's balance card, an Active Members card and a Pending
/// Shopping card (tap to open the Shopping tab).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.onGoToShopping, this.onGoToMonthly});

  /// Called when the Pending Shopping card is tapped.
  final VoidCallback? onGoToShopping;

  /// Called when the celebration's "View monthly summary" is tapped.
  final VoidCallback? onGoToMonthly;

  /// Shows the savings celebration once per login, if it applies.
  /// Called only AFTER the welcome popup has been dismissed (never
  /// stacked with it) — or directly when the welcome popup is not
  /// pending. Guards in AppState stop it showing twice.
  void _maybeShowCelebration(BuildContext context, AppState state) {
    if (!state.shouldShowCelebration) {
      state.clearCelebrationPending();
      return;
    }
    final member = state.loggedInMember;
    final saved = state.celebrationSavedAmount;
    if (member == null || saved == null) {
      state.clearCelebrationPending();
      return;
    }
    state.markCelebrationShown();
    showCelebrationDialog(
      context,
      member: member,
      savedAmount: saved,
      // MoM comparison: null when there is no last-month history
      // or no improvement — then the dialog shows the normal
      // celebration with no comparison line and no poppers.
      monthOverMonthSaved: state.monthOverMonthSaved,
      onViewMonthly: () => onGoToMonthly?.call(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // Welcome popup, once per login: scheduled after the first frame
    // once balances have loaded (so the balance line is always right).
    // The store's scheduling guard stops a rebuild from queueing it
    // twice; the store's shown-flag stops it on tab switches, rebuilds
    // and pull-to-refresh. A new login re-arms it.
    // Celebration: shown AFTER the welcome popup is dismissed (never
    // stacked), only when the member saved money this month.
    if (state.shouldShowWelcome) {
      state.markWelcomeScheduled();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!context.mounted) {
          state.clearWelcomePending();
          return;
        }
        final member = state.loggedInMember;
        final balance = state.activeBalance;
        if (member == null || balance == null) {
          state.clearWelcomePending();
          return;
        }
        state.markWelcomeShown();
        await showWelcomeDialog(context, member: member, balance: balance);
        if (!context.mounted) return;
        _maybeShowCelebration(context, state);
      });
    } else if (state.shouldShowCelebration) {
      state.markCelebrationScheduled();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          state.clearCelebrationPending();
          return;
        }
        _maybeShowCelebration(context, state);
      });
    }
    final b = state.balances;
    final active = state.activeBalance;
    final net = active == null ? null : double.tryParse(active.net) ?? 0;
    final isOwed = net != null && net > 0;
    final isOwing = net != null && net < 0;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final spent = double.tryParse(b?.totalSpending ?? '0') ?? 0;
    final pendingItems =
        state.shopping.where((i) => i.isPending).toList();

    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView(
        padding: const EdgeInsets.all(SplitNestTheme.screenPadding),
        children: [
          // Branded header.
          Entrance(
            child: Card(
              color: theme.colorScheme.primary,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'assets/splitnest-logo-v3.webp',
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SplitNest',
                            style: SplitNestTheme.titleStyle.copyWith(
                              color: theme.colorScheme.onPrimary,
                            ),
                          ),
                          Text(
                            'Shared living · Ali, Ayesha & Bilal · Lahore',
                            style: SplitNestTheme.supportingStyle.copyWith(
                              color: theme.colorScheme.onPrimary
                                  .withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (state.errorMessage != null) ...[
            ErrorBanner(
              message: state.errorMessage!,
              onDismiss: state.clearError,
              onRetry: state.refresh,
            ),
            const SizedBox(height: 16),
          ],
          if (state.isLoading && b == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (b == null && !state.isLoading && state.errorMessage == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.cloud_off_outlined, size: 40),
                    SizedBox(height: 8),
                    Text(
                      'Could not load the household.',
                      style: SplitNestTheme.sectionStyle,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          if (b != null) ...[
            // Logged-in member display (set at login; changed via
            // Log out + picking a member again).
            if (state.loggedInMember != null)
              Entrance(
                delay: const Duration(milliseconds: 60),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        MemberAvatar(
                          memberId: state.loggedInMember!.id,
                          name: state.loggedInMember!.name,
                          radius: 24,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Logged in as',
                                style: SplitNestTheme.supportingStyle,
                              ),
                              Text(
                                state.loggedInMember!.name,
                                style: SplitNestTheme.sectionStyle,
                              ),
                              Text(
                                '${state.loggedInMember!.id} · Roommate',
                                style: SplitNestTheme.supportingStyle,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            // Budget alert: Near Limit at >=80%, Budget exceeded at
            // >=100% — from LIVE balances, never hardcoded.
            // (House-level alert only. Category-cap warnings live
            // ONLY in Monthly view > Budgets — no-overlap rule.)
            BudgetAlertBanner(balances: b),
            const SizedBox(height: 16),
            // Monthly Budget ring, centred.
            Entrance(
              delay: const Duration(milliseconds: 120),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text(
                        'Monthly Budget',
                        style: SplitNestTheme.sectionStyle,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      BudgetRing(
                        usedPercent: b.usedPercent,
                        size: 168,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Spent PKR ${b.totalSpending} of PKR ${b.budget}',
                        style: SplitNestTheme.bodyStyle.copyWith(
                            fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'PKR ${b.remaining} remaining',
                        style: SplitNestTheme.supportingStyle,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      StatusPill(
                        status: b.status,
                        usedPercent: b.usedPercent,
                      ),
                      if (spent == 0) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'No spending yet this month',
                          style: SplitNestTheme.supportingStyle,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Active-member balance card.
            if (active != null)
              Entrance(
                delay: const Duration(milliseconds: 180),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            MemberAvatar(
                              memberId: active.memberId,
                              name: active.name,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '${active.name} — net balance',
                                style: SplitNestTheme.sectionStyle,
                              ),
                            ),
                            Icon(
                              isOwed
                                  ? Icons.trending_up_rounded
                                  : isOwing
                                      ? Icons.trending_down_rounded
                                      : Icons.check_circle_outline,
                              color: isOwed
                                  ? colors.success
                                  : isOwing
                                      ? colors.error
                                      : colors.success,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          isOwed
                              ? 'You are owed PKR ${active.net}'
                              : isOwing
                                  ? 'You owe PKR ${active.net.replaceFirst('-', '')}'
                                  : 'Settled up — PKR 0.00',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: isOwed
                                ? colors.success
                                : isOwing
                                    ? colors.error
                                    : null,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _Stat(
                                label: 'Paid',
                                value: 'PKR ${active.paid}',
                                icon: Icons.payments_outlined,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _Stat(
                                label: 'Share owed',
                                value: 'PKR ${active.share}',
                                icon: Icons.receipt_outlined,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            const Text('Active Members', style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Entrance(
              delay: const Duration(milliseconds: 240),
              child: Card(
                child: Column(
                  children: [
                    for (var i = 0; i < b.rows.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: 72),
                      _BalanceRow(
                        row: b.rows[i],
                        isActive:
                            b.rows[i].memberId == state.activeMemberId,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Pending Shopping',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Entrance(
              delay: const Duration(milliseconds: 300),
              child: Card(
                child: InkWell(
                  onTap: onGoToShopping,
                  borderRadius:
                      BorderRadius.circular(SplitNestTheme.cardRadius),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.shopping_basket_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                state.pendingCount == 0
                                    ? 'No pending shopping items'
                                    : '${state.pendingCount} pending shopping item(s)',
                                style: SplitNestTheme.bodyStyle.copyWith(
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                            const Icon(Icons.arrow_forward_ios_rounded,
                                size: 16),
                          ],
                        ),
                        if (pendingItems.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ...pendingItems.take(2).map((item) => Padding(
                                padding:
                                    const EdgeInsets.only(top: 4),
                                child: Text(
                                  '${item.title} (${item.unit} × ${item.requestedQty})',
                                  style: SplitNestTheme.supportingStyle,
                                ),
                              )),
                          if (pendingItems.length > 2)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '+${pendingItems.length - 2} more',
                                style: SplitNestTheme.supportingStyle,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Entrance(
              delay: const Duration(milliseconds: 360),
              child: CategoryBreakdownCard(expenses: state.recentExpenses),
            ),
            const SizedBox(height: 16),
            Entrance(
              delay: const Duration(milliseconds: 420),
              child: MonthlySummaryCard(
                balances: b,
                expenses: state.recentExpenses,
                members: state.members,
              ),
            ),
            const SizedBox(height: 16),
            Entrance(
              delay: const Duration(milliseconds: 480),
              child: RecurringBillsCard(expenses: state.recentExpenses),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Practice build · API: ${state.apiBaseUrl} · Password login enabled.',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: SplitNestTheme.supportingStyle),
                Text(
                  value,
                  style: SplitNestTheme.bodyStyle
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BalanceRow extends StatelessWidget {
  const _BalanceRow({required this.row, required this.isActive});
  final BalanceRow row;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final net = double.tryParse(row.net) ?? 0;
    final (String label, IconData icon, Color color) = net > 0
        ? ('is owed', Icons.arrow_downward_rounded, colors.success)
        : net < 0
            ? ('owes', Icons.arrow_upward_rounded, colors.error)
            : ('settled up', Icons.check_circle_outline, colors.success);
    return ListTile(
      leading: MemberAvatar(memberId: row.memberId, name: row.name),
      title: Text(
        '${row.name}${isActive ? ' (you)' : ''}',
        style: SplitNestTheme.bodyStyle.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        net == 0 ? 'Settled up' : '${row.name} $label',
        style: SplitNestTheme.supportingStyle,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 4),
          MoneyText(
            row.net.replaceFirst('-', ''),
            style: SplitNestTheme.bodyStyle.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
            semanticLabel:
                '${row.name} $label PKR ${row.net.replaceFirst('-', '')}',
          ),
        ],
      ),
    );
  }
}
