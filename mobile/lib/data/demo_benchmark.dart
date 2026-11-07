/// The DEMO benchmark seed — the exact four expenses, two fixed
/// templates and two shopping items from the old backend benchmark
/// (README "Benchmark (reproduce exactly)"), as pure data.
///
/// Both the local repository and the in-memory test fake seed
/// from here, so the benchmark is identical everywhere. Benchmark
/// expenses are dated "today" (the old backend dated every benchmark
/// expense today), so they count towards the current month's total
/// spending: 4200.00 of the 5000.00 budget, 84%, Near Limit, nets
/// Ali +250.00 / Ayesha -450.00 / Bilal +200.00.
///
/// Demo data is NEVER auto-seeded. It loads only when a demo user
/// taps "Load demo benchmark" ([SplitNestRepository.loadDemoBenchmark]).
/// Seeded docs carry deterministic ids (`demo-benchmark-*`,
/// `demo-fixed-*`, `demo-shopping-*`) so a second load is a no-op,
/// and seeded expenses carry `isDemo: true` in lock.json
/// (`isDemo` on [ExpenseRecord]) so the UI can label them.
library;

import '../domain/models.dart';

String _dateString(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One benchmark expense, as the repository should store it.
class BenchmarkExpenseSpec {
  const BenchmarkExpenseSpec({
    required this.id,
    required this.title,
    required this.category,
    required this.amountPaisa,
    required this.payerId,
    required this.splitType,
    required this.splitMemberIds,
    this.customSplits,
  });
  final String id;
  final String title;
  final String category;
  final int amountPaisa;
  final String payerId;
  final String splitType;
  final List<String> splitMemberIds;

  /// memberId → paisa, for custom splits only.
  final Map<String, int>? customSplits;
}

const List<BenchmarkExpenseSpec> benchmarkExpenses = [
  BenchmarkExpenseSpec(
    id: 'demo-benchmark-1',
    title: 'Shopping: Milk, Rice',
    category: 'Groceries',
    amountPaisa: 78000,
    payerId: 'M01',
    splitType: 'equal',
    splitMemberIds: ['M01', 'M02', 'M03'],
  ),
  BenchmarkExpenseSpec(
    id: 'demo-benchmark-2',
    title: 'Cleaning Supplies',
    category: 'Cleaning',
    amountPaisa: 90000,
    payerId: 'M02',
    splitType: 'equal',
    splitMemberIds: ['M01', 'M02'],
  ),
  BenchmarkExpenseSpec(
    id: 'demo-benchmark-3',
    title: 'Internet Bill',
    category: 'Utilities',
    amountPaisa: 150000,
    payerId: 'M03',
    splitType: 'custom',
    splitMemberIds: ['M01', 'M02', 'M03'],
    customSplits: {'M01': 50000, 'M02': 30000, 'M03': 70000},
  ),
  BenchmarkExpenseSpec(
    id: 'demo-benchmark-4',
    title: 'Electricity Bill',
    category: 'Utilities',
    amountPaisa: 102000,
    payerId: 'M01',
    splitType: 'equal',
    splitMemberIds: ['M01', 'M02', 'M03'],
  ),
];

/// One benchmark fixed template.
class BenchmarkFixedSpec {
  const BenchmarkFixedSpec({
    required this.id,
    required this.title,
    required this.category,
    required this.amountPaisa,
    required this.payerId,
  });
  final String id;
  final String title;
  final String category;
  final int amountPaisa;
  final String payerId;
}

const List<BenchmarkFixedSpec> benchmarkFixed = [
  BenchmarkFixedSpec(
    id: 'demo-fixed-internet',
    title: 'Internet',
    category: 'Utilities',
    amountPaisa: 150000,
    payerId: 'M03',
  ),
  BenchmarkFixedSpec(
    id: 'demo-fixed-electricity',
    title: 'Electricity',
    category: 'Utilities',
    amountPaisa: 102000,
    payerId: 'M01',
  ),
];

/// One benchmark shopping item (pending, as seeded).
class BenchmarkShoppingSpec {
  const BenchmarkShoppingSpec({
    required this.id,
    required this.title,
    required this.unit,
    required this.qty,
  });
  final String id;
  final String title;
  final String unit;
  final int qty;
}

const List<BenchmarkShoppingSpec> benchmarkShopping = [
  BenchmarkShoppingSpec(id: 'demo-shopping-milk', title: 'Milk', unit: 'bottle', qty: 2),
  BenchmarkShoppingSpec(id: 'demo-shopping-rice', title: 'Rice', unit: 'pack', qty: 1),
];

/// The benchmark expenses as domain records, dated [now] (today by
/// default). Used by the in-memory fake and by tests.
List<ExpenseRecord> benchmarkExpenseRecords({DateTime? now}) {
  final date = _dateString(now ?? DateTime.now());
  return benchmarkExpenses.map((spec) {
    final shares = spec.splitType == 'custom'
        ? spec.customSplits!.entries
            .map((e) => ExpenseShare(
                  memberId: e.key,
                  amount: (e.value / 100).toStringAsFixed(2),
                ))
            .toList()
        : _equalShares(spec.amountPaisa, spec.splitMemberIds);
    return ExpenseRecord(
      id: spec.id,
      title: spec.title,
      category: spec.category,
      amount: (spec.amountPaisa / 100).toStringAsFixed(2),
      payerId: spec.payerId,
      date: date,
      splitType: spec.splitType,
      shares: shares,
      isDemo: true,
    );
  }).toList();
}

List<ExpenseShare> _equalShares(int totalPaisa, List<String> memberIds) {
  final ids = [...memberIds]..sort();
  final base = totalPaisa ~/ ids.length;
  final remainder = totalPaisa - base * ids.length;
  return [
    for (var i = 0; i < ids.length; i++)
      ExpenseShare(
        memberId: ids[i],
        amount: ((base + (i < remainder ? 1 : 0)) / 100).toStringAsFixed(2),
      ),
  ];
}

/// The benchmark fixed templates as domain records.
List<FixedExpense> benchmarkFixedRecords() => benchmarkFixed
    .map((spec) => FixedExpense(
          id: spec.id,
          title: spec.title,
          category: spec.category,
          amount: (spec.amountPaisa / 100).toStringAsFixed(2),
          payerId: spec.payerId,
          splitMemberIds: const ['M01', 'M02', 'M03'],
        ))
    .toList();

/// The benchmark shopping items as domain records (all Pending).
List<ShoppingItem> benchmarkShoppingRecords() => benchmarkShopping
    .map((spec) => ShoppingItem(
          id: spec.id,
          title: spec.title,
          unit: spec.unit,
          requestedQty: spec.qty,
          status: 'Pending',
        ))
    .toList();
