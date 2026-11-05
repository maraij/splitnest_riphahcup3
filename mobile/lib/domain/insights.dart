/// Insights computed from the REAL recorded expense history in AppState
/// (session expenses + checkout-posted expenses tracked in state).
///
/// Pure functions — no widgets, no HTTP, no hardcoded benchmark numbers.
/// Every feature here returns an honest empty result when there is no
/// recorded history yet, instead of inventing values.
library;

import '../core/money.dart';
import 'models.dart';

double _amountOf(ExpenseRecord e) => double.tryParse(e.amount) ?? 0;

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

// ---------------------------------------------------------------------------
// 1. Category-wise spending breakdown
// ---------------------------------------------------------------------------

class CategorySlice {
  CategorySlice({
    required this.category,
    required this.total,
    required this.percent,
  });
  final String category;

  /// Total spent in this category, PKR.
  final double total;

  /// Share of all recorded spending, 0-100.
  final double percent;
}

/// Sums the recorded expenses by category, largest first.
/// Returns [] when there is no recorded history.
List<CategorySlice> categoryBreakdown(List<ExpenseRecord> expenses) {
  final totals = <String, double>{};
  for (final e in expenses) {
    totals[e.category] = (totals[e.category] ?? 0) + _amountOf(e);
  }
  final grandTotal = totals.values.fold(0.0, (a, b) => a + b);
  if (grandTotal <= 0) return [];
  final slices = totals.entries
      .map((e) => CategorySlice(
            category: e.key,
            total: e.value,
            percent: e.value / grandTotal * 100,
          ))
      .toList()
    ..sort((a, b) => b.total.compareTo(a.total));
  return slices;
}

// ---------------------------------------------------------------------------
// 2. Monthly summary: biggest expense + who paid the most
// ---------------------------------------------------------------------------

class MonthlySummary {
  MonthlySummary({required this.biggest, required this.topPayerId, required this.topPayerTotal});

  /// The single largest recorded expense, or null when none recorded.
  final ExpenseRecord? biggest;

  /// Member id who paid the most across the recorded history,
  /// or null when none recorded.
  final String? topPayerId;

  /// Total that member paid, PKR.
  final double topPayerTotal;
}

MonthlySummary monthlySummary(List<ExpenseRecord> expenses) {
  if (expenses.isEmpty) {
    return MonthlySummary(biggest: null, topPayerId: null, topPayerTotal: 0);
  }
  ExpenseRecord? biggest;
  final paidBy = <String, double>{};
  for (final e in expenses) {
    final amount = _amountOf(e);
    if (biggest == null || amount > _amountOf(biggest)) biggest = e;
    paidBy[e.payerId] = (paidBy[e.payerId] ?? 0) + amount;
  }
  String? topPayerId;
  var topTotal = 0.0;
  // First-seen member wins a tie, so the result is deterministic.
  for (final e in expenses) {
    final total = paidBy[e.payerId]!;
    if (topPayerId == null || total > topTotal) {
      topPayerId = e.payerId;
      topTotal = total;
    }
  }
  return MonthlySummary(
    biggest: biggest,
    topPayerId: topPayerId,
    topPayerTotal: topTotal,
  );
}

// ---------------------------------------------------------------------------
// 4. Recurring-bill reminder (Internet / Electricity)
// ---------------------------------------------------------------------------

class BillStatus {
  BillStatus({required this.key, required this.label, required this.paidExpense});
  final String key;
  final String label;

  /// The most recent matching expense recorded in the current month,
  /// or null when none was recorded yet.
  final ExpenseRecord? paidExpense;

  bool get isPaid => paidExpense != null;
}

/// For each monthly bill, finds the most recent expense whose title
/// mentions it and whose date falls in the current month. An expense
/// with no parseable date can never prove the bill was paid this
/// month, so it does not count — no fake paid states.
List<BillStatus> recurringBillStatus(
  List<ExpenseRecord> expenses, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  const bills = [
    ('internet', 'Internet'),
    ('electricity', 'Electricity'),
  ];
  return bills.map((bill) {
    final (keyword, label) = bill;
    ExpenseRecord? paid;
    // recentExpenses is newest-first, so the first match is the latest.
    for (final e in expenses) {
      if (!e.title.toLowerCase().contains(keyword)) continue;
      final d = _parseDate(e.date);
      if (d == null || d.year != current.year || d.month != current.month) {
        continue;
      }
      paid = e;
      break;
    }
    return BillStatus(key: keyword, label: label, paidExpense: paid);
  }).toList();
}

// ---------------------------------------------------------------------------
// 5. Quick-add favourites: most frequent expense titles
// ---------------------------------------------------------------------------

