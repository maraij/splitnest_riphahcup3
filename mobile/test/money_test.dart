import 'package:flutter_test/flutter_test.dart';
import 'package:splitnest/core/money.dart';
import 'package:splitnest/domain/settle_plan.dart';

void main() {
  test('parse/format paisa', () {
    expect(parsePaisa('780.00'), 78000);
    expect(parsePaisa('0.01'), 1);
    expect(parsePaisa('1000.005'), isNull);
    expect(parsePaisa('abc'), isNull);
    expect(formatPaisa(-45000), '-450.00');
    expect(formatPaisa(1), '0.01');
  });

  test('equal split 1000.00 / 3', () {
    final shares = equalSplit(100000, ['M01', 'M02', 'M03']);
    expect(shares.map((s) => s.amountPaisa).toList(), [33334, 33333, 33333]);
  });

  test('equal split rounding cases', () {
    expect(equalSplit(1, ['M01', 'M02', 'M03']).map((s) => s.amountPaisa).toList(), [1, 0, 0]);
    expect(equalSplit(2, ['M01', 'M02', 'M03']).map((s) => s.amountPaisa).toList(), [1, 1, 0]);
    expect(equalSplit(3, ['M01', 'M02', 'M03']).map((s) => s.amountPaisa).toList(), [1, 1, 1]);
  });

  test('smart settle plan from benchmark balances', () {
    final plan = computeSettlePlan([
      (memberId: 'M01', netPaisa: 25000),
      (memberId: 'M02', netPaisa: -45000),
      (memberId: 'M03', netPaisa: 20000),
    ]);
    expect(plan.length, 2);
    expect(
        plan[0],
        (
          senderId: 'M02',
          recipientId: 'M01',
          amountPaisa: 25000,
        ));
    expect(
        plan[1],
        (
          senderId: 'M02',
          recipientId: 'M03',
          amountPaisa: 20000,
        ));
  });

  test('smart settle plan is empty when everyone is settled', () {
    expect(
        computeSettlePlan([
          (memberId: 'M01', netPaisa: 0),
          (memberId: 'M02', netPaisa: 0),
          (memberId: 'M03', netPaisa: 0),
        ]),
        isEmpty);
  });

  test('smart settle plan zeroes balances in general', () {
    final nets = {'M01': 10000, 'M02': -7000, 'M03': -3000};
    final plan = computeSettlePlan([
      for (final e in nets.entries)
        (memberId: e.key, netPaisa: e.value),
    ]);
    final remaining = Map<String, int>.from(nets);
    for (final step in plan) {
      remaining[step.senderId] = remaining[step.senderId]! + step.amountPaisa;
      remaining[step.recipientId] =
          remaining[step.recipientId]! - step.amountPaisa;
    }
    expect(remaining.values, everyElement(0));
  });
}
