/// Domain models — pure data, no HTTP, no Flutter.
/// JSON parsing lives here; HTTP lives in data/api_client.dart.
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
  });
  final String id;
  final String title;
  final String category;
  final String amount;
  final String payerId;
  final String? date;
  final String? splitType;
  final List<ExpenseShare> shares;
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
