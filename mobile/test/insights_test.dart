import 'package:flutter_test/flutter_test.dart';
import 'package:splitnest/domain/insights.dart';
import 'package:splitnest/domain/models.dart';

ExpenseRecord _exp({
  required String title,
  required String category,
  required String amount,
  required String payerId,
  String? date,
  String? splitType,
  List<ExpenseShare> shares = const [],
}) =>
    ExpenseRecord(
      id: 'E-$title-$amount',
      title: title,
      category: category,
      amount: amount,
      payerId: payerId,
      date: date,
      splitType: splitType,
      shares: shares,
    );

void main() {
  group('categoryBreakdown', () {
    test('sums by category, largest first', () {
      final expenses = [
        _exp(title: 'Internet', category: 'Utilities', amount: '1500.00', payerId: 'M03', date: '2026-11-03'),
        _exp(title: 'Electricity', category: 'Utilities', amount: '1020.00', payerId: 'M01', date: '2026-11-04'),
        _exp(title: 'Cleaning', category: 'Cleaning', amount: '900.00', payerId: 'M02', date: '2026-11-02'),
      ];
      final slices = categoryBreakdown(expenses);
      expect(slices.length, 2);
      expect(slices[0].category, 'Utilities');
      expect(slices[0].total, 2520.00);
      expect(slices[0].percent, closeTo(73.7, 0.1));
      expect(slices[1].category, 'Cleaning');
      expect(slices[1].total, 900.00);
      expect(slices[1].percent, closeTo(26.3, 0.1));
    });

    test('empty history gives no slices', () {
      expect(categoryBreakdown([]), isEmpty);
    });
  });

  group('monthlySummary', () {
    test('biggest expense and top payer from real history', () {
      final expenses = [
        _exp(title: 'Internet', category: 'Utilities', amount: '1500.00', payerId: 'M03', date: '2026-11-03'),
        _exp(title: 'Electricity', category: 'Utilities', amount: '1020.00', payerId: 'M01', date: '2026-11-04'),
        _exp(title: 'Cleaning', category: 'Cleaning', amount: '900.00', payerId: 'M02', date: '2026-11-02'),
      ];
      final summary = monthlySummary(expenses);
      expect(summary.biggest?.title, 'Internet');
      expect(summary.biggest?.amount, '1500.00');
      expect(summary.topPayerId, 'M03');
      expect(summary.topPayerTotal, 1500.00);
    });

    test('empty history gives nulls, not invented values', () {
      final summary = monthlySummary([]);
      expect(summary.biggest, isNull);
      expect(summary.topPayerId, isNull);
      expect(summary.topPayerTotal, 0);
    });
  });

  group('recurringBillStatus', () {
    final now = DateTime(2026, 11, 5);

    test('paid this month vs due', () {
      final expenses = [
        _exp(title: 'Internet', category: 'Utilities', amount: '1500.00', payerId: 'M03', date: '2026-11-03'),
        _exp(title: 'Electricity', category: 'Utilities', amount: '1020.00', payerId: 'M01', date: '2026-10-20'),
      ];
      final bills = recurringBillStatus(expenses, now: now);
      expect(bills[0].label, 'Internet');
      expect(bills[0].isPaid, isTrue);
      expect(bills[0].paidExpense?.amount, '1500.00');
      expect(bills[1].label, 'Electricity');
      expect(bills[1].isPaid, isFalse);
    });

    test('undated expense never counts as paid', () {
      final expenses = [
        _exp(title: 'Internet', category: 'Utilities', amount: '1500.00', payerId: 'M03'),
      ];
      final bills = recurringBillStatus(expenses, now: now);
      expect(bills[0].isPaid, isFalse);
    });

    test('no history means both due', () {
      final bills = recurringBillStatus([], now: now);
      expect(bills.every((b) => !b.isPaid), isTrue);
    });
  });

  group('quickAddFavourites', () {
    test('most frequent first, latest amount kept', () {
      // Newest-first order, as AppState.recentExpenses stores it.
      final expenses = [
        _exp(title: 'Milk', category: 'Groceries', amount: '750.00', payerId: 'M01', date: '2026-11-05', splitType: 'equal'),
        _exp(title: 'Internet', category: 'Utilities', amount: '1500.00', payerId: 'M03', date: '2026-11-04', splitType: 'equal'),
        _exp(title: 'Milk', category: 'Groceries', amount: '780.00', payerId: 'M01', date: '2026-11-02', splitType: 'equal'),
      ];
      final favs = quickAddFavourites(expenses);
      expect(favs.length, 2);
      expect(favs[0].title, 'Milk');
      expect(favs[0].count, 2);
      expect(favs[0].amount, '750.00');
      expect(favs[1].title, 'Internet');
      expect(favs[1].count, 1);
    });

    test('empty history gives no favourites', () {
      expect(quickAddFavourites([]), isEmpty);
    });
  });

  group('parseReceipt', () {
    test('reads item, price and date from a shop receipt', () {
      final parsed = parseReceipt('''
Grocery Store
Milk 2L - Rs 780.00
Bread - Rs 120.00
Total: Rs 900.00
05/11/2026
''');
      expect(parsed, isNotNull);
      expect(parsed!.title, 'Milk 2L');
      expect(parsed.amount, 900.00);
      expect(parsed.date, DateTime(2026, 11, 5));
    });

    test('reads a PKR-prefixed total without a date', () {
      final parsed = parseReceipt('Internet Bill\nPKR 1500.00');
      expect(parsed, isNotNull);
      expect(parsed!.title, 'Internet Bill');
      expect(parsed.amount, 1500.00);
      expect(parsed.date, isNull);
    });

    test('reads a named month date', () {
      final parsed = parseReceipt('Cleaning\nRs 900\n5 Nov 2026');
      expect(parsed, isNotNull);
      expect(parsed!.title, 'Cleaning');
      expect(parsed.amount, 900.00);
      expect(parsed.date, DateTime(2026, 11, 5));
    });

    test('a bill number is not mistaken for a price', () {
      // "Bill No. 1234" must not become a PKR 1234 expense.
      final parsed = parseReceipt('Bill No. 1234\nThanks for shopping');
      expect(parsed, isNull);
    });

    test('unparseable text returns null — the form stays empty', () {
      expect(parseReceipt('hello there, no prices here'), isNull);
      expect(parseReceipt(''), isNull);
      expect(parseReceipt('x2\nqty 3'), isNull);
    });

    test('quantities alone are not prices', () {
      expect(parseReceipt('Eggs x2\nBread x1'), isNull);
    });
  });
}