class FavouriteExpense {
  FavouriteExpense({
    required this.title,
    required this.category,
    required this.amount,
    required this.payerId,
    required this.splitType,
    required this.shares,
    required this.count,
  });
  final String title;
  final String category;

  /// Amount of the most recent occurrence, PKR as a string.
  final String amount;
  final String payerId;

  /// 'equal' or 'custom', from the most recent occurrence.
  final String splitType;

  /// Per-member shares of the most recent occurrence.
  final List<ExpenseShare> shares;

  /// How many times this title was recorded this session.
  final int count;

  /// Member ids sharing an equal split (from the shares).
  List<String> get splitMemberIds =>
      shares.map((s) => s.memberId).toList()..sort();

  /// Splits payload for re-adding a custom expense.
  List<Map<String, String>> get splitsPayload => shares
      .map((s) => {'member_id': s.memberId, 'amount': s.amount})
      .toList();
}

/// Most frequent titles in the recorded history, most frequent first
/// (ties: most recent first). Empty when there is no history —
/// favourites are never invented.
List<FavouriteExpense> quickAddFavourites(
  List<ExpenseRecord> expenses, {
  int limit = 3,
}) {
  final counts = <String, int>{};
  final latest = <String, ExpenseRecord>{};
  for (final e in expenses) {
    final key = e.title.trim().toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
    // recentExpenses is newest-first: the first seen is the latest.
    latest.putIfAbsent(key, () => e);
  }
  final favs = latest.entries.map((entry) {
    final e = entry.value;
    return FavouriteExpense(
      title: e.title,
      category: e.category,
      amount: e.amount,
      payerId: e.payerId,
      splitType: e.splitType ?? 'equal',
      shares: e.shares,
      count: counts[entry.key]!,
    );
  }).toList();
  // Most frequent first; on a tie the most recently recorded wins.
  // latest.values order is newest-first, so a stable sort keeps it.
  favs.sort((a, b) => b.count.compareTo(a.count));
  return favs.take(limit).toList();
}

/// Equal-split shares for a re-add, computed from the recorded amount
/// (remainder paisa in member-ID order, same rule as the backend).
List<ExpenseShare> equalSharesFor(String amount, List<String> memberIds) {
  final paisa = parsePaisa(amount) ?? 0;
  return equalSplit(paisa, memberIds)
      .map((s) => ExpenseShare(
            memberId: s.memberId,
            amount: formatPaisa(s.amountPaisa),
          ))
      .toList();
}

// ---------------------------------------------------------------------------
// Per-member view: every member's paid total, share total and expenses.
// ---------------------------------------------------------------------------

class MemberExpenseSummary {
  MemberExpenseSummary({
    required this.member,
    required this.totalPaid,
    required this.totalShare,
    required this.expenses,
  });
  final Member member;

  /// Sum of the amounts of expenses this member paid, PKR.
  final double totalPaid;

  /// Sum of this member's shares across ALL recorded expenses, PKR.
  final double totalShare;

  /// Expenses this member paid (newest first, as recorded).
  final List<ExpenseRecord> expenses;
}

/// One summary per member, in member order, from the recorded history.
/// A member with no expenses gets zeros and an empty list — never
/// invented rows. The household ledger is shared: every member sees
/// every other member's expenses.
List<MemberExpenseSummary> memberExpenseSummaries(
  List<ExpenseRecord> expenses,
  List<Member> members,
) {
  return members.map((m) {
    var paid = 0.0;
    var share = 0.0;
    final mine = <ExpenseRecord>[];
    for (final e in expenses) {
      if (e.payerId == m.id) {
        paid += _amountOf(e);
        mine.add(e);
      }
      for (final s in e.shares) {
        if (s.memberId == m.id) share += double.tryParse(s.amount) ?? 0;
      }
    }
    return MemberExpenseSummary(
      member: m,
      totalPaid: paid,
      totalShare: share,
      expenses: mine,
    );
  }).toList();
}

// ---------------------------------------------------------------------------
// 7. Weekly spending trend (current month, from dated expenses only).
// ---------------------------------------------------------------------------

class WeekBucket {
  WeekBucket({required this.label, required this.total});
  final String label;
  final double total;
}

/// Spending per week of the current month: days 1-7, 8-14, 15-21,
/// 22-28, 29-31. Only expenses with a parseable date in the current
/// month count — undated expenses cannot be bucketed honestly.
List<WeekBucket> weeklySpending(
  List<ExpenseRecord> expenses, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final totals = List<double>.filled(5, 0);
  for (final e in expenses) {
    final d = _parseDate(e.date);
    if (d == null || d.year != current.year || d.month != current.month) {
      continue;
    }
    final bucket = (d.day - 1) ~/ 7;
    totals[bucket] += _amountOf(e);
  }
  return [
    for (var i = 0; i < 5; i++)
      WeekBucket(label: 'Week ${i + 1}', total: totals[i]),
  ];
}

