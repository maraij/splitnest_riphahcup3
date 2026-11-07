/// Per-member payment tracking + the payment status state machine —
/// pure functions, no widgets, no Firestore.
///
/// Two balances exist in this app, deliberately, and the UI must
/// never blur them:
///
/// - The **ledger preview** (`computeBalances` in balances.dart)
///   counts a payment as soon as it is `recorded`, so the sender
///   sees the effect immediately. That is the Phase 3 rule and it
///   is unchanged.
/// - The **settled balance** here counts only `verified` payments.
///   A `recorded` payment is shown as *pending* — it does not move
///   the settled balance, and the UI must never display it as
///   confirmed. A `rejected` payment counts nowhere.
///
/// [MemberPaymentSummary] is the per-member view built on the
/// settled balance: total owed (share), total paid (expenses paid),
/// verified/pending settlements sent and received, the remaining
/// settled balance, the status (`settled` / `owes` / `owed`), the
/// monthly contribution, and that member's payment history.
library;

import '../core/money.dart';
import 'models.dart';

/// The user-facing label for a payment status. An unverified payment
/// is always labelled as awaiting verification — never as confirmed.
String paymentStatusLabel(String status) => switch (status) {
      'verified' => 'Verified',
      'rejected' => 'Rejected — not counted as settled',
      _ => 'Recorded — awaiting verification',
    };

/// Validates a payment status transition. Returns a plain error
/// message, or null when the transition may proceed.
///
/// - `recorded → verified`: owner/admin only.
/// - `recorded → rejected`: owner/admin only.
/// - Everything else is forbidden: a verified payment can never be
///   un-verified, a rejected payment can never be verified (record a
///   new payment instead — that is the correctable path), and a
///   payment can never move backwards.
String? paymentStatusTransitionError({
  required String current,
  required String target,
  required bool isAdmin,
}) {
  if (current != 'recorded') {
    return 'This payment is already $current and cannot be changed.';
  }
  if (target != 'verified' && target != 'rejected') {
    return 'A recorded payment can only be verified or rejected.';
  }
  if (!isAdmin) {
    return 'Only the household owner or an admin can $target a payment.';
  }
  return null;
}

class MemberPaymentSummary {
  MemberPaymentSummary({
    required this.member,
    required this.totalOwedPaisa,
    required this.totalPaidPaisa,
    required this.sentVerifiedPaisa,
    required this.sentPendingPaisa,
    required this.receivedVerifiedPaisa,
    required this.receivedPendingPaisa,
    required this.remainingPaisa,
    required this.status,
    required this.monthlyContributionPaisa,
    required this.monthlyPaidPaisa,
    required this.monthlySharePaisa,
    required this.payments,
  });
  final Member member;

  /// Sum of this member's shares across all expenses (what they owe
  /// in total), integer paisa.
  final int totalOwedPaisa;

  /// Sum of the expenses this member paid for, integer paisa.
  final int totalPaidPaisa;

  /// Verified settlements this member sent / received.
  final int sentVerifiedPaisa;
  final int receivedVerifiedPaisa;

  /// Recorded-but-unverified settlements sent / received — shown as
  /// pending, never counted in [remainingPaisa].
  final int sentPendingPaisa;
  final int receivedPendingPaisa;

  /// Settled balance (verified payments only):
  /// Paid − Owed + Sent(verified) − Received(verified).
  /// > 0: the household owes them; < 0: they owe; 0: settled.
  final int remainingPaisa;

  /// 'settled' | 'owes' | 'owed', from [remainingPaisa].
  final String status;

  /// This month's contribution: expenses paid this month + verified
  /// settlements sent this month, integer paisa.
  final int monthlyContributionPaisa;

  /// This month's expenses paid / share, integer paisa.
  final int monthlyPaidPaisa;
  final int monthlySharePaisa;

  /// True when this member has a recorded-but-unverified payment
  /// either way (sent or received).
  bool get hasPending => sentPendingPaisa > 0 || receivedPendingPaisa > 0;

  /// Every payment this member sent or received, newest first.
  final List<PaymentRecord> payments;
}

