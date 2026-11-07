/// Household context for the AI chatbot (Phase 7).
///
/// Pure functions, no widgets, no HTTP. The context is built from
/// the LIVE AppState data (totals, balances, budget usage, recent
/// expenses) and handed to the provider with every message, so the
/// bot answers from real figures. The system prompt forbids
/// inventing figures: when data is missing the bot must say so.
library;

import '../../../domain/models.dart';

/// The system prompt for the SplitNest household expense assistant.
///
/// The bot answers ONLY from the household context supplied with
/// each message. It must never invent a financial figure, a balance,
/// an expense or a date — if the context does not contain the
/// answer, it says so plainly and suggests where to look in the app.
const String chatbotSystemPrompt = '''
You are the SplitNest household expense assistant for three
roommates (Ali, Ayesha and Bilal) who share living expenses in
Pakistani rupees (PKR). You answer questions about their household
spending, balances and budget.

Rules you must follow:
- Answer ONLY from the household summary supplied with each
  question. Every figure you quote must appear in that summary.
- NEVER invent a financial figure, balance, expense, date or
  settlement. If the summary does not contain the answer, say so
  plainly ("I don't have that in your household data") and suggest
  where to check in the app instead of guessing.
- Amounts are in PKR with two decimals. A positive net balance
  means the member is owed money; a negative net means they owe.
- Keep answers short and practical. Suggest at most one next step
  (for example, who should settle with whom, using the balances).
- You cannot change, add or delete any expense, payment or setting.
  If asked to do that, explain how to do it in the app.
''';

/// Builds the household summary handed to the AI with every
/// message. All figures come from the live household data passed
/// in — nothing here is guessed or hardcoded.
///
/// When [balances] is null (no household loaded yet) the summary
/// says so explicitly, so the bot reports the gap instead of
/// inventing numbers. [recentExpenses] are listed newest first,
/// at most [recentCount] of them.
String buildHouseholdContext({
  required String memberName,
  required Balances? balances,
  required List<ExpenseRecord> recentExpenses,
  int recentCount = 5,
}) {
  final lines = <String>[
    'Household summary for SplitNest (shared living, PKR).',
    'Logged in as $memberName.',
  ];
  final b = balances;
  if (b == null) {
    lines.add(
      'No household data is loaded yet — no totals, balances or '
      'expenses are available. Do not invent any figures; tell the '
      'user the household has not loaded and suggest reopening the '
      'app or signing in again.',
    );
    return lines.join('\n');
  }
  lines.add(
    'Monthly budget: PKR ${b.budget}. '
    'Total spent this month: PKR ${b.totalSpending} '
    '(${b.usedPercent.toStringAsFixed(0)}% used, status: ${b.status}). '
    'Remaining: PKR ${b.remaining}.',
  );
  lines.add('Balances (net = paid - share + sent - received):');
  for (final row in b.rows) {
    lines.add(
      '- ${row.name}: net PKR ${row.net} '
      '(paid PKR ${row.paid}, share PKR ${row.share}).',
    );
  }
  if (recentExpenses.isEmpty) {
    lines.add('Recent expenses: none recorded yet.');
  } else {
    lines.add('Recent expenses (newest first):');
    for (final e in recentExpenses.take(recentCount)) {
      lines.add(
        '- ${e.title}: PKR ${e.amount}, paid by ${e.payerId}'
        '${e.date == null ? '' : ' on ${e.date}'} (${e.category}).',
      );
    }
  }
  return lines.join('\n');
}
