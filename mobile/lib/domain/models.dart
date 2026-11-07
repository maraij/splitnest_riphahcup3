/// Domain models — pure data, no Firestore, no Flutter.
/// Firestore mapping lives in data/firestore_repository.dart.
library;

class Member {
  Member({required this.id, required this.name});
  final String id;
  final String name;
  factory Member.fromJson(Map<String, dynamic> j) =>
      Member(id: j['id'] as String, name: j['name'] as String);
}

class ShoppingItem {
  ShoppingItem({
    required this.id,
    required this.title,
    required this.unit,
    required this.requestedQty,
    required this.status,
  });
  final String id;
  final String title;
  final String unit;
  final int requestedQty;
  final String status;
  bool get isPending => status == 'Pending';
  factory ShoppingItem.fromJson(Map<String, dynamic> j) => ShoppingItem(
        id: j['id'] as String,
        title: j['title'] as String,
        unit: j['unit'] as String,
        requestedQty: (j['requested_qty'] as num).toInt(),
        status: j['status'] as String,
      );
}

class BalanceRow {
  BalanceRow({
    required this.memberId,
    required this.name,
    required this.net,
    required this.paid,
    required this.share,
  });
  final String memberId;
  final String name;
  final String net;
  final String paid;
  final String share;
  factory BalanceRow.fromJson(Map<String, dynamic> j) => BalanceRow(
        memberId: j['member_id'] as String,
        name: j['name'] as String? ?? j['member_id'] as String,
        net: j['net'] as String,
        paid: j['paid'] as String? ?? '0.00',
        share: j['share'] as String? ?? '0.00',
      );
}

class Balances {
  Balances({
    required this.rows,
    required this.totalSpending,
    required this.budget,
    required this.remaining,
    required this.usedPercent,
    required this.status,
  });
  final List<BalanceRow> rows;
  final String totalSpending;
  final String budget;
  final String remaining;
  final double usedPercent;
  final String status;
  factory Balances.fromJson(Map<String, dynamic> j) => Balances(
        rows: (j['balances'] as List)
            .map((e) => BalanceRow.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalSpending: j['total_spending'] as String,
        budget: j['budget'] as String,
        remaining: j['remaining'] as String,
        usedPercent: (j['used_percent'] as num).toDouble(),
        status: j['status'] as String,
      );
}

/// One entry in the in-memory activity log (Timeline screen).
/// Appended on every successful checkout, expense post and
/// settlement. Session-only: it resets when the app reloads.
class ActivityEntry {
  ActivityEntry({
    required this.type,
    required this.title,
    required this.amount,
    required this.memberId,
    required this.detail,
    required this.timestamp,
  });

  /// 'checkout' | 'expense' | 'settle'.
  final String type;
  final String title;

  /// Amount, two-decimal string ('1500.00').
  final String amount;

  /// Member who did it (payer for expenses, sender for settlements).
  final String memberId;

  /// Short extra info, e.g. 'Ayesha → Ali'.
  final String detail;
  final DateTime timestamp;
}

/// A fixed monthly expense TEMPLATE (not an expense itself).
/// Seeded: Internet 1500.00 (Bilal) + Electricity 1020.00 (Ali),
/// split equally among all three members. Templates post nothing
/// on their own; Apply posts one equal-split expense per month.
class FixedExpense {
  FixedExpense({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.payerId,
    required this.splitMemberIds,
  });
  final String id;
  final String title;
  final String category;

  /// Monthly amount, two-decimal string ('1500.00').
  final String amount;
  final String payerId;

  /// Members sharing it equally.
  final List<String> splitMemberIds;

  factory FixedExpense.fromJson(Map<String, dynamic> j) => FixedExpense(
        id: j['id'] as String,
        title: j['title'] as String,
        category: j['category'] as String,
        amount: j['amount'] as String,
        payerId: j['payer_id'] as String,
        splitMemberIds: (j['split_members'] as List)
            .map((e) => e as String)
            .toList(),
      );
}

class ExpenseShare {
  ExpenseShare({required this.memberId, required this.amount});
  final String memberId;
  final String amount;
  factory ExpenseShare.fromJson(Map<String, dynamic> j) => ExpenseShare(
        memberId: j['member_id'] as String,
        amount: j['amount'] as String,
      );
}

class ExpenseRecord {
  ExpenseRecord({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.payerId,
    this.date,
    this.splitType,
    this.shares = const [],
    this.isDemo = false,
  });
  final String id;
  final String title;
  final String category;
  final String amount;
  final String payerId;
  final String? date;
  final String? splitType;
  final List<ExpenseShare> shares;

  /// True when this expense is clearly-labelled DEMO benchmark data
  /// (see SplitNestRepository.loadDemoBenchmark). Demo rows are never
  /// mixed silently into a real user's history.
  final bool isDemo;
  factory ExpenseRecord.fromJson(Map<String, dynamic> j) => ExpenseRecord(
        id: j['id'] as String,
        title: j['title'] as String,
        category: j['category'] as String,
        amount: j['amount'] as String,
        payerId: j['payer_id'] as String,
        date: j['date'] as String?,
        splitType: j['split_type'] as String?,
        shares: (j['shares'] as List?)
                ?.map((s) => ExpenseShare.fromJson(s as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// One settlement (payment) between two members.
///
/// A payment is a **record** first and a **verified fact** second:
/// `status` starts as `recorded` (set by the sender) and moves to
/// `verified` when an owner/admin confirms it. Either way it counts
/// in the ledger immediately (Net = Paid − Share + Sent − Received),
/// exactly as the old backend's settlements did — verification is a
/// trust flag, not a second posting. A payment never changes total
/// spending.
class PaymentRecord {
  PaymentRecord({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.amount,
    required this.status,
    this.verifiedBy,
    this.createdAt,
  });
  final String id;
  final String senderId;
  final String recipientId;

  /// Amount, two-decimal string ('250.00').
  final String amount;

  /// 'recorded' | 'verified'.
  final String status;
  final String? verifiedBy;
  final DateTime? createdAt;
}