/// One member's slice of the payment ledger, in member order.
/// Payments with an unknown status are treated as `recorded`
/// (pending) — never silently as verified.
List<MemberPaymentSummary> memberPaymentSummaries({
  required List<ExpenseRecord> expenses,
  required List<PaymentRecord> payments,
  required List<Member> members,
  DateTime? now,
}) {
  final ref = now ?? DateTime.now();
  return members.map((m) {
    var owed = 0;
    var paid = 0;
    var sentVerified = 0;
    var sentPending = 0;
    var receivedVerified = 0;
    var receivedPending = 0;
    var monthlyPaid = 0;
    var monthlyShare = 0;
    var monthlySentVerified = 0;
    final mine = <PaymentRecord>[];
    for (final e in expenses) {
      final amount = parsePaisa(e.amount) ?? 0;
      if (e.payerId == m.id) paid += amount;
      for (final s in e.shares) {
        if (s.memberId == m.id) owed += parsePaisa(s.amount) ?? 0;
      }
      final d = DateTime.tryParse(e.date ?? '');
      if (d != null && d.year == ref.year && d.month == ref.month) {
        if (e.payerId == m.id) monthlyPaid += amount;
        for (final s in e.shares) {
          if (s.memberId == m.id) {
            monthlyShare += parsePaisa(s.amount) ?? 0;
          }
        }
      }
    }
    for (final p in payments) {
      final amount = parsePaisa(p.amount) ?? 0;
      final isSender = p.senderId == m.id;
      final isRecipient = p.recipientId == m.id;
      if (!isSender && !isRecipient) continue;
      mine.add(p);
      final created = p.createdAt;
      final inMonth = created != null &&
          created.year == ref.year &&
          created.month == ref.month;
      if (p.status == 'verified') {
        if (isSender) {
          sentVerified += amount;
          if (inMonth) monthlySentVerified += amount;
        }
        if (isRecipient) receivedVerified += amount;
      } else if (p.status == 'rejected') {
        // Rejected counts nowhere — not in any total.
      } else {
        // 'recorded' (and any unknown status): pending only.
        if (isSender) sentPending += amount;
        if (isRecipient) receivedPending += amount;
      }
    }
    mine.sort((a, b) {
      final ca = a.createdAt;
      final cb = b.createdAt;
      if (ca == null && cb == null) return b.id.compareTo(a.id);
      if (ca == null) return 1;
      if (cb == null) return -1;
      return cb.compareTo(ca);
    });
    final remaining = paid - owed + sentVerified - receivedVerified;
    return MemberPaymentSummary(
      member: m,
      totalOwedPaisa: owed,
      totalPaidPaisa: paid,
      sentVerifiedPaisa: sentVerified,
      sentPendingPaisa: sentPending,
      receivedVerifiedPaisa: receivedVerified,
      receivedPendingPaisa: receivedPending,
      remainingPaisa: remaining,
      status: remaining > 0
          ? 'owed'
          : remaining < 0
              ? 'owes'
              : 'settled',
      monthlyContributionPaisa: monthlyPaid + monthlySentVerified,
      monthlyPaidPaisa: monthlyPaid,
      monthlySharePaisa: monthlyShare,
      payments: mine,
    );
  }).toList();
}

class MonthlyContribution {
  MonthlyContribution({
    required this.member,
    required this.paidPaisa,
    required this.sharePaisa,
    required this.contributedPaisa,
    required this.sentVerifiedPaisa,
    required this.sentPendingPaisa,
  });
  final Member member;

  /// Expenses this member paid in the month, integer paisa.
  final int paidPaisa;

  /// This member's share of the month's expenses, integer paisa.
  final int sharePaisa;

  /// Contribution = paid this month + verified settlements sent
  /// this month, integer paisa.
  final int contributedPaisa;
  final int sentVerifiedPaisa;
  final int sentPendingPaisa;

  /// True when the member paid for at least one expense this month.
  bool get didPay => paidPaisa > 0;
}

/// Monthly breakdown: who paid, who did not pay, and how much each
/// member contributed — for one calendar month ([month] is any date
/// in that month). Expenses count by `expenseDate`; payments count
/// by `createdAt` (a payment with no timestamp cannot be placed in
/// a month, so it is excluded from the monthly figures — its totals
/// still appear in [memberPaymentSummaries]).
List<MonthlyContribution> monthlyBreakdown({
  required List<ExpenseRecord> expenses,
  required List<PaymentRecord> payments,
  required List<Member> members,
  required DateTime month,
}) {
  final summaries = memberPaymentSummaries(
    expenses: expenses,
    payments: payments,
    members: members,
    now: month,
  );
  return summaries
      .map((s) => MonthlyContribution(
            member: s.member,
            paidPaisa: s.monthlyPaidPaisa,
            sharePaisa: s.monthlySharePaisa,
            contributedPaisa: s.monthlyContributionPaisa,
            sentVerifiedPaisa: s.sentVerifiedPaisa,
            sentPendingPaisa: s.sentPendingPaisa,
          ))
      .toList();
}
