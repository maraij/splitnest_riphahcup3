/// Ledger maths — pure functions, no widgets, no Firestore, no HTTP.
///
/// These are the exact rules the old Node backend enforced in
/// `backend/src/app.js` (computeBalances / monthSummary / settle
/// validation), now computed client-side from the Firestore data:
///
/// - All money is integer paisa; display strings are two-decimal.
/// - Net = Paid − Share + Sent − Received (worked-example formula).
/// - Total spending is the CURRENT MONTH's expenses only; the per-
///   member Paid/Share/Sent/Received rows are all-time.
/// - Settlements never change total spending.
/// - Budget status: used >= 84% → 'Near Limit'; >= 50% → 'On Track';
///   otherwise 'Under Budget' (backend monthSummary thresholds).
library;

import '../core/money.dart';
import 'models.dart';

/// Computes [Balances] from the group's recorded history.
///
/// [expenses] and [payments] are the full group history (newest
/// first or oldest first — order does not matter here). [budgetPaisa]
/// is the group's monthly budget in integer paisa (PKR 5,000 =
/// 500000). [now] is the reference month for total spending; it
/// defaults to [DateTime.now]. Expenses with no parseable date still
/// count in the per-member rows, but cannot be placed in a month, so
/// they do not count towards this month's total spending.
Balances computeBalances({
  required List<ExpenseRecord> expenses,
  required List<PaymentRecord> payments,
  required List<Member> members,
  required int budgetPaisa,
  DateTime? now,
}) {
  final ref = now ?? DateTime.now();
  final paid = <String, int>{for (final m in members) m.id: 0};
  final share = <String, int>{for (final m in members) m.id: 0};
  final sent = <String, int>{for (final m in members) m.id: 0};
  final received = <String, int>{for (final m in members) m.id: 0};
  var monthTotal = 0;

  for (final e in expenses) {
    final amount = parsePaisa(e.amount) ?? 0;
    paid[e.payerId] = (paid[e.payerId] ?? 0) + amount;
    for (final s in e.shares) {
      share[s.memberId] =
          (share[s.memberId] ?? 0) + (parsePaisa(s.amount) ?? 0);
    }
    final d = DateTime.tryParse(e.date ?? '');
    if (d != null && d.year == ref.year && d.month == ref.month) {
      monthTotal += amount;
    }
  }
  for (final p in payments) {
    // A rejected payment counts nowhere in any balance — the
    // sender's way to correct it is to record a new payment.
    if (p.status == 'rejected') continue;
    final amount = parsePaisa(p.amount) ?? 0;
    sent[p.senderId] = (sent[p.senderId] ?? 0) + amount;
    received[p.recipientId] = (received[p.recipientId] ?? 0) + amount;
  }

  final rows = members.map((m) {
    final net = (paid[m.id] ?? 0) -
        (share[m.id] ?? 0) +
        (sent[m.id] ?? 0) -
        (received[m.id] ?? 0);
    return BalanceRow(
      memberId: m.id,
      name: m.name,
      net: formatPaisa(net),
      paid: formatPaisa(paid[m.id] ?? 0),
      share: formatPaisa(share[m.id] ?? 0),
    );
  }).toList();

  final remaining = budgetPaisa - monthTotal;
  // Backend rounding: Math.round(total / limit * 10000) / 100.
  final usedPercent = budgetPaisa > 0
      ? (monthTotal / budgetPaisa * 10000).round() / 100
      : 0.0;
  final status = usedPercent >= 84
      ? 'Near Limit'
      : usedPercent >= 50
          ? 'On Track'
          : 'Under Budget';
  return Balances(
    rows: rows,
    totalSpending: formatPaisa(monthTotal),
    budget: formatPaisa(budgetPaisa),
    remaining: formatPaisa(remaining),
    usedPercent: usedPercent,
    status: status,
  );
}

/// Validates a settlement against live nets, exactly as the old
/// backend's POST /api/settle did. Returns a plain error message, or
/// null when the payment may be recorded.
///
/// [nets] maps member id → net in integer paisa (from
/// [computeBalances]). A payment counts in the ledger as soon as it
/// is recorded; verification (recorded → verified) does not change
/// the maths.
String? settlementError({
  required Map<String, int> nets,
  required String senderId,
  required String recipientId,
  required int amountPaisa,
}) {
  if (!nets.containsKey(senderId) || !nets.containsKey(recipientId)) {
    return 'Sender and recipient must be known members.';
  }
  if (senderId == recipientId) {
    return 'Sender and recipient must be different.';
  }
  if (amountPaisa <= 0) {
    return 'Settlement amount must be positive.';
  }
  final senderNet = nets[senderId]!;
  final recipientNet = nets[recipientId]!;
  if (senderNet >= 0) {
    return 'Sender does not owe money (not a debtor).';
  }
  if (recipientNet <= 0) {
    return 'Recipient is not owed money (not a creditor).';
  }
  if (amountPaisa > -senderNet || amountPaisa > recipientNet) {
    return 'Payment exceeds outstanding balance (sender owes '
        '${formatPaisa(-senderNet)}, recipient is owed '
        '${formatPaisa(recipientNet)}).';
  }
  return null;
}
