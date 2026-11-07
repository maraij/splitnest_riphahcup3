import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/core/money.dart';
import 'package:splitnest/data/demo_benchmark.dart';
import 'package:splitnest/data/firebase_auth_service.dart';
import 'package:splitnest/data/firestore_repository.dart';
import 'package:splitnest/data/google_auth_service.dart';
import 'package:splitnest/data/repository.dart';
import 'package:splitnest/domain/balances.dart';
import 'package:splitnest/domain/models.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';
import 'widget_test.dart' as widget_helpers;

// ---------------------------------------------------------------------------
// Compact fake Firebase Auth (verified/unverified email users + demo),
// so the email-only end-to-end path can be tested without Firebase.
// ---------------------------------------------------------------------------

class _FakeUser {
  _FakeUser({
    required this.uid,
    required this.email,
    required this.password,
    required this.displayName,
    required this.emailVerified,
  });
  final String uid;
  final String email;
  final String password;
  String displayName;
  bool emailVerified;
}

class CompactFakeFirebaseAuth implements FirebaseAuthService {
  final Map<String, _FakeUser> _usersByEmail = {};
  final Map<String, String> _memberLinks = {};
  final _controller = StreamController<FirebaseSession?>.broadcast();
  FirebaseSession? _current;

  FirebaseSession _sessionFor(_FakeUser user) => FirebaseSession(
        uid: user.uid,
        email: user.email,
        displayName: user.displayName,
        emailVerified: user.emailVerified,
        isDemo: isDemoEmail(user.email),
      );

  void _emit(_FakeUser? user) {
    _current = user == null ? null : _sessionFor(user);
    _controller.add(_current);
  }

  void verifyEmail(String email) {
    final user = _usersByEmail[email];
    if (user != null) user.emailVerified = true;
  }

  @override
  Stream<FirebaseSession?> get authStateChanges => _controller.stream;

  @override
  FirebaseSession? get currentSession => _current;

  @override
  Future<FirebaseAuthResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final user = _usersByEmail[email.trim()];
    if (user == null) {
      return const FirebaseAuthFailure(
          'No account exists for that email. Check the email or create an account.');
    }
    if (user.password != password) {
      return const FirebaseAuthFailure(
          'That email or password is not correct. Try again or reset your password.');
    }
    _emit(user);
    return FirebaseAuthSuccess(_sessionFor(user));
  }

  @override
  Future<FirebaseAuthResult> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final clean = email.trim();
    if (_usersByEmail.containsKey(clean)) {
      return const FirebaseAuthFailure(
          'An account already exists for that email. Try signing in instead.');
    }
    final user = _FakeUser(
      uid: 'uid-$clean',
      email: clean,
      password: password,
      displayName: displayName,
      emailVerified: false,
    );
    _usersByEmail[clean] = user;
    _emit(user);
    return FirebaseAuthSuccess(_sessionFor(user));
  }

  @override
  Future<FirebaseAuthResult> signInWithGoogle({
    required String idToken,
  }) async {
    const email = 'google.user@gmail.com';
    var user = _usersByEmail[email];
    user ??= _FakeUser(
      uid: 'uid-google',
      email: email,
      password: '',
      displayName: 'Google User',
      emailVerified: true,
    );
    _usersByEmail[email] = user;
    _emit(user);
    return FirebaseAuthSuccess(_sessionFor(user));
  }

  @override
  Future<FirebaseAuthResult> signInDemo(DemoAccount demo) async {
    var user = _usersByEmail[demo.email];
    user ??= _FakeUser(
      uid: 'uid-${demo.memberId}',
      email: demo.email,
      password: demo.password,
      displayName: demo.name,
      emailVerified: false,
    );
    _usersByEmail[demo.email] = user;
    _emit(user);
    return FirebaseAuthSuccess(_sessionFor(user));
  }

  @override
  Future<FirebaseAuthResult> sendPasswordReset({
    required String email,
  }) async =>
      const FirebaseAuthSuccess();

  @override
  Future<bool> sendEmailVerification() async => _current != null;

  @override
  Future<FirebaseSession?> reloadCurrentUser() async {
    final current = _current;
    if (current == null) return null;
    final user = _usersByEmail[current.email];
    if (user == null) return null;
    _current = _sessionFor(user);
    return _current;
  }

  @override
  Future<void> signOut() async => _emit(null);

  @override
  Future<String?> memberIdFor(String uid) async => _memberLinks[uid];

  @override
  Future<void> saveMemberId(String uid, String memberId) async {
    _memberLinks[uid] = memberId;
  }

  @override
  Future<void> syncProfile({String? displayName, String? memberId}) async {}
}