// ---------------------------------------------------------------------------
// 3. Per-category budget caps: spent per cap category.
// ---------------------------------------------------------------------------

/// Amount spent against one cap category, from the recorded history:
/// Grocery = Groceries category; Cleaning = Cleaning category;
/// Internet/Electricity = title match (they are Utilities in the app);
/// Dining/Snacks = their own categories.
double capSpent(List<ExpenseRecord> expenses, String capCategory) {
  var total = 0.0;
  for (final e in expenses) {
    final match = switch (capCategory) {
      'Grocery' => e.category == 'Groceries',
      'Cleaning' => e.category == 'Cleaning',
      'Internet' => e.title.toLowerCase().contains('internet'),
      'Electricity' => e.title.toLowerCase().contains('electricity'),
      'Dining' => e.category == 'Dining',
      'Snacks' => e.category == 'Snacks',
      _ => false,
    };
    if (match) total += _amountOf(e);
  }
  return total;
}

// ---------------------------------------------------------------------------
// 10. Receipt parser (REGEX only — no AI, no network).
// ---------------------------------------------------------------------------

class ParsedReceipt {
  ParsedReceipt({required this.title, required this.amount, this.date});

  /// Item name read from the receipt.
  final String title;

  /// Price in PKR.
  final double amount;

  /// Date read from the receipt, when one was present.
  final DateTime? date;
}

