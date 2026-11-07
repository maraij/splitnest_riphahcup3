/// Home insight cards — all computed from LIVE balances and the REAL
/// recorded expense history in AppState. No hardcoded numbers anywhere:
/// with no recorded history each card shows an honest empty state.
library;

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../domain/insights.dart';
import '../../domain/models.dart';
import '../../state/app_state.dart';
import 'package:splitnest/core/widgets/entrance.dart';

// ---------------------------------------------------------------------------
// 6. Budget alert: >=80% Near Limit warning, >=100% Budget exceeded.
// ---------------------------------------------------------------------------

class BudgetAlertBanner extends StatelessWidget {
  const BudgetAlertBanner({super.key, required this.balances});
  final Balances balances;

  @override
  Widget build(BuildContext context) {
    final used = balances.usedPercent;
    if (used < 80) return const SizedBox.shrink();
    final exceeded = used >= 100;
    final colors = StatusColors.of(context);
    final color = exceeded ? colors.error : colors.warning;
    final background = exceeded
        ? colors.error.withValues(alpha: 0.12)
        : colors.warning.withValues(alpha: 0.12);
    return Entrance(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: background,
          borderRadius:
              BorderRadius.circular(SplitNestTheme.cardRadius),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              exceeded
                  ? Icons.error_outline_rounded
                  : Icons.warning_amber_rounded,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    exceeded ? 'Budget exceeded' : 'Near Limit',
                    style: SplitNestTheme.bodyStyle.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    exceeded
                        ? 'You have used ${used.toStringAsFixed(1)}% of the monthly budget (PKR ${balances.totalSpending} of PKR ${balances.budget}).'
                        : 'You have used ${used.toStringAsFixed(1)}% of the monthly budget (PKR ${balances.remaining} left).',
                    style: SplitNestTheme.supportingStyle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Category-wise spending breakdown (bars over the recorded history).
// ---------------------------------------------------------------------------

class CategoryBreakdownCard extends StatelessWidget {
  const CategoryBreakdownCard({super.key, required this.expenses});
  final List<ExpenseRecord> expenses;

  @override
  Widget build(BuildContext context) {
    final slices = categoryBreakdown(expenses);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Spending by category',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 12),
            if (slices.isEmpty)
              const Text(
                'No expenses recorded yet',
                style: SplitNestTheme.supportingStyle,
              )
            else
              ...slices.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              categoryIcons[s.category] ??
                                  Icons.receipt_long,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                s.category,
                                style: SplitNestTheme.bodyStyle.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            Text(
                              'PKR ${s.total.toStringAsFixed(2)} · ${s.percent.toStringAsFixed(0)}%',
                              style: SplitNestTheme.bodyStyle.copyWith(
                                  fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: s.percent / 100,
                            minHeight: 8,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                          ),
                        ),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Monthly summary: live totals + biggest expense + who paid the most.
// ---------------------------------------------------------------------------

class MonthlySummaryCard extends StatelessWidget {
  const MonthlySummaryCard({
    super.key,
    required this.balances,
    required this.expenses,
    required this.members,
  });
  final Balances balances;
  final List<ExpenseRecord> expenses;
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    final summary = monthlySummary(expenses);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Monthly summary',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 12),
            _SummaryRow(
              label: 'Total spent',
              value: 'PKR ${balances.totalSpending}',
            ),
            const SizedBox(height: 8),
            _SummaryRow(
              label: 'Remaining',
              value: 'PKR ${balances.remaining}',
            ),
            const SizedBox(height: 8),
            _SummaryRow(
              label: 'Biggest expense',
              value: summary.biggest == null
                  ? '—'
                  : '${summary.biggest!.title} — PKR ${summary.biggest!.amount}',
            ),
            const SizedBox(height: 8),
            _SummaryRow(
              label: 'Paid the most',
              value: summary.topPayerId == null
                  ? '—'
                  : '${memberName(members, summary.topPayerId!)} — PKR ${summary.topPayerTotal.toStringAsFixed(2)}',
            ),
            if (expenses.isEmpty) ...[
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: SplitNestTheme.supportingStyle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            style: SplitNestTheme.bodyStyle
                .copyWith(fontWeight: FontWeight.w700),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Recurring-bill reminder: Internet / Electricity, paid vs due.
// ---------------------------------------------------------------------------

class RecurringBillsCard extends StatelessWidget {
  const RecurringBillsCard({super.key, required this.expenses});
  final List<ExpenseRecord> expenses;

  @override
  Widget build(BuildContext context) {
    final bills = recurringBillStatus(expenses);
    final colors = StatusColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Monthly bills', style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 12),
            ...bills.map((bill) {
              final paid = bill.paidExpense;
              final dateText = paid?.date != null
                  ? () {
                      final d = DateTime.tryParse(paid!.date!);
                      return d == null ? paid.date! : formatDate(d);
                    }()
                  : '';
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      bill.isPaid
                          ? Icons.check_circle_outline
                          : Icons.schedule_outlined,
                      color:
                          bill.isPaid ? colors.success : colors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        bill.label,
                        style: SplitNestTheme.bodyStyle.copyWith(
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      bill.isPaid
                          ? 'Paid — PKR ${paid!.amount} · $dateText'
                          : 'Due monthly',
                      style: SplitNestTheme.supportingStyle.copyWith(
                        color: bill.isPaid ? colors.success : colors.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Per-category budget caps (Danger Zone at 80%+ of a cap).
// ---------------------------------------------------------------------------

/// Category caps card: one row per cap category. Only categories
/// WITH a cap show a progress bar; unset categories show 'No cap set'
/// with a Set cap action. Caps are user-set and persisted locally;
/// nothing here is a default presented as the user's choice.
/// Danger Zone banner: prominent warning when ANY set category cap is
/// at 80%+ of its spend (error styling at 100%+). Renders nothing when
/// no cap is set or all caps are under 80%. Spent comes from the REAL
/// recorded expense history via [capSpent]; caps are user-set only
/// (unset = no bar, no alert).
class CapDangerBanner extends StatelessWidget {
  const CapDangerBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final colors = StatusColors.of(context);
    final breached = <({String category, double spent, double cap, double pct})>[];
    for (final cat in capCategories) {
      final capPaisa = state.categoryCaps[cat];
      if (capPaisa == null || capPaisa <= 0) continue;
      final spent = capSpent(state.recentExpenses, cat);
      final cap = capPaisa / 100;
      final pct = spent / cap * 100;
      if (pct >= 80) breached.add((category: cat, spent: spent, cap: cap, pct: pct));
    }
    if (breached.isEmpty) return const SizedBox.shrink();
    final over = breached.any((b) => b.pct >= 100);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (over ? colors.error : colors.warning).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
        border: Border.all(
          color: (over ? colors.error : colors.warning).withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            over ? Icons.error_outline : Icons.warning_amber_rounded,
            color: over ? colors.error : colors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  over ? 'Over a category cap' : 'Near a category cap',
                  style: SplitNestTheme.bodyStyle.copyWith(
                    fontWeight: FontWeight.w700,
                    color: over ? colors.error : colors.warning,
                  ),
                ),
                const SizedBox(height: 4),
                for (final b in breached)
                  Text(
                    '${b.category}: PKR ${b.spent.toStringAsFixed(2)} of PKR ${b.cap.toStringAsFixed(2)} (${b.pct.toStringAsFixed(0)}%)',
                    style: SplitNestTheme.supportingStyle.copyWith(
                      color: b.pct >= 100 ? colors.error : colors.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CategoryCapsCard extends StatelessWidget {
  const CategoryCapsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final expenses = state.recentExpenses;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Category caps', style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 12),
            ...capCategories.map((cat) {
              final capPaisa = state.categoryCaps[cat];
              final spent = capSpent(expenses, cat);
              final colors = StatusColors.of(context);
              final pct = capPaisa == null || capPaisa <= 0
                  ? 0.0
                  : spent / (capPaisa / 100) * 100;
              final danger = capPaisa != null && pct >= 80;
              final over = capPaisa != null && pct >= 100;
              final barColor = over
                  ? colors.error
                  : danger
                      ? colors.warning
                      : Theme.of(context).colorScheme.primary;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            cat,
                            style: SplitNestTheme.bodyStyle
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          capPaisa == null
                              ? 'No cap set'
                              : 'PKR ${spent.toStringAsFixed(2)} of PKR ${(capPaisa / 100).toStringAsFixed(2)} · ${pct.toStringAsFixed(0)}%',
                          style: SplitNestTheme.supportingStyle.copyWith(
                            color: over
                                ? colors.error
                                : danger
                                    ? colors.warning
                                    : null,
                            fontWeight:
                                danger ? FontWeight.w700 : null,
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: () =>
                              _editCap(context, state, cat, capPaisa),
                          child: Text(capPaisa == null ? 'Set cap' : 'Edit'),
                        ),
                      ],
                    ),
                    if (capPaisa != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (pct / 100).clamp(0.0, 1.0),
                          minHeight: 8,
                          color: barColor,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _editCap(BuildContext context, AppState state,
      String category, int? currentPaisa) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _CapDialog(category: category, currentPaisa: currentPaisa),
    );
    if (action == 'clear') {
      await state.clearCategoryCap(category);
    } else if (action != null && action.startsWith('save:')) {
      final paisa = int.tryParse(action.substring(5));
      if (paisa != null) await state.setCategoryCap(category, paisa);
    }
  }
}

/// Cap edit dialog. Owns its TextEditingController and disposes it in
/// its own dispose() — disposing a controller right after showDialog
/// returns crashes, because the dialog is still animating out and its
/// TextField is rebuilt with the disposed controller.
class _CapDialog extends StatefulWidget {
  const _CapDialog({required this.category, required this.currentPaisa});
  final String category;
  final int? currentPaisa;

  @override
  State<_CapDialog> createState() => _CapDialogState();
}

class _CapDialogState extends State<_CapDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentPaisa == null
        ? ''
        : (widget.currentPaisa! / 100).toStringAsFixed(2),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Cap for ${widget.category}'),
      content: TextField(
        controller: _controller,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
        decoration:
            const InputDecoration(labelText: 'Monthly cap (PKR)'),
      ),
      actions: [
        if (widget.currentPaisa != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop('clear'),
            child: const Text('Remove cap'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final paisa = parsePaisa(_controller.text.trim());
            if (paisa == null || paisa <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Enter a positive amount.')));
              return;
            }
            Navigator.of(context).pop('save:$paisa');
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