Future<AppState> _makeFirestoreState({
  required SplitNestRepository repository,
  FirebaseAuthService? firebaseAuth,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(
    repository: repository,
    firebaseAuth: firebaseAuth,
  )..refresh();
  await Future<void>.delayed(Duration.zero);
  return state;
}

void main() {
  group('computeBalances (Firestore-shaped data)', () {
    test('benchmark invariants: 4200 total, 84%, nets sum to zero', () {
      final members = [
        Member(id: 'M01', name: 'Ali'),
        Member(id: 'M02', name: 'Ayesha'),
        Member(id: 'M03', name: 'Bilal'),
      ];
      final balances = computeBalances(
        expenses: benchmarkExpenseRecords(),
        payments: const [],
        members: members,
        budgetPaisa: 500000,
      );
      expect(balances.totalSpending, '4200.00');
      expect(balances.budget, '5000.00');
      expect(balances.remaining, '800.00');
      expect(balances.usedPercent, 84);
      expect(balances.status, 'Near Limit');
      final nets = {
        for (final r in balances.rows) r.memberId: r.net,
      };
      expect(nets, {'M01': '250.00', 'M02': '-450.00', 'M03': '200.00'});
      final sum = balances.rows
          .map((r) => parsePaisa(r.net) ?? 0)
          .fold(0, (a, b) => a + b);
      expect(sum, 0);
      final paid = {
        for (final r in balances.rows) r.memberId: r.paid,
      };
      expect(paid, {'M01': '1800.00', 'M02': '900.00', 'M03': '1500.00'});
      final share = {
        for (final r in balances.rows) r.memberId: r.share,
      };
      expect(share, {'M01': '1550.00', 'M02': '1350.00', 'M03': '1300.00'});
    });

    test('settlements never change total spending', () {
      final members = [
        Member(id: 'M01', name: 'Ali'),
        Member(id: 'M02', name: 'Ayesha'),
        Member(id: 'M03', name: 'Bilal'),
      ];
      final expenses = benchmarkExpenseRecords();
      final before = computeBalances(
        expenses: expenses,
        payments: const [],
        members: members,
        budgetPaisa: 500000,
      );
      final after = computeBalances(
        expenses: expenses,
        payments: [
          PaymentRecord(
            id: 'P1',
            senderId: 'M02',
            recipientId: 'M01',
            amount: '250.00',
            status: 'recorded',
          ),
          PaymentRecord(
            id: 'P2',
            senderId: 'M02',
            recipientId: 'M03',
            amount: '200.00',
            status: 'verified',
          ),
        ],
        members: members,
        budgetPaisa: 500000,
      );
      expect(after.totalSpending, before.totalSpending);
      expect(
        {for (final r in after.rows) r.memberId: r.net},
        {'M01': '0.00', 'M02': '0.00', 'M03': '0.00'},
      );
    });

    test('split-map invariant: splits sum to amount, remainder in ID order',
        () {
      for (final spec in benchmarkExpenses) {
        final shares = spec.splitType == 'custom'
            ? spec.customSplits!.values.toList()
            : equalSplit(spec.amountPaisa, spec.splitMemberIds)
                .map((s) => s.amountPaisa)
                .toList();
        expect(
          shares.fold(0, (a, b) => a + b),
          spec.amountPaisa,
          reason: spec.title,
        );
      }
      // 1000.00 / 3: the first member in ascending ID order takes the
      // remainder paisa.
      final split = equalSplit(100000, ['M03', 'M01', 'M02']);
      expect(
        split.map((s) => (s.memberId, s.amountPaisa)).toList(),
        [
          ('M01', 33334),
          ('M02', 33333),
          ('M03', 33333),
        ],
      );
    });

    test('settlement validation rejects self, non-debtor, over-payment',
        () {
      const nets = {'M01': 25000, 'M02': -45000, 'M03': 20000};
      expect(
        settlementError(
          nets: nets,
          senderId: 'M02',
          recipientId: 'M02',
          amountPaisa: 1000,
        ),
        'Sender and recipient must be different.',
      );
      expect(
        settlementError(
          nets: nets,
          senderId: 'M01',
          recipientId: 'M02',
          amountPaisa: 1000,
        ),
        contains('not a debtor'),
      );
      expect(
        settlementError(
          nets: nets,
          senderId: 'M02',
          recipientId: 'M01',
          amountPaisa: 99999,
        ),
        contains('exceeds outstanding balance'),
      );
      expect(
        settlementError(
          nets: nets,
          senderId: 'M02',
          recipientId: 'M01',
          amountPaisa: 25000,
        ),
        isNull,
      );
      expect(
        settlementError(
          nets: nets,
          senderId: 'M02',
          recipientId: 'M01',
          amountPaisa: 0,
        ),
        contains('must be positive'),
      );
    });
  });

  group('Firestore document mapping (pure helpers)', () {
    test('expense doc: integer paisa, splits sum to amount', () {
      final data = expenseDocData(
        title: 'Test',
        category: 'General',
        amountPaisa: 100000,
        date: '2026-11-07',
        paidByKey: 'uid-ali',
        splitType: 'equal',
        splits: {'uid-ali': 33334, 'M02': 33333, 'M03': 33333},
        createdByUid: 'uid-ali',
      );
      expect(data['amountPaisa'], 100000);
      expect(data['amountPaisa'] is int, isTrue);
      final splits = data['splits'] as Map<String, int>;
      expect(splits.values.fold(0, (a, b) => a + b), 100000);
      expect(data['expenseDate'], isA<Timestamp>());
      expect(
        dateStringFromTimestamp(data['expenseDate'] as Timestamp),
        '2026-11-07',
      );
    });

    test('expense round-trips through doc data with UID keys', () {
      final data = expenseDocData(
        title: 'Internet Bill',
        category: 'Utilities',
        amountPaisa: 150000,
        date: '2026-11-07',
        paidByKey: 'uid-bilal',
        splitType: 'custom',
        splits: {'uid-ali': 50000, 'uid-ayesha': 30000, 'uid-bilal': 70000},
        createdByUid: 'uid-bilal',
      );
      final record = expenseRecordFromData(
        'E1',
        data.map((k, v) => MapEntry(k, v as dynamic)),
        (key) => switch (key) {
          'uid-ali' => 'M01',
          'uid-ayesha' => 'M02',
          'uid-bilal' => 'M03',
          _ => key,
        },
      );
      expect(record.title, 'Internet Bill');
      expect(record.amount, '1500.00');
      expect(record.payerId, 'M03');
      expect(record.date, '2026-11-07');
      expect(
        {for (final s in record.shares) s.memberId: s.amount},
        {'M01': '500.00', 'M02': '300.00', 'M03': '700.00'},
      );
    });

    test('payment and fixed-expense mapping round-trips', () {
      final payment = paymentRecordFromData(
        'P1',
        {
          'fromUid': 'uid-ayesha',
          'toUid': 'uid-ali',
          'amountPaisa': 25000,
          'status': 'recorded',
          'createdAt': Timestamp.fromDate(DateTime(2026, 11, 7)),
        },
        (key) => key == 'uid-ayesha' ? 'M02' : 'M01',
      );
      expect(payment.senderId, 'M02');
      expect(payment.recipientId, 'M01');
      expect(payment.amount, '250.00');
      expect(payment.status, 'recorded');
      final fixed = fixedExpenseFromData(
        'F1',
        {
          'title': 'Internet',
          'category': 'Utilities',
          'amountPaisa': 150000,
          'payerUid': 'uid-bilal',
          'splitMemberUids': ['uid-ali', 'uid-ayesha', 'uid-bilal'],
        },
        (key) => switch (key) {
          'uid-ali' => 'M01',
          'uid-ayesha' => 'M02',
          _ => 'M03',
        },
      );
      expect(fixed.title, 'Internet');
      expect(fixed.amount, '1500.00');
      expect(fixed.payerId, 'M03');
      expect(fixed.splitMemberIds, ['M01', 'M02', 'M03']);
    });

    test('timestamp helper round-trips a yyyy-MM-dd date', () {
      expect(dateStringFromTimestamp(timestampFromDateString('2026-11-07')),
          '2026-11-07');
      expect(dateStringFromTimestamp(timestampFromDateString('2027-01-04')),
          '2027-01-04');
    });
  });

  group('FakeSplitNestRepository (interface contract)', () {
    test('ensureGroup seeds the 3-member roster and PKR 5,000 budget',
        () async {
      final repo = FakeSplitNestRepository.empty();
      final info = await repo.ensureGroup(
        uid: 'uid-test',
        displayName: 'Test',
        email: 'test@example.com',
        legacyMemberId: 'M01',
        isDemo: false,
      );
      expect(info.budgetPaisa, 500000);
      final members = await repo.getMembers(info.groupId);
      expect(members.map((m) => m.id).toList(), ['M01', 'M02', 'M03']);
      expect(members.map((m) => m.name).toList(),
          ['Ali', 'Ayesha', 'Bilal']);
      expect(await repo.getExpenses(info.groupId), isEmpty);
      expect(await repo.getShopping(info.groupId), isEmpty);
    });

    test('loadDemoBenchmark seeds exactly the benchmark, once', () async {
      final repo = FakeSplitNestRepository.empty();
      const gid = FakeSplitNestRepository.groupId;
      var n = await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: 'demo-M01',
        actorName: 'Ali',
      );
      expect(n, 4);
      expect(repo.benchmarkLoaded, isTrue);
      expect((await repo.getExpenses(gid)).length, 4);
      expect((await repo.getFixedExpenses(gid)).length, 2);
      expect((await repo.getShopping(gid)).length, 2);
      final balances = computeBalances(
        expenses: await repo.getExpenses(gid),
        payments: const [],
        members: await repo.getMembers(gid),
        budgetPaisa: 500000,
      );
      expect(balances.totalSpending, '4200.00');
      expect(balances.usedPercent, 84);
      // Second load is a no-op — no duplicates.
      n = await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: 'demo-M01',
        actorName: 'Ali',
      );
      expect(n, 0);
      expect((await repo.getExpenses(gid)).length, 4);
      expect((await repo.getFixedExpenses(gid)).length, 2);
      // Seeded expenses are labelled demo.
      expect(
        (await repo.getExpenses(gid)).every((e) => e.isDemo),
        isTrue,
      );
    });

    test('checkout is atomic: failure changes nothing', () async {
      final repo = FakeSplitNestRepository.benchmark();
      const gid = FakeSplitNestRepository.groupId;
      final before = await repo.getExpenses(gid);
      // Second checkout of the same (already bought after the first)
      // items fails and posts no second expense.
      await repo.checkout(
        groupId: gid,
        itemIds: ['demo-shopping-milk', 'demo-shopping-rice'],
        totalPaid: '780.00',
        payerId: 'M01',
        splitMembers: ['M01', 'M02', 'M03'],
        actorUid: 'demo-M01',
      );
      expect((await repo.getExpenses(gid)).length, before.length + 1);
      final second = repo.checkout(
        groupId: gid,
        itemIds: ['demo-shopping-milk'],
        totalPaid: '10.00',
        payerId: 'M01',
        splitMembers: ['M01'],
        actorUid: 'demo-M01',
      );
      await expectLater(second, throwsA(isA<CloudDataException>()));
      expect((await repo.getExpenses(gid)).length, before.length + 1);
      expect(
        (await repo.getShopping(gid))
            .where((i) => i.id == 'demo-shopping-milk')
            .single
            .status,
        'Bought',
      );
      // Simulated mid-call failure: validation passed, but the write
      // throws before any mutation — items stay Pending, no expense.
      final fresh = FakeSplitNestRepository.empty();
      await fresh.addShopping(
        groupId: FakeSplitNestRepository.groupId,
        title: 'Tea',
        unit: 'pack',
        qty: 1,
        actorUid: 'demo-M01',
      );
      fresh.failNextCheckout = true;
      await expectLater(
        fresh.checkout(
          groupId: FakeSplitNestRepository.groupId,
          itemIds: [fresh.allShopping.single.id],
          totalPaid: '100.00',
          payerId: 'M01',
          splitMembers: ['M01', 'M02', 'M03'],
          actorUid: 'demo-M01',
        ),
        throwsA(isA<CloudDataException>()),
      );
      expect(fresh.allExpenses, isEmpty);
      expect(fresh.allShopping.single.status, 'Pending');
    });

    test('custom split mismatch is rejected and writes nothing', () async {
      final repo = FakeSplitNestRepository.empty();
      const gid = FakeSplitNestRepository.groupId;
      await expectLater(
        repo.addExpense(
          groupId: gid,
          title: 'Bad',
          category: 'Utilities',
          date: '2026-11-07',
          amount: '1500.00',
          payerId: 'M03',
          splitType: 'custom',
          splits: [
            {'member_id': 'M01', 'amount': '500.00'},
            {'member_id': 'M02', 'amount': '300.00'},
          ],
          actorUid: 'demo-M03',
        ),
        throwsA(isA<CloudDataException>()),
      );
      expect(await repo.getExpenses(gid), isEmpty);
    });

    test('payment recorded then verified; balances count it throughout',
        () async {
      final repo = FakeSplitNestRepository.benchmark();
      const gid = FakeSplitNestRepository.groupId;
      // Verification is owner/admin-only (Phase 5): establish the
      // actor's role first — the first ensureGroup caller owns the
      // group, a later caller joins as a plain member.
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
      final payment = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M01',
        amount: '250.00',
        actorUid: 'demo-M02',
      );
      expect(payment.status, 'recorded');
      // A plain member may record but never verify.
      await expectLater(
        repo.verifyPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M02',
        ),
        throwsA(isA<CloudDataException>()),
      );
      var balances = computeBalances(
        expenses: await repo.getExpenses(gid),
        payments: await repo.getPayments(gid),
        members: await repo.getMembers(gid),
        budgetPaisa: 500000,
      );
      expect(
        {for (final r in balances.rows) r.memberId: r.net},
        {'M01': '0.00', 'M02': '-200.00', 'M03': '200.00'},
      );
      expect(balances.totalSpending, '4200.00');
      final verified = await repo.verifyPayment(
        groupId: gid,
        paymentId: payment.id,
        actorUid: 'demo-M01',
      );
      expect(verified.status, 'verified');
      expect(verified.verifiedBy, 'demo-M01');
      balances = computeBalances(
        expenses: await repo.getExpenses(gid),
        payments: await repo.getPayments(gid),
        members: await repo.getMembers(gid),
        budgetPaisa: 500000,
      );
      expect(
        {for (final r in balances.rows) r.memberId: r.net},
        {'M01': '0.00', 'M02': '-200.00', 'M03': '200.00'},
      );
      // A verified payment cannot be verified again.
      await expectLater(
        repo.verifyPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M01',
        ),
        throwsA(isA<CloudDataException>()),
      );
      // Over-settlement is rejected.
      await expectLater(
        repo.recordPayment(
          groupId: gid,
          senderId: 'M02',
          recipientId: 'M03',
          amount: '9999.00',
          actorUid: 'demo-M02',
        ),
        throwsA(isA<CloudDataException>()),
      );
    });

    test('applyFixedExpense posts at most once per month', () async {
      final repo = FakeSplitNestRepository.benchmark();
      const gid = FakeSplitNestRepository.groupId;
      final first = await repo.applyFixedExpense(
        groupId: gid,
        id: 'demo-fixed-internet',
        actorUid: 'demo-M01',
      );
      expect(first.applied, isTrue);
      expect(first.expense, isNotNull);
      expect(first.expense!.title, 'Internet');
      final second = await repo.applyFixedExpense(
        groupId: gid,
        id: 'demo-fixed-internet',
        actorUid: 'demo-M01',
      );
      expect(second.applied, isFalse);
      expect(second.expense, isNull);
    });

    test('activity entries persist through the repository', () async {
      final repo = FakeSplitNestRepository.empty();
      const gid = FakeSplitNestRepository.groupId;
      await repo.logActivity(
        groupId: gid,
        entry: ActivityEntry(
          type: 'expense',
          title: 'Expense: Test',
          amount: '100.00',
          memberId: 'M01',
          detail: 'General',
          timestamp: DateTime(2026, 11, 7),
        ),
        actorUid: 'demo-M01',
      );
      final entries = await repo.getActivity(gid);
      expect(entries.length, 1);
      expect(entries.single.title, 'Expense: Test');
    });
  });

  group('FirestoreSplitNestRepository (FakeFirebaseFirestore)', () {
    late FakeFirebaseFirestore fake;
    late FirestoreSplitNestRepository repo;
    const uid = 'uid-ali';
    const gid = 'household-uid-ali';

    setUp(() {
      fake = FakeFirebaseFirestore();
      repo = FirestoreSplitNestRepository(firestore: fake);
    });

    Future<void> ensure() async {
      await repo.ensureGroup(
        uid: uid,
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
    }

    test('ensureGroup creates the group with roster + budget', () async {
      final info = await repo.ensureGroup(
        uid: uid,
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
      expect(info.groupId, gid);
      expect(info.budgetPaisa, 500000);
      final doc = await fake.collection('groups').doc(gid).get();
      expect(doc.exists, isTrue);
      expect(doc.data()?['budgetPaisa'], 500000);
      expect(doc.data()?['currency'], 'PKR');
      expect((doc.data()?['members'] as Map)[uid]['role'], 'owner');
      final members = await repo.getMembers(gid);
      expect(members.map((m) => m.id).toList(), ['M01', 'M02', 'M03']);
      // Second ensure is a no-op (same group, same budget).
      final again = await repo.ensureGroup(
        uid: uid,
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
      expect(again.groupId, gid);
    });

    test('addExpense stores integer paisa + UID-keyed splits', () async {
      await ensure();
      final expense = await repo.addExpense(
        groupId: gid,
        title: 'Round',
        category: 'General',
        date: '2026-11-07',
        amount: '1000.00',
        payerId: 'M01',
        splitType: 'equal',
        actorUid: uid,
      );
      expect(expense.amount, '1000.00');
      expect(
        {for (final s in expense.shares) s.memberId: s.amount},
        {'M01': '333.34', 'M02': '333.33', 'M03': '333.33'},
      );
      final snap =
          await fake.collection('groups/$gid/expenses').doc(expense.id).get();
      final data = snap.data()!;
      expect(data['amountPaisa'], 100000);
      expect(data['amountPaisa'] is int, isTrue);
      final splits = data['splits'] as Map<String, dynamic>;
      expect(
        splits.values.fold<int>(0, (a, b) => a + (b as int)),
        100000,
      );
      // The payer is stored under the creator's UID (rules key).
      expect(data['paidBy'], uid);
      expect(data['createdBy'], uid);
      // Reading it back maps the UID to the member id again.
      final back = await repo.getExpenses(gid);
      expect(back.single.payerId, 'M01');
      expect(back.single.shares.map((s) => s.memberId).toList(),
          ['M01', 'M02', 'M03']);
    });

    test('checkout posts one expense and marks items Bought, atomically',
        () async {
      await ensure();
      await repo.addShopping(
        groupId: gid,
        title: 'Milk',
        unit: 'bottle',
        qty: 2,
        actorUid: uid,
      );
      await repo.addShopping(
        groupId: gid,
        title: 'Rice',
        unit: 'pack',
        qty: 1,
        actorUid: uid,
      );
      final items = await repo.getShopping(gid);
      final expense = await repo.checkout(
        groupId: gid,
        itemIds: items.map((i) => i.id).toList(),
        totalPaid: '780.00',
        payerId: 'M01',
        splitMembers: ['M01', 'M02', 'M03'],
        actorUid: uid,
      );
      expect(expense.title, 'Shopping: Milk, Rice');
      expect(expense.category, 'Groceries');
      expect(expense.amount, '780.00');
      final after = await repo.getShopping(gid);
      expect(after.every((i) => i.status == 'Bought'), isTrue);
      expect((await repo.getExpenses(gid)).length, 1);
      // A second checkout of the same items fails and posts nothing.
      await expectLater(
        repo.checkout(
          groupId: gid,
          itemIds: [items.first.id],
          totalPaid: '10.00',
          payerId: 'M01',
          splitMembers: ['M01'],
          actorUid: uid,
        ),
        throwsA(isA<CloudDataException>()),
      );
      expect((await repo.getExpenses(gid)).length, 1);
    });

    test('loadDemoBenchmark seeds the benchmark once, labelled demo',
        () async {
      await ensure();
      var n = await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: uid,
        actorName: 'Ali',
      );
      expect(n, 4);
      final expenses = await repo.getExpenses(gid);
      expect(expenses.length, 4);
      expect(expenses.every((e) => e.isDemo), isTrue);
      expect((await repo.getFixedExpenses(gid)).length, 2);
      expect((await repo.getShopping(gid)).length, 2);
      final members = await repo.getMembers(gid);
      final balances = computeBalances(
        expenses: expenses,
        payments: const [],
        members: members,
        budgetPaisa: 500000,
      );
      expect(balances.totalSpending, '4200.00');
      expect(
        {for (final r in balances.rows) r.memberId: r.net},
        {'M01': '250.00', 'M02': '-450.00', 'M03': '200.00'},
      );
      n = await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: uid,
        actorName: 'Ali',
      );
      expect(n, 0);
      expect((await repo.getExpenses(gid)).length, 4);
    });

    test('recordPayment validates against the live ledger', () async {
      await ensure();
      await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: uid,
        actorName: 'Ali',
      );
      final payment = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M01',
        amount: '250.00',
        actorUid: 'uid-ayesha',
      );
      expect(payment.status, 'recorded');
      final verified = await repo.verifyPayment(
        groupId: gid,
        paymentId: payment.id,
        actorUid: uid,
      );
      expect(verified.status, 'verified');
      await expectLater(
        repo.recordPayment(
          groupId: gid,
          senderId: 'M02',
          recipientId: 'M03',
          amount: '9999.00',
          actorUid: 'uid-ayesha',
        ),
        throwsA(isA<CloudDataException>()),
      );
      await expectLater(
        repo.recordPayment(
          groupId: gid,
          senderId: 'M01',
          recipientId: 'M02',
          amount: '10.00',
          actorUid: uid,
        ),
        throwsA(isA<CloudDataException>()),
      );
    });

    test('applyFixedExpense posts at most once per month', () async {
      await ensure();
      await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: uid,
        actorName: 'Ali',
      );
      final first = await repo.applyFixedExpense(
        groupId: gid,
        id: 'demo-fixed-electricity',
        actorUid: uid,
      );
      expect(first.applied, isTrue);
      expect(first.expense?.title, 'Electricity');
      final second = await repo.applyFixedExpense(
        groupId: gid,
        id: 'demo-fixed-electricity',
        actorUid: uid,
      );
      expect(second.applied, isFalse);
    });

    test('activity entries persist and read back', () async {
      await ensure();
      await repo.logActivity(
        groupId: gid,
        entry: ActivityEntry(
          type: 'expense',
          title: 'Expense: Test',
          amount: '100.00',
          memberId: 'M01',
          detail: 'General',
          timestamp: DateTime(2026, 11, 7),
        ),
        actorUid: uid,
      );
      final entries = await repo.getActivity(gid);
      expect(entries.length, 1);
      expect(entries.single.title, 'Expense: Test');
    });
  });

  group('AppState on Firestore (email-only user end-to-end)', () {
    test('email-only user signs up, verifies, loads data, posts',
        () async {
      final fakeAuth = CompactFakeFirebaseAuth();
      final state = await _makeFirestoreState(
        repository: FakeSplitNestRepository.empty(),
        firebaseAuth: fakeAuth,
      );
      expect(state.firebaseAuthEnabled, isTrue);
      expect(state.isLoggedIn, isFalse);

      // Sign up: unverified, gated.
      final signedUp = await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'user@example.com',
        password: 'secret1',
        memberId: 'M02',
      );
      expect(signedUp, isTrue);
      expect(state.firebaseStatus, FirebaseAuthStatus.needsVerification);
      expect(state.isLoggedIn, isFalse);

      // Click the link, check again: verified, member applied, and —
      // the Phase 2 limit is gone — the household loads from
      // Firestore with no backend token involved.
      fakeAuth.verifyEmail('user@example.com');
      final checked = await state.refreshVerificationStatus();
      expect(checked, isTrue);
      expect(state.isLoggedIn, isTrue);
      expect(state.loggedInMemberId, 'M02');
      expect(state.balances, isNotNull);
      expect(state.balances!.totalSpending, '0.00');
      expect(state.balances!.budget, '5000.00');
      expect(state.members.map((m) => m.id).toList(), ['M01', 'M02', 'M03']);

      // Posting works for the email-only user too.
      final ok = await state.addExpense(
        title: 'Internet',
        category: 'Utilities',
        date: '2026-11-07',
        amount: '1500.00',
        payerId: 'M02',
        splitType: 'equal',
      );
      expect(ok, isTrue);
      expect(state.recentExpenses.length, 1);
      expect(state.balances!.totalSpending, '1500.00');

      // A settlement from the new ledger state validates: Ayesha now
      // owes (paid 1500, share 500 → net +1000? No: paid 1500,
      // share 500, net +1000 — she is owed, so she cannot be the
      // sender). The recorded payment below must come from a debtor.
      final bad = await state.settle(
        senderId: 'M02',
        recipientId: 'M01',
        amount: '100.00',
      );
      expect(bad, isFalse);
      expect(state.errorMessage, contains('not a debtor'));
    });

    test('cloud down: login succeeds, data shows unavailable, no crash',
        () async {
      final state = await _makeFirestoreState(
        repository: widget_helpers.ThrowingRepository(),
      );
      expect(state.isLoggedIn, isFalse);
      final ok = await state.loginWithDemo(memberId: 'M01');
      expect(ok, isTrue);
      expect(state.isLoggedIn, isTrue);
      expect(state.errorMessage, contains('Cloud data unavailable'));
      expect(state.balances, isNull);
      expect(state.recentExpenses, isEmpty);
      expect(state.members, isEmpty);
      // Retry still reports the same honest state.
      await state.refresh();
      expect(state.errorMessage, contains('Cloud data unavailable'));
      expect(state.balances, isNull);
    });

    test('non-demo user cannot load the demo benchmark', () async {
      final fakeAuth = CompactFakeFirebaseAuth();
      final state = await _makeFirestoreState(
        repository: FakeSplitNestRepository.empty(),
        firebaseAuth: fakeAuth,
      );
      await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'real@example.com',
        password: 'secret1',
        memberId: 'M01',
      );
      fakeAuth.verifyEmail('real@example.com');
      await state.refreshVerificationStatus();
      expect(state.isLoggedIn, isTrue);
      expect(state.isDemoUser, isFalse);
      final n = await state.loadDemoBenchmark();
      expect(n, 0);
      expect(state.recentExpenses, isEmpty);
    });
  });

  group('Demo benchmark (widget)', () {
    testWidgets('demo user loads the benchmark from Home', (tester) async {
      await widget_helpers.loginAs(
        tester,
        'Ali',
        repository: FakeSplitNestRepository.empty(),
      );
      // Empty household: the demo card offers the benchmark. Tap it
      // while it is on screen (the budget ring sits below the fold,
      // and scrolling back up would need a reversed drag).
      expect(find.text('Load demo benchmark'), findsOneWidget);
      await tester.tap(find.text('Load demo benchmark'));
      await tester.pumpAndSettle();
      expect(
          find.text('Loaded 4 demo benchmark expense(s).'), findsOneWidget);
      // The household is now the benchmark: 4200 spent, 84% used.
      // The budget ring sits below the fold on the test viewport, so
      // scroll it into view (ListView builds lazily) before asserting.
      await tester.scrollUntilVisible(find.text('Monthly Budget'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('4200.00'), findsWidgets);
      expect(find.text('84.0%'), findsOneWidget);
      // The card is gone once the benchmark is loaded.
      expect(find.text('Load demo benchmark'), findsNothing);
      // The seeded rows are labelled DEMO on the Expenses tab.
      await tester.tap(find.text('Expenses'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.text('Shopping: Milk, Rice · DEMO'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Shopping: Milk, Rice · DEMO'), findsOneWidget);
    });

    testWidgets('non-demo Google user never sees the benchmark action',
        (tester) async {
      await widget_helpers.pumpApp(
        tester,
        googleAuth: widget_helpers.FakeGoogleAuthService(
          const GoogleSignedIn(
            idToken: 'fake-id-token',
            email: 'test.user@gmail.com',
          ),
        ),
      );
      await tester.ensureVisible(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ali • M01'));
      await tester.pumpAndSettle();
      if (find.text('Got it').evaluate().isNotEmpty) {
        await tester.tap(find.text('Got it'));
        await tester.pumpAndSettle();
        if (find.text('Dismiss').evaluate().isNotEmpty) {
          await tester.tap(find.text('Dismiss'));
          await tester.pumpAndSettle();
        }
      }
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Load demo benchmark'), findsNothing);
    });

    testWidgets('recorded payment shows pending verification, then verifies',
        (tester) async {
      await widget_helpers.loginAs(tester, 'Ali');
      await tester.tap(find.text('Settle Up'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Settle Debt'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settle Debt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ayesha → Ali · up to PKR 250.00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record settlement'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm payment'));
      await tester.pumpAndSettle();
      expect(find.text('Settlement recorded.'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('Pending verification'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Pending verification'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();
      expect(find.text('Pending verification'), findsNothing);
    });
  });
}