/// Reads a pasted receipt (WhatsApp/SMS text) into a title, a price
/// and an optional date. Recognised patterns:
/// - Price: a number with a `PKR` / `Rs` / `Rs.` marker next to it
///   ("PKR 1,250.00", "Rs. 850", "Total: Rs 370"), or a number on a
///   line containing "total"/"amount"/"bill", or a number with a
///   decimal part or thousands separator ("780.00", "1,250").
///   Bare small integers (quantities, "x2") are NOT prices.
///   Amount picked: the last price on a "total" line if there is one,
///   otherwise the largest price found (a receipt total is usually
///   the biggest number).
/// - Item name: the first non-total line that carries a price, with
///   the price, currency marker and quantity fragments ("x2", "2x",
///   "qty 2") stripped; otherwise the first line with letters that
///   is not a total/date line.
/// - Date: `dd/mm/yyyy`, `dd-mm-yyyy`, `yyyy-mm-dd`, or
///   `5 Nov 2026` style (day-first, as used in Pakistan).
/// Returns null when no price or no item name can be read — the
/// caller then shows "Could not read a price/item from this receipt"
/// and leaves the form EMPTY. Never invents data.
ParsedReceipt? parseReceipt(String text) {
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;

  DateTime? tryDate(int y, int m, int d) {
    if (y < 1900 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) {
      return null;
    }
    try {
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  const months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  DateTime? date;
  for (final line in lines) {
    final numeric = RegExp(r'(\d{1,2})[/-](\d{1,2})[/-](\d{4})')
        .firstMatch(line);
    if (numeric != null) {
      date = tryDate(
        int.parse(numeric.group(3)!),
        int.parse(numeric.group(2)!),
        int.parse(numeric.group(1)!),
      );
    }
    date ??= () {
      final iso = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(line);
      if (iso == null) return null;
      return tryDate(
        int.parse(iso.group(1)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(3)!),
      );
    }();
    date ??= () {
      final named = RegExp(
              r'(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{4})',
              caseSensitive: false)
          .firstMatch(line);
      if (named == null) return null;
      final m = months[named.group(2)!.toLowerCase()];
      if (m == null) return null;
      return tryDate(
        int.parse(named.group(3)!),
        m,
        int.parse(named.group(1)!),
      );
    }();
    if (date != null) break;
  }

  bool isTotalLine(String line) =>
      line.toLowerCase().contains('total') ||
      line.toLowerCase().contains('amount due') ||
      line.toLowerCase().contains('grand total');
  bool isDateLine(String line) =>
      RegExp(r'\d{1,2}[/-]\d{1,2}[/-]\d{4}').hasMatch(line) ||
      RegExp(r'\d{4}-\d{1,2}-\d{1,2}').hasMatch(line);

  // A price-looking number on one line: with a PKR/Rs marker, or on a
  // total/amount/bill line, or with a decimal / thousands separator.
  final moneyRe = RegExp(
    r'(?:PKR|Rs\.?)\s*(\d[\d,]*(?:\.\d{1,2})?)'
    r'|(\d[\d,]*(?:\.\d{1,2})?)\s*(?:PKR|Rs\.?)'
    r'|(\d[\d,]*\.\d{1,2})'
    r'|(\d{1,3}(?:,\d{3})+)',
    caseSensitive: false,
  );
  double? priceOnLine(String line) {
    final lower = line.toLowerCase();
    // Bare numbers count only on total/amount lines — a bare number on
    // any other line ("Bill No. 1234", a quantity, a date) is not a
    // price and must not be picked up.
    final isTotal = isTotalLine(line) || lower.contains('amount');
    final m = moneyRe.firstMatch(line);
    if (m != null) {
      final raw = m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4);
      if (raw != null) return double.tryParse(raw.replaceAll(',', ''));
    }
    if (isTotal) {
      final bare = RegExp(r'(\d[\d,]*(?:\.\d{1,2})?)').firstMatch(line);
      if (bare != null) {
        return double.tryParse(bare.group(1)!.replaceAll(',', ''));
      }
    }
    return null;
  }

  double? amount;
  for (final line in lines.where(isTotalLine)) {
    final p = priceOnLine(line);
    if (p != null) amount = p; // Last total line wins.
  }
  amount ??= () {
    double? best;
    for (final line in lines) {
      final p = priceOnLine(line);
      if (p != null && (best == null || p > best)) best = p;
    }
    return best;
  }();
  if (amount == null) return null;

  String cleanTitle(String line) {
    var t = line;
    t = t.replaceAll(moneyRe, '');
    t = t.replaceAll(RegExp(r'\b\d+\s*[xX]\b|\b[xX]\s*\d+\b'), '');
    t = t.replaceAll(RegExp(r'\bqty\s*\d+\b', caseSensitive: false), '');
    // Receipt words (not 'bill': "Internet Bill" is a real title).
    t = t.replaceAll(
        RegExp(r'\b(total|subtotal|grand total|amount|balance|change)\b',
            caseSensitive: false),
        '');
    // Trim BEFORE stripping trailing punctuation — the line ends in
    // a space after the price is removed ("Milk 2L - "), and the
    // punctuation strip only matches at the very end.
    t = t.trim();
    t = t.replaceAll(RegExp(r'[:\-–—,.]+$'), '').trim();
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t;
  }

  String? title;
  for (final line in lines) {
    if (isTotalLine(line) || isDateLine(line)) continue;
    if (priceOnLine(line) != null) {
      final cleaned = cleanTitle(line);
      if (cleaned.length >= 2) {
        title = cleaned;
        break;
      }
    }
  }
  title ??= () {
    for (final line in lines) {
      if (isTotalLine(line) || isDateLine(line)) continue;
      if (RegExp(r'[A-Za-z]').hasMatch(line)) {
        final cleaned = cleanTitle(line);
        if (cleaned.length >= 2) return cleaned;
      }
    }
    return null;
  }();
  if (title == null) return null;

  return ParsedReceipt(title: title, amount: amount, date: date);
}

// ---------------------------------------------------------------------------
// Month-over-month savings (celebration comparison)
// ---------------------------------------------------------------------------

/// A member's share of the recorded expenses for one calendar month
/// ([month] is any date in that month). Sums that member's split
/// shares — not what they paid — for expenses dated in that month.
double memberShareForMonth(
  List<ExpenseRecord> expenses,
  String memberId,
  DateTime month,
) {
  var total = 0.0;
  for (final e in expenses) {
    final d = _parseDate(e.date);
    if (d == null || d.year != month.year || d.month != month.month) {
      continue;
    }
    for (final s in e.shares) {
      if (s.memberId == memberId) {
        total += double.tryParse(s.amount) ?? 0;
      }
    }
  }
  return total;
}

/// Month-over-month improvement for [memberId]: last month's share
/// minus this month's share, in PKR. Returns the positive difference,
/// or null when no comparison can be computed — no expenses recorded
/// for last month, or this month's share is not smaller. Never invents
/// last-month figures: no history means no comparison line, no poppers.
double? monthOverMonthSavedFor(
  List<ExpenseRecord> expenses,
  String memberId, {
  DateTime? now,
}) {
  final ref = now ?? DateTime.now();
  // DateTime normalises month 0 (January) to December of last year.
  final last = DateTime(ref.year, ref.month - 1);
  final lastShare = memberShareForMonth(expenses, memberId, last);
  if (lastShare <= 0) return null; // no previous-month history
  final thisShare = memberShareForMonth(expenses, memberId, ref);
  final diff = lastShare - thisShare;
  return diff > 0 ? diff : null;
}
