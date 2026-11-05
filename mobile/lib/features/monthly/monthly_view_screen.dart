/// Monthly view: the whole month for the LOGGED-IN member — where
/// and how much they paid (per-category + per-expense), the month
/// total, and a weekly spending trend. All from the REAL recorded
/// expense history in AppState + live balances. With no recorded
/// history, honest empty states — never fake rows.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/money_text.dart';
import '../../domain/insights.dart';
import '../../domain/models.dart';
import '../../state/app_state.dart';
import '../home/insights_cards.dart';

class MonthlyViewScreen extends StatelessWidget {
  const MonthlyViewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final member = state.loggedInMember;
    final b = state.balances;
    final mine = member == null
        ? <ExpenseRecord>[]
        : state.recentExpenses.where((e) => e.payerId == member.id).toList();
    final paidTotal =
        mine.fold(0.0, (s, e) => s + (double.tryParse(e.amount) ?? 0));
    final weeks = weeklySpending(state.recentExpenses);
    final maxWeek =
        weeks.fold(0.0, (m, w) => w.total > m ? w.total : m);
    final hasTrend = maxWeek > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Monthly view')),
      body: ListView(
        padding: const EdgeInsets.all(SplitNestTheme.screenPadding),
        children: [
          if (b != null)
            Entrance(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('This month',
                          style: SplitNestTheme.sectionStyle),
                      const SizedBox(height: 12),
                      _Row(
                          label: 'Household spent',
                          value: 'PKR ${b.totalSpending}'),
                      const SizedBox(height: 8),
                      _Row(
                          label: 'Budget',
                          value: 'PKR ${b.budget}'),
                      const SizedBox(height: 8),
                      _Row(
                          label: 'Remaining',
                          value: 'PKR ${b.remaining}'),
                      const SizedBox(height: 8),
                      _Row(
                          label: 'You paid',
                          value:
                              'PKR ${paidTotal.toStringAsFixed(2)}'),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text('Weekly spending',
              style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          Entrance(
            delay: const Duration(milliseconds: 60),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: hasTrend
                    ? Column(
                        children: [
                          SizedBox(
                            height: 140,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: weeks
                                  .map((w) => Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 4),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: [
                                              Text(
                                                w.total > 0
                                                    ? w.total
                                                        .toStringAsFixed(0)
                                                    : '',
                                                style: SplitNestTheme
                                                    .supportingStyle,
                                              ),
                                              const SizedBox(height: 4),
                                              Container(
                                                height: w.total > 0
                                                    ? 8 +
                                                        72 *
                                                            (w.total /
                                                                maxWeek)
                                                    : 4,
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          4),
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(w.label,
                                                  style: SplitNestTheme
                                                      .supportingStyle),
                                            ],
                                          ),
                                        ),
                                      ))
                                  .toList(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'PKR per week, from recorded expenses',
                            style: SplitNestTheme.supportingStyle,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      )
                    : const Column(
                        children: [
                          EmptyStateIllustration(
                              kind: EmptyArtKind.receipt),
                          SizedBox(height: 8),
                          Text('No expenses recorded yet in this session',
                              style: SplitNestTheme.sectionStyle,
                              textAlign: TextAlign.center),
                        ],
                      ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Your spending by category',
              style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          Entrance(
            delay: const Duration(milliseconds: 120),
            child: CategoryBreakdownCard(expenses: mine),
          ),
          const SizedBox(height: 16),
          // Budgets: category caps + Danger Zone warnings live ONLY
          // here (no-overlap rule — not on Home, not in Expenses).
          // Caps are set per category from real recorded expenses;
          // the banner appears at 80%+ of a set cap.
          const Text('Budgets', style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          const CapDangerBanner(),
          const SizedBox(height: 8),
          Entrance(
            delay: const Duration(milliseconds: 180),
            child: const CategoryCapsCard(),
          ),
          const SizedBox(height: 16),
          const Text('Your expenses',
              style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          if (mine.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  children: [
                    EmptyStateIllustration(kind: EmptyArtKind.receipt),
                    SizedBox(height: 8),
                    Text('No expenses recorded yet in this session',
                        style: SplitNestTheme.sectionStyle,
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          else
            ...mine.map((e) => Card(
                  child: ListTile(
                    title: Text(e.title),
                    subtitle: Text('${e.category} · ${e.date ?? ''}'),
                    trailing: MoneyText(e.amount,
                        style: SplitNestTheme.bodyStyle
                            .copyWith(fontWeight: FontWeight.w700)),
                  ),
                )),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: Text(label, style: SplitNestTheme.supportingStyle)),
        Text(value,
            style: SplitNestTheme.bodyStyle
                .copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}
