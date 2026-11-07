// Phase 5 — expenses & payments + OCR.
// Covers, in layers:
//   1. the pure helpers: percentage splits + validation, QR payload
//      parse/format, receipt-text parsing (OCR text in, fields out),
//      the payment status state machine, per-member payment
//      tracking (verified-only settled balances);
//   2. the repository contract (in-memory fake): percentage expense
//      add, expense edit/delete authorisation, payment
//      verify/reject authorisation + state machine, uploads;
//   3. AppState end-to-end with the fake: percentage add/edit/
//      delete, record → verify / reject, receipt attach, profile
//      photo upload.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/data/repository.dart';
import 'package:splitnest/domain/balances.dart';
import 'package:splitnest/domain/expense_auth.dart';
import 'package:splitnest/domain/insights.dart';
import 'package:splitnest/domain/models.dart';
import 'package:splitnest/domain/payment_tracking.dart';
import 'package:splitnest/domain/percentage_split.dart';
import 'package:splitnest/domain/qr_payload.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';

String _today() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

List<Member> get _members => [
      Member(id: 'M01', name: 'Ali'),
      Member(id: 'M02', name: 'Ayesha'),
      Member(id: 'M03', name: 'Bilal'),
    ];

void main() {
  group('percentage splits (pure)', () {
    test('50/50 splits exactly', () {
      final shares = percentageSplit(100000, [
        (memberId: 'M01', percentHundredths: 5000),
        (memberId: 'M02', percentHundredths: 5000),
      ]);
      expect(
        {for (final s in shares) s.memberId: s.amountPaisa},
        {'M01': 50000, 'M02': 50000},
      );
    });

    test('thirds sum exactly to the amount (remainder 1-by-1)', () {
      final shares = percentageSplit(100000, [
        (memberId: 'M01', percentHundredths: 3333),
        (memberId: 'M02', percentHundredths: 3333),
        (memberId: 'M03', percentHundredths: 3334),
      ]);
      expect(
        {for (final s in shares) s.memberId: s.amountPaisa},
        {'M01': 33330, 'M02': 33330, 'M03': 33340},
      );
      expect(
        shares.fold(0, (sum, s) => sum + s.amountPaisa),
        100000,
      );
    });

    test('tiny amounts still sum exactly', () {
      // 100 paisa at 33.33/33.33/33.34: floors are 33/33/33, the
      // 1-paisa remainder goes to the first member in ID order.
      final shares = percentageSplit(100, [
        (memberId: 'M01', percentHundredths: 3333),
        (memberId: 'M02', percentHundredths: 3333),
        (memberId: 'M03', percentHundredths: 3334),
      ]);
      expect(
        {for (final s in shares) s.memberId: s.amountPaisa},
        {'M01': 34, 'M02': 33, 'M03': 33},
      );
    });

    test('parse + format round-trip', () {
      expect(parsePercentHundredths('40'), 4000);
      expect(parsePercentHundredths('33.33'), 3333);
      expect(parsePercentHundredths('100'), 10000);
      expect(parsePercentHundredths('0'), 0);
      expect(parsePercentHundredths('100.01'), isNull);
      expect(parsePercentHundredths('abc'), isNull);
      expect(parsePercentHundredths('12.345'), isNull);
      expect(formatPercentHundredths(4000), '40');
      expect(formatPercentHundredths(3333), '33.33');
      expect(formatPercentHundredths(10000), '100');
    });

    test('validation: percents must sum to 100', () {
      const known = ['M01', 'M02', 'M03'];
      final ok = percentageSplitError(
        amountPaisa: 100000,
        shares: [
          (memberId: 'M01', percentHundredths: 5000),
          (memberId: 'M02', percentHundredths: 3000),
          (memberId: 'M03', percentHundredths: 2000),
        ],
        knownMembers: known,
      );
      expect(ok, isNull);
      final short = percentageSplitError(
        amountPaisa: 100000,
        shares: [
          (memberId: 'M01', percentHundredths: 5000),
          (memberId: 'M02', percentHundredths: 3000),
          (memberId: 'M03', percentHundredths: 1000),
        ],
        knownMembers: known,
      );
      expect(short, contains('100%'));
      final unknown = percentageSplitError(
        amountPaisa: 100000,
        shares: [(memberId: 'M99', percentHundredths: 10000)],
        knownMembers: known,
      );
      expect(unknown, isNotNull);
      final dup = percentageSplitError(
        amountPaisa: 100000,
        shares: [
          (memberId: 'M01', percentHundredths: 5000),
          (memberId: 'M01', percentHundredths: 5000),
        ],
        knownMembers: known,
      );
      expect(dup, isNotNull);
      final noAmount = percentageSplitError(
        amountPaisa: 0,
        shares: [(memberId: 'M01', percentHundredths: 10000)],
        knownMembers: known,
      );
      expect(noAmount, isNotNull);
    });

    test('validatedShares percentage branch keeps the invariant', () {
      final shares = validatedShares(
        amountPaisa: 100000,
        splitType: 'percentage',
        percentageSplits: [
          {'member_id': 'M01', 'percent': '50'},
          {'member_id': 'M02', 'percent': '30'},
          {'member_id': 'M03', 'percent': '20'},
        ],
        knownMembers: ['M01', 'M02', 'M03'],
      );
      expect(
        {for (final s in shares) s.memberId: s.amountPaisa},
        {'M01': 50000, 'M02': 30000, 'M03': 20000},
      );
      expect(
        () => validatedShares(
          amountPaisa: 100000,
          splitType: 'percentage',
          percentageSplits: [
            {'member_id': 'M01', 'percent': '50'},
            {'member_id': 'M02', 'percent': '30'},
            {'member_id': 'M03', 'percent': '10'},
          ],
          knownMembers: ['M01', 'M02', 'M03'],
        ),
        throwsA(isA<LocalDataException>()),
      );
    });
  });

  group('QR payload (pure)', () {
    test('parse + format round-trip, with and without date', () {
      const payload = 'SPLITNEST|Internet Bill|1500.00|Utilities|2026-11-07';
      final parsed = parseQrPayload(payload);
      expect(parsed, isNotNull);
      expect(parsed!.title, 'Internet Bill');
      expect(parsed.amountPaisa, 150000);
      expect(parsed.category, 'Utilities');
      expect(parsed.date, '2026-11-07');
      expect(
        formatQrPayload(
          title: 'Internet Bill',
          amountPaisa: 150000,
          category: 'Utilities',
          date: '2026-11-07',
        ),
        payload,
      );
      final noDate = parseQrPayload('SPLITNEST|Milk|780.00|Groceries');
      expect(noDate, isNotNull);
      expect(noDate!.date, isNull);
      expect(noDate.amountPaisa, 78000);
    });

    test('invalid codes are rejected, never partially parsed', () {
      expect(parseQrPayload(''), isNull);
      expect(parseQrPayload('SPLITNEST|Milk|780.00'), isNull);
      expect(parseQrPayload('OTHER|Milk|780.00|Groceries'), isNull);
      expect(parseQrPayload('SPLITNEST||780.00|Groceries'), isNull);
      expect(parseQrPayload('SPLITNEST|Milk|0.00|Groceries'), isNull);
      expect(parseQrPayload('SPLITNEST|Milk|abc|Groceries'), isNull);
      expect(parseQrPayload('SPLITNEST|Milk|780.00|'), isNull);
      expect(parseQrPayload('SPLITNEST|Milk|780.00|Groceries|07/11/26'),
          isNull);
      expect(
        formatQrPayload(
          title: 'Bad|Title',
          amountPaisa: 100,
          category: 'General',
        ),
        isNull,
      );
      expect(
        formatQrPayload(
          title: 'Ok',
          amountPaisa: 0,
          category: 'General',
        ),
        isNull,
      );
    });
  });

  group('receipt-text parsing (OCR text in, fields out)', () {
    test('multi-line OCR-style receipt reads title, amount, date', () {
      const ocr = '''
Imtiaz Super Market
Grocery Items
Milk 2L  450.00
Rice 5kg  820.00
TOTAL  1270.00
05 Nov 2026
Thank you!
''';
      final parsed = parseReceipt(ocr);
      expect(parsed, isNotNull);
      expect(parsed!.amount, 1270.00);
      expect(parsed.date, DateTime(2026, 11, 5));
      expect(parsed.title, isNotEmpty);
    });

    test('receipt with a PKR total line', () {
      const ocr = 'Internet Bill\nPKR 1,500.00\nDue: 10 Nov 2026';
      final parsed = parseReceipt(ocr);
      expect(parsed, isNotNull);
      expect(parsed!.title, 'Internet Bill');
      expect(parsed.amount, 1500.00);
    });

    test('text with no price or no item is not invented', () {
      expect(parseReceipt('Hello world\nno numbers here'), isNull);
      expect(parseReceipt(''), isNull);
      expect(parseReceipt('12345'), isNull);
    });
  });

  group('payment status state machine (pure)', () {
    test('recorded → verified / rejected need an admin', () {
      expect(
        paymentStatusTransitionError(
          current: 'recorded',
          target: 'verified',
          isAdmin: true,
        ),
        isNull,
      );
      expect(
        paymentStatusTransitionError(
          current: 'recorded',
          target: 'rejected',
          isAdmin: true,
        ),
        isNull,
      );
      expect(
        paymentStatusTransitionError(
          current: 'recorded',
          target: 'verified',
          isAdmin: false,
        ),
        contains('Only the household owner or an admin'),
      );
      expect(
        paymentStatusTransitionError(
          current: 'recorded',
          target: 'rejected',
          isAdmin: false,
        ),
        isNotNull,
      );
    });

    test('verified / rejected are terminal', () {
      expect(
        paymentStatusTransitionError(
          current: 'verified',
          target: 'verified',
          isAdmin: true,
        ),
        isNotNull,
      );
      expect(
        paymentStatusTransitionError(
          current: 'verified',
          target: 'rejected',
          isAdmin: true,
        ),
        isNotNull,
      );
      expect(
        paymentStatusTransitionError(
          current: 'rejected',
          target: 'verified',
          isAdmin: true,
        ),
        isNotNull,
      );
      expect(
        paymentStatusTransitionError(
          current: 'recorded',
          target: 'recorded',
          isAdmin: true,
        ),
        isNotNull,
      );
    });

    test('labels never show an unverified payment as confirmed', () {
      expect(paymentStatusLabel('recorded'),
          'Recorded — awaiting verification');
      expect(paymentStatusLabel('verified'), 'Verified');
      expect(
        paymentStatusLabel('rejected'),
        'Rejected — not counted as settled',
      );
      // An unknown status is treated as pending, never as verified.
      expect(paymentStatusLabel('mystery'),
          'Recorded — awaiting verification');
    });

    test('edit authorisation: creator, payer, admin — nobody else', () {
      expect(
        canEditExpense(
          isAdmin: false,
          actorUid: 'uid-ali',
          actorMemberId: 'M01',
          createdByUid: 'uid-ali',
          payerMemberId: 'M02',
        ),
        isTrue,
      );
      expect(
        canEditExpense(
          isAdmin: false,
          actorUid: 'uid-ayesha',
          actorMemberId: 'M02',
          createdByUid: 'uid-ali',
          payerMemberId: 'M02',
        ),
        isTrue,
      );
      expect(
        canEditExpense(
          isAdmin: true,
          actorUid: 'uid-ali',
          actorMemberId: 'M01',
          createdByUid: 'uid-someone-else',
          payerMemberId: 'M02',
        ),
        isTrue,
      );
      expect(
        canEditExpense(
          isAdmin: false,
          actorUid: 'uid-bilal',
          actorMemberId: 'M03',
          createdByUid: 'uid-ali',
          payerMemberId: 'M02',
        ),
        isFalse,
      );
      expect(canVerifyPayment('owner'), isTrue);
      expect(canVerifyPayment('admin'), isTrue);
      expect(canVerifyPayment('member'), isFalse);
      expect(canVerifyPayment(null), isFalse);
    });
  });

  group('per-member payment tracking (pure)', () {
    late List<ExpenseRecord> expenses;
    late List<PaymentRecord> payments;

    setUp(() {
      final today = _today();
      final now = DateTime.now();
      expenses = [
        ExpenseRecord(
          id: 'E1',
          title: 'Groceries',
          category: 'Groceries',
          amount: '900.00',
          payerId: 'M01',
          date: today,
          splitType: 'equal',
          shares: [
            ExpenseShare(memberId: 'M01', amount: '300.00'),
            ExpenseShare(memberId: 'M02', amount: '300.00'),
            ExpenseShare(memberId: 'M03', amount: '300.00'),
          ],
        ),
        ExpenseRecord(
          id: 'E2',
          title: 'Solo',
          category: 'General',
          amount: '300.00',
          payerId: 'M02',
          date: today,
          splitType: 'custom',
          shares: [ExpenseShare(memberId: 'M02', amount: '300.00')],
        ),
      ];
      payments = [
        PaymentRecord(
          id: 'P1',
          senderId: 'M02',
          recipientId: 'M01',
          amount: '250.00',
          status: 'verified',
          verifiedBy: 'uid-ali',
          createdAt: now,
        ),
        PaymentRecord(
          id: 'P2',
          senderId: 'M02',
          recipientId: 'M01',
          amount: '100.00',
          status: 'recorded',
          createdAt: now,
        ),
        PaymentRecord(
          id: 'P3',
          senderId: 'M03',
          recipientId: 'M01',
          amount: '50.00',
          status: 'rejected',
          rejectedBy: 'uid-ali',
          createdAt: now,
        ),
      ];
    });

    test('settled balance counts verified only; recorded is pending', () {
      final summaries = memberPaymentSummaries(
        expenses: expenses,
        payments: payments,
        members: _members,
      );
      final ali = summaries[0];
      expect(ali.totalOwedPaisa, 30000);
      expect(ali.totalPaidPaisa, 90000);
      expect(ali.receivedVerifiedPaisa, 25000);
      expect(ali.receivedPendingPaisa, 10000);
      // 900 - 300 - 250 (verified only) = 350 → owed.
      expect(ali.remainingPaisa, 35000);
      expect(ali.status, 'owed');
      expect(ali.hasPending, isTrue);

      final ayesha = summaries[1];
      expect(ayesha.totalOwedPaisa, 60000);
      expect(ayesha.totalPaidPaisa, 30000);
      expect(ayesha.sentVerifiedPaisa, 25000);
      expect(ayesha.sentPendingPaisa, 10000);
      // 300 - 600 + 250 = -50 → owes. The recorded 100 does NOT
      // move the settled balance.
      expect(ayesha.remainingPaisa, -5000);
      expect(ayesha.status, 'owes');

      final bilal = summaries[2];
      // The rejected 50 counts nowhere.
      expect(bilal.sentVerifiedPaisa, 0);
      expect(bilal.sentPendingPaisa, 0);
      expect(bilal.remainingPaisa, -30000);
      expect(bilal.status, 'owes');
      expect(bilal.hasPending, isFalse);
    });

    test('monthly breakdown: who paid, who did not, contributions', () {
      final breakdown = monthlyBreakdown(
        expenses: expenses,
        payments: payments,
        members: _members,
        month: DateTime.now(),
      );
      expect(breakdown[0].didPay, isTrue);
      expect(breakdown[0].paidPaisa, 90000);
      expect(breakdown[0].contributedPaisa, 90000);
      expect(breakdown[1].didPay, isTrue);
      // Ayesha: paid 300 + verified sent 250 = 550 contributed.
      expect(breakdown[1].contributedPaisa, 55000);
      expect(breakdown[1].sentPendingPaisa, 10000);
      expect(breakdown[2].didPay, isFalse);
      expect(breakdown[2].contributedPaisa, 0);
    });

    test('computeBalances skips rejected payments', () {
      final balances = computeBalances(
        expenses: expenses,
        payments: payments,
        members: _members,
        budgetPaisa: 500000,
      );
      // Ali net: 900 - 300 + 0 - (250 verified + 100 recorded) = 250.
      // Ayesha net (ledger counts the recorded 100 too):
      // 300 - 600 + 350 = 50 — her VERIFIED-only net is -50 (see the
      // test above); the two balances differ by design. The rejected
      // 50 from Bilal is in nobody's net.
      expect(
        {for (final r in balances.rows) r.memberId: r.net},
        {'M01': '250.00', 'M02': '50.00', 'M03': '-300.00'},
      );
    });
  });

  group('repository contract (fake): expense CRUD authorisation', () {
    late FakeSplitNestRepository repo;
    const gid = FakeSplitNestRepository.groupId;

    setUp(() async {
      repo = FakeSplitNestRepository.empty();
      await repo.ensureGroup(
        uid: 'demo-M01',
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
      await repo.ensureGroup(
        uid: 'demo-M02',
        displayName: 'Ayesha',
        email: 'ayesha.demo@splitnest.app',
        legacyMemberId: 'M02',
        isDemo: true,
      );
      await repo.ensureGroup(
        uid: 'demo-M03',
        displayName: 'Bilal',
        email: 'bilal.demo@splitnest.app',
        legacyMemberId: 'M03',
        isDemo: true,
      );
    });

    test('percentage add stores exact shares; bad percents write nothing',
        () async {
      final expense = await repo.addExpense(
        groupId: gid,
        title: 'Internet',
        category: 'Utilities',
        date: _today(),
        amount: '1000.00',
        payerId: 'M01',
        splitType: 'percentage',
        percentageSplits: [
          {'member_id': 'M01', 'percent': '50'},
          {'member_id': 'M02', 'percent': '30'},
          {'member_id': 'M03', 'percent': '20'},
        ],
        actorUid: 'demo-M01',
      );
      expect(
        {for (final s in expense.shares) s.memberId: s.amount},
        {'M01': '500.00', 'M02': '300.00', 'M03': '200.00'},
      );
      await expectLater(
        repo.addExpense(
          groupId: gid,
          title: 'Bad',
          category: 'Utilities',
          date: _today(),
          amount: '1000.00',
          payerId: 'M01',
          splitType: 'percentage',
          percentageSplits: [
            {'member_id': 'M01', 'percent': '50'},
            {'member_id': 'M02', 'percent': '30'},
            {'member_id': 'M03', 'percent': '10'},
          ],
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
      expect(repo.allExpenses.length, 1);
    });

    test('edit: creator and owner may edit; another member may not',
        () async {
      final expense = await repo.addExpense(
        groupId: gid,
        title: 'Groceries',
        category: 'Groceries',
        date: _today(),
        amount: '900.00',
        payerId: 'M02',
        splitType: 'equal',
        actorUid: 'demo-M02',
      );
      // Ayesha (creator/payer) edits the amount: splits recompute
      // and the invariant holds (300 each → 400 each).
      final edited = await repo.updateExpense(
        groupId: gid,
        id: expense.id,
        amount: '1200.00',
        actorUid: 'demo-M02',
      );
      expect(edited.amount, '1200.00');
      expect(
        {for (final s in edited.shares) s.memberId: s.amount},
        {'M01': '400.00', 'M02': '400.00', 'M03': '400.00'},
      );
      // Bilal (neither creator nor admin) may not edit it.
      await expectLater(
        repo.updateExpense(
          groupId: gid,
          id: expense.id,
          amount: '100.00',
          actorUid: 'demo-M03',
        ),
        throwsA(isA<LocalDataException>()),
      );
      // Ali (owner) may edit it.
      final ownerEdited = await repo.updateExpense(
        groupId: gid,
        id: expense.id,
        title: 'Groceries (owner edit)',
        actorUid: 'demo-M01',
      );
      expect(ownerEdited.title, 'Groceries (owner edit)');
      expect(ownerEdited.amount, '1200.00');
      // An invalid edit writes nothing.
      await expectLater(
        repo.updateExpense(
          groupId: gid,
          id: expense.id,
          amount: '0.00',
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
      expect(
        (await repo.getExpenses(gid)).single.amount,
        '1200.00',
      );
    });

    test('edit can change the split type and keeps the invariant',
        () async {
      final expense = await repo.addExpense(
        groupId: gid,
        title: 'Dinner',
        category: 'Dining',
        date: _today(),
        amount: '1000.00',
        payerId: 'M01',
        splitType: 'equal',
        actorUid: 'demo-M01',
      );
      final edited = await repo.updateExpense(
        groupId: gid,
        id: expense.id,
        splitType: 'percentage',
        percentageSplits: [
          {'member_id': 'M01', 'percent': '50'},
          {'member_id': 'M02', 'percent': '50'},
        ],
        actorUid: 'demo-M01',
      );
      expect(edited.splitType, 'percentage');
      expect(
        {for (final s in edited.shares) s.memberId: s.amount},
        {'M01': '500.00', 'M02': '500.00'},
      );
    });

    test('delete: creator and owner may delete; another member may not',
        () async {
      final expense = await repo.addExpense(
        groupId: gid,
        title: 'To delete',
        category: 'General',
        date: _today(),
        amount: '100.00',
        payerId: 'M02',
        splitType: 'equal',
        actorUid: 'demo-M02',
      );
      await expectLater(
        repo.deleteExpense(
          groupId: gid,
          id: expense.id,
          actorUid: 'demo-M03',
        ),
        throwsA(isA<LocalDataException>()),
      );
      expect((await repo.getExpenses(gid)).length, 1);
      await repo.deleteExpense(
        groupId: gid,
        id: expense.id,
        actorUid: 'demo-M02',
      );
      expect(await repo.getExpenses(gid), isEmpty);
      await expectLater(
        repo.deleteExpense(
          groupId: gid,
          id: expense.id,
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });

    test('receipt + profile uploads return locations; oversize fails',
        () async {
      final receipt = await repo.uploadReceipt(
        groupId: gid,
        expenseId: 'E1',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(receipt, isNotNull);
      expect(receipt!.path, 'receipts/$gid/E1/receipt.jpg');
      expect(receipt.url, contains('receipts/$gid/E1/receipt.jpg'));
      final tooBig = await repo.uploadReceipt(
        groupId: gid,
        expenseId: 'E1',
        bytes: Uint8List(10 * 1024 * 1024 + 1),
      );
      expect(tooBig, isNull);
      final photo = await repo.uploadProfilePhoto(
        uid: 'demo-M01',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(photo, contains('profile-photos/demo-M01/photo.jpg'));
      final photoTooBig = await repo.uploadProfilePhoto(
        uid: 'demo-M01',
        bytes: Uint8List(5 * 1024 * 1024 + 1),
      );
      expect(photoTooBig, isNull);
    });
  });

  group('repository contract (fake): payment verify/reject', () {
    late FakeSplitNestRepository repo;
    const gid = FakeSplitNestRepository.groupId;

    setUp(() async {
      repo = FakeSplitNestRepository.benchmark();
      await repo.ensureGroup(
        uid: 'demo-M01',
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
      await repo.ensureGroup(
        uid: 'demo-M02',
        displayName: 'Ayesha',
        email: 'ayesha.demo@splitnest.app',
        legacyMemberId: 'M02',
        isDemo: true,
      );
    });

    test('record → verify (owner) and record → reject (owner)',
        () async {
      final toVerify = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M01',
        amount: '250.00',
        actorUid: 'demo-M02',
      );
      expect(toVerify.status, 'recorded');
      final verified = await repo.verifyPayment(
        groupId: gid,
        paymentId: toVerify.id,
        actorUid: 'demo-M01',
      );
      expect(verified.status, 'verified');
      expect(verified.verifiedBy, 'demo-M01');
      expect(verified.verifiedAt, isNotNull);

      final toReject = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M03',
        amount: '200.00',
        actorUid: 'demo-M02',
      );
      final rejected = await repo.rejectPayment(
        groupId: gid,
        paymentId: toReject.id,
        actorUid: 'demo-M01',
      );
      expect(rejected.status, 'rejected');
      expect(rejected.rejectedBy, 'demo-M01');
      expect(rejected.rejectedAt, isNotNull);
      // A rejected payment counts nowhere: Ayesha's net is back to
      // -200 (only the verified 250 moved it from -450).
      final balances = computeBalances(
        expenses: await repo.getExpenses(gid),
        payments: await repo.getPayments(gid),
        members: await repo.getMembers(gid),
        budgetPaisa: 500000,
      );
      expect(
        {for (final r in balances.rows) r.memberId: r.net},
        {'M01': '0.00', 'M02': '-200.00', 'M03': '200.00'},
      );
    });

    test('a plain member can neither verify nor reject', () async {
      final payment = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M01',
        amount: '250.00',
        actorUid: 'demo-M02',
      );
      await expectLater(
        repo.verifyPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M02',
        ),
        throwsA(isA<LocalDataException>()),
      );
      await expectLater(
        repo.rejectPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M02',
        ),
        throwsA(isA<LocalDataException>()),
      );
      expect(
        (await repo.getPayments(gid)).single.status,
        'recorded',
      );
    });

    test('verified and rejected payments are terminal', () async {
      final payment = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M01',
        amount: '250.00',
        actorUid: 'demo-M02',
      );
      await repo.verifyPayment(
        groupId: gid,
        paymentId: payment.id,
        actorUid: 'demo-M01',
      );
      await expectLater(
        repo.rejectPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
      final second = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M03',
        amount: '200.00',
        actorUid: 'demo-M02',
      );
      await repo.rejectPayment(
        groupId: gid,
        paymentId: second.id,
        actorUid: 'demo-M01',
      );
      await expectLater(
        repo.verifyPayment(
          groupId: gid,
          paymentId: second.id,
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });
  });

  group('AppState end-to-end (fake repository)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('percentage add → edit → delete, with UI gating', () async {
      final repo = FakeSplitNestRepository.empty();
      final ali = AppState(repository: repo);
      expect(await ali.loginWithDemo(memberId: 'M01'), isTrue);
      expect(ali.canVerifyPayments, isTrue);

      final ok = await ali.addExpense(
        title: 'Internet',
        category: 'Utilities',
        date: _today(),
        amount: '1000.00',
        payerId: 'M01',
        splitType: 'percentage',
        percentageSplits: [
          {'member_id': 'M01', 'percent': '50'},
          {'member_id': 'M02', 'percent': '30'},
          {'member_id': 'M03', 'percent': '20'},
        ],
      );
      expect(ok, isTrue);
      expect(ali.recentExpenses.length, 1);
      final expense = ali.recentExpenses.single;
      expect(expense.splitType, 'percentage');
      expect(
        {for (final s in expense.shares) s.memberId: s.amount},
        {'M01': '500.00', 'M02': '300.00', 'M03': '200.00'},
      );
      expect(ali.mayEditExpense(expense), isTrue);

      // Another member's store sees the same expense but may not
      // edit it; the owner/admin gate is per-user.
      final ayesha = AppState(repository: repo);
      expect(await ayesha.loginWithDemo(memberId: 'M02'), isTrue);
      expect(ayesha.canVerifyPayments, isFalse);
      expect(ayesha.mayEditExpense(expense), isFalse);
      expect(
        await ayesha.updateExpense(id: expense.id, amount: '1.00'),
        isFalse,
      );
      expect(ayesha.errorMessage, isNotNull);

      // The creator edits the split to equal; the invariant holds.
      expect(
        await ali.updateExpense(
          id: expense.id,
          splitType: 'equal',
          splitMembers: ['M01', 'M02', 'M03'],
        ),
        isTrue,
      );
      expect(
        {for (final s in ali.recentExpenses.single.shares) s.memberId: s.amount},
        {'M01': '333.34', 'M02': '333.33', 'M03': '333.33'},
      );
      expect(
        await ali.deleteExpense(ali.recentExpenses.single),
        isTrue,
      );
      expect(ali.recentExpenses, isEmpty);
      expect(
        ali.activityLog.any((a) => a.type == 'expense_deleted'),
        isTrue,
      );
    });

    test('record → verify / reject through AppState, with activity',
        () async {
      final repo = FakeSplitNestRepository.benchmark();
      final ali = AppState(repository: repo);
      expect(await ali.loginWithDemo(memberId: 'M01'), isTrue);
      expect(
        await ali.settle(
          senderId: 'M02',
          recipientId: 'M01',
          amount: '250.00',
        ),
        isTrue,
      );
      expect(ali.pendingPayments.length, 1);
      final payment = ali.pendingPayments.single;
      expect(ali.paymentSummaries[1].sentPendingPaisa, 25000);
      expect(ali.paymentSummaries[1].remainingPaisa, -45000);

      // A plain member cannot verify it.
      final ayesha = AppState(repository: repo);
      expect(await ayesha.loginWithDemo(memberId: 'M02'), isTrue);
      expect(await ayesha.verifyPayment(payment.id), isFalse);

      // The owner verifies it; the settled balance moves, and the
      // activity log records the verification.
      expect(await ali.verifyPayment(payment.id), isTrue);
      expect(ali.verifiedPayments.length, 1);
      expect(ali.pendingPayments, isEmpty);
      expect(ali.paymentSummaries[1].sentVerifiedPaisa, 25000);
      expect(ali.paymentSummaries[1].remainingPaisa, -20000);
      expect(
        ali.activityLog.any((a) => a.type == 'payment_verified'),
        isTrue,
      );

      // A second payment, rejected by the owner, counts nowhere.
      expect(
        await ali.settle(
          senderId: 'M02',
          recipientId: 'M03',
          amount: '200.00',
        ),
        isTrue,
      );
      final second = ali.pendingPayments.single;
      expect(await ali.rejectPayment(second.id), isTrue);
      expect(ali.rejectedPayments.length, 1);
      expect(ali.paymentSummaries[1].remainingPaisa, -20000);
      expect(
        ali.activityLog.any((a) => a.type == 'payment_rejected'),
        isTrue,
      );
    });

    test('receipt attach via AppState stores the URL on the expense',
        () async {
      final repo = FakeSplitNestRepository.empty();
      final ali = AppState(repository: repo);
      expect(await ali.loginWithDemo(memberId: 'M01'), isTrue);
      final image = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'receipt.jpg',
        mimeType: 'image/jpeg',
      );
      expect(
        await ali.addExpenseWithReceipt(
          title: 'Groceries',
          category: 'Groceries',
          date: _today(),
          amount: '780.00',
          payerId: 'M01',
          splitType: 'equal',
          receiptImage: image,
        ),
        isTrue,
      );
      final expense = ali.recentExpenses.single;
      expect(expense.receiptUrl, isNotNull);
      expect(expense.receiptUrl, contains('receipts/'));
      expect(expense.receiptPath, contains('receipt.jpg'));
    });

    test('profile photo upload stores the URL; local copy kept',
        () async {
      final repo = FakeSplitNestRepository.empty();
      final ali = AppState(repository: repo);
      expect(await ali.loginWithDemo(memberId: 'M01'), isTrue);
      final uploaded =
          await ali.setProfileImage(Uint8List.fromList([1, 2, 3]));
      expect(uploaded, isTrue);
      expect(ali.profileImageFor('M01'), isNotNull);
      expect(
        ali.profilePhotoUrlFor('M01'),
        contains('profile-photos/'),
      );
    });
  });
}
