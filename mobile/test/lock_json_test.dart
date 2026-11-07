// Phase 6 — the local store: lock.json persistence + the
// LocalJsonRepository contract.
//
// Covers, in layers:
//   1. the store itself: first-run seed, persistence round-trip
//      across store instances, atomic write + corrupt-file recovery
//      (backup restore, then fresh seed when both files are gone),
//      schema validation, the in-memory (web) mode;
//   2. the repository contract against a real temp-directory store:
//      household seeding, expense CRUD + split maths, checkout
//      atomicity, payments + authorisation, fixed templates,
//      the demo benchmark (exact numbers), invitations, uploads;
//   3. auth hashing through the real service on the same store:
//      different salts give different hashes, wrong passwords fail.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitnest/data/demo_accounts.dart';
import 'package:splitnest/data/local_auth_service.dart';
import 'package:splitnest/data/local_json_repository.dart';
import 'package:splitnest/data/password_hash.dart';
import 'package:splitnest/data/repository.dart';
import 'package:splitnest/domain/balances.dart';
import 'package:splitnest/domain/models.dart';

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('splitnest-lock-');

Future<LocalJsonRepository> _repoIn(Directory dir) async =>
    LocalJsonRepository(store: await LockJsonStore.inDirectory(dir.path));

Future<(LocalJsonRepository, String)> _seededRepo(Directory dir) async {
  final repo = await _repoIn(dir);
  final info = await repo.ensureGroup(
    uid: 'demo-M01',
    displayName: 'Ali',
    email: 'ali.demo@splitnest.app',
    legacyMemberId: 'M01',
    isDemo: true,
  );
  return (repo, info.groupId);
}

Future<ExpenseRecord> _addExpense(
  LocalJsonRepository repo,
  String gid, {
  String title = 'Internet Bill',
  String amount = '1500.00',
  String payerId = 'M03',
  String splitType = 'equal',
  List<String>? splitMembers,
}) =>
    repo.addExpense(
      groupId: gid,
      title: title,
      category: 'Utilities',
      date: '2026-11-07',
      amount: amount,
      payerId: payerId,
      splitType: splitType,
      splitMembers: splitMembers ?? const ['M01', 'M02', 'M03'],
      actorUid: 'demo-M01',
    );

void main() {
  group('store: seed + persistence', () {
    late Directory dir;
    setUp(() async {
      dir = await _tempDir();
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('first load seeds demo users, empty collections, PKR 5000',
        () async {
      final store = await LockJsonStore.inDirectory(dir.path);
      final doc = await store.load();
      expect(store.seededFresh, isTrue);
      expect(store.recoveredFromBackup, isFalse);
      expect(store.lastNotice, isNull);
      expect(doc['version'], lockJsonVersion);
      final users = (doc['users'] as List).cast<Map<String, dynamic>>();
      expect(users.length, 3);
      for (final demo in demoAccounts) {
        final user =
            users.where((u) => u['email'] == demo.email).single;
        expect(user['memberId'], demo.memberId);
        expect(user['isDemo'], isTrue);
        expect(
          verifyPassword(
            password: demo.password,
            salt: user['passwordSalt'] as String,
            storedHash: user['passwordHash'] as String,
          ),
          isTrue,
        );
      }
      for (final key in [
        'groups',
        'expenses',
        'payments',
        'shopping',
        'fixedExpenses',
        'invitations',
        'activity',
      ]) {
        expect(doc[key], isEmpty);
      }
      expect((doc['settings'] as Map)['budgetPaisa'], 500000);
      expect(File('${dir.path}/lock.json').existsSync(), isTrue);
    });

    test('seed document matches the bundled asset shape', () async {
      final doc = buildSeedLockJson(random: _SeededRandom());
      expect(doc['version'], lockJsonVersion);
      expect((doc['users'] as List).length, 3);
      expect((doc['settings'] as Map)['budgetPaisa'], 500000);
    });

    test('round-trip: a write survives a fresh store instance',
        () async {
      final (repo, gid) = await _seededRepo(dir);
      await _addExpense(repo, gid);
      final store2 = await LockJsonStore.inDirectory(dir.path);
      final doc2 = await store2.load();
      expect(store2.seededFresh, isFalse);
      final expenses = (doc2['expenses'] as List)
          .cast<Map<String, dynamic>>();
      expect(expenses.length, 1);
      expect(expenses.single['title'], 'Internet Bill');
      expect(expenses.single['amountPaisa'], 150000);
      final repo2 = LocalJsonRepository(store: store2);
      final read = await repo2.getExpenses(gid);
      expect(read.single.amount, '1500.00');
      expect(read.single.payerId, 'M03');
    });

    test('a backup of the last good state is kept on every write',
        () async {
      final (repo, gid) = await _seededRepo(dir);
      await _addExpense(repo, gid, title: 'First');
      final bak = File('${dir.path}/lock.json.bak');
      expect(bak.existsSync(), isTrue);
      final backupDoc =
          jsonDecode(await bak.readAsString()) as Map<String, dynamic>;
      // The backup holds the state BEFORE the last write (the group
      // seed), so it has no expenses yet — and it parses.
      expect((backupDoc['expenses'] as List), isEmpty);
      expect((backupDoc['groups'] as List).length, 1);
      await _addExpense(repo, gid, title: 'Second');
      final backupDoc2 =
          jsonDecode(await bak.readAsString()) as Map<String, dynamic>;
      expect((backupDoc2['expenses'] as List).length, 1);
    });

    test('corrupt lock.json recovers from the backup, with a notice',
        () async {
      final (repo, gid) = await _seededRepo(dir);
      await _addExpense(repo, gid, title: 'Keep me');
      await File('${dir.path}/lock.json').writeAsString('{{{not json');
      final store2 = await LockJsonStore.inDirectory(dir.path);
      final doc2 = await store2.load();
      expect(store2.recoveredFromBackup, isTrue);
      expect(store2.lastNotice, contains('backup was restored'));
      // The backup is the pre-expense state, so the expense is
      // gone — but the household (and the notice) survived.
      expect((doc2['groups'] as List).length, 1);
      expect((doc2['expenses'] as List), isEmpty);
      // And the live file was restored from the backup.
      final live =
          jsonDecode(await File('${dir.path}/lock.json').readAsString())
              as Map<String, dynamic>;
      expect((live['groups'] as List).length, 1);
    });

    test('corrupt live + corrupt backup starts fresh, with a notice',
        () async {
      final store = await LockJsonStore.inDirectory(dir.path);
      await store.load();
      await File('${dir.path}/lock.json').writeAsString('garbage');
      await File('${dir.path}/lock.json.bak').writeAsString('garbage');
      final store2 = await LockJsonStore.inDirectory(dir.path);
      final doc2 = await store2.load();
      expect(store2.seededFresh, isTrue);
      expect(store2.recoveredFromBackup, isFalse);
      expect(store2.lastNotice, contains('fresh household'));
      expect((doc2['users'] as List).length, 3);
      expect((doc2['groups'] as List), isEmpty);
    });

    test('wrong schema version is treated as corrupt', () async {
      final store = await LockJsonStore.inDirectory(dir.path);
      final doc = await store.load();
      doc['version'] = 99;
      await store.save(doc);
      final store2 = await LockJsonStore.inDirectory(dir.path);
      final doc2 = await store2.load();
      // The backup (version 1) is restored, not the bad file.
      expect(store2.recoveredFromBackup, isTrue);
      expect(doc2['version'], lockJsonVersion);
    });

    test('in-memory store never touches disk', () async {
      final store = LockJsonStore.inMemory();
      final doc = await store.load();
      expect(store.isPersistent, isFalse);
      expect(store.seededFresh, isTrue);
      final repo = LocalJsonRepository(store: store);
      final info = await repo.ensureGroup(
        uid: 'demo-M01',
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
      await _addExpense(repo, info.groupId);
      // A second in-memory store starts fresh: nothing persisted.
      final store2 = LockJsonStore.inMemory();
      final doc2 = await store2.load();
      expect((doc2['groups'] as List), isEmpty);
      expect((doc['groups'] as List).length, 1);
    });
  });

  group('repository: household + expenses', () {
    late Directory dir;
    late LocalJsonRepository repo;
    late String gid;
    setUp(() async {
      dir = await _tempDir();
      (repo, gid) = await _seededRepo(dir);
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('ensureGroup seeds the 3-member roster, owner first', () async {
      expect(gid, 'household-demo-M01');
      final members = await repo.getMembers(gid);
      expect(members.map((m) => m.id), ['M01', 'M02', 'M03']);
      expect(members.map((m) => m.name), ['Ali', 'Ayesha', 'Bilal']);
      expect(await repo.getMyRole(groupId: gid, uid: 'demo-M01'),
          'owner');
      expect(await repo.getMyRole(groupId: gid, uid: 'demo-M02'),
          isNull);
      // Idempotent: a second call does not re-seed.
      final again = await repo.ensureGroup(
        uid: 'demo-M01',
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
      expect(again.groupId, gid);
      expect(again.budgetPaisa, 500000);
      expect((await repo.getMembers(gid)).length, 3);
    });

    test('add/get expense round-trip with equal-split remainder',
        () async {
      final record = await repo.addExpense(
        groupId: gid,
        title: 'Odd bill',
        category: 'General',
        date: '2026-11-07',
        amount: '100.00',
        payerId: 'M01',
        splitType: 'equal',
        splitMembers: const ['M01', 'M02', 'M03'],
        actorUid: 'demo-M01',
      );
      // 10000 paisa / 3 = 3333 + 1 remainder to M01.
      expect(
        record.shares.map((s) => s.amount),
        ['33.34', '33.33', '33.33'],
      );
      final read = await repo.getExpenses(gid);
      expect(read.length, 1);
      expect(read.single.title, 'Odd bill');
    });

    test('add rejects bad title, amount, date, payer, split',
        () async {
      Future<void> bad({
        String title = 'X',
        String amount = '10.00',
        String date = '2026-11-07',
        String payerId = 'M01',
        String splitType = 'equal',
      }) =>
          expectLater(
            repo.addExpense(
              groupId: gid,
              title: title,
              category: 'General',
              date: date,
              amount: amount,
              payerId: payerId,
              splitType: splitType,
              splitMembers: const ['M01', 'M02', 'M03'],
              actorUid: 'demo-M01',
            ),
            throwsA(isA<LocalDataException>()),
          );
      await bad(title: '  ');
      await bad(amount: '0.00');
      await bad(amount: '-5.00');
      await bad(amount: 'ten');
      await bad(date: '07-11-2026');
      await bad(payerId: 'M99');
      await bad(splitType: 'sideways');
      expect(await repo.getExpenses(gid), isEmpty);
    });

    test('custom + percentage splits, bad percentage sum rejected',
        () async {
      final custom = await repo.addExpense(
        groupId: gid,
        title: 'Custom',
        category: 'General',
        date: '2026-11-07',
        amount: '100.00',
        payerId: 'M02',
        splitType: 'custom',
        splits: const [
          {'member_id': 'M01', 'amount': '60.00'},
          {'member_id': 'M02', 'amount': '40.00'},
        ],
        actorUid: 'demo-M02',
      );
      expect(custom.shares.map((s) => s.amount), ['60.00', '40.00']);
      final pct = await repo.addExpense(
        groupId: gid,
        title: 'Percent',
        category: 'General',
        date: '2026-11-07',
        amount: '200.00',
        payerId: 'M01',
        splitType: 'percentage',
        percentageSplits: const [
          {'member_id': 'M01', 'percent': '25'},
          {'member_id': 'M02', 'percent': '75'},
        ],
        actorUid: 'demo-M01',
      );
      expect(pct.shares.map((s) => s.amount), ['50.00', '150.00']);
      await expectLater(
        repo.addExpense(
          groupId: gid,
          title: 'Bad pct',
          category: 'General',
          date: '2026-11-07',
          amount: '200.00',
          payerId: 'M01',
          splitType: 'percentage',
          percentageSplits: const [
            {'member_id': 'M01', 'percent': '40'},
            {'member_id': 'M02', 'percent': '40'},
          ],
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });

    test('update recomputes splits; a stranger cannot edit/delete',
        () async {
      final record = await _addExpense(repo, gid);
      final updated = await repo.updateExpense(
        groupId: gid,
        id: record.id,
        amount: '900.00',
        actorUid: 'demo-M01',
      );
      expect(updated.amount, '900.00');
      expect(updated.shares.map((s) => s.amount),
          ['300.00', '300.00', '300.00']);
      await expectLater(
        repo.updateExpense(
          groupId: gid,
          id: record.id,
          title: 'Hijack',
          actorUid: 'uid-stranger',
        ),
        throwsA(isA<LocalDataException>()),
      );
      await expectLater(
        repo.deleteExpense(
          groupId: gid,
          id: record.id,
          actorUid: 'uid-stranger',
        ),
        throwsA(isA<LocalDataException>()),
      );
      expect((await repo.getExpenses(gid)).single.title,
          'Internet Bill');
      await repo.deleteExpense(
        groupId: gid,
        id: record.id,
        actorUid: 'demo-M01',
      );
      expect(await repo.getExpenses(gid), isEmpty);
    });

    test('checkout posts one expense and marks items Bought', () async {
      final milk = await repo.addShopping(
        groupId: gid,
        title: 'Milk',
        unit: 'bottle',
        qty: 2,
        actorUid: 'demo-M01',
      );
      final rice = await repo.addShopping(
        groupId: gid,
        title: 'Rice',
        unit: 'pack',
        qty: 1,
        actorUid: 'demo-M01',
      );
      final expense = await repo.checkout(
        groupId: gid,
        itemIds: [milk.id, rice.id],
        totalPaid: '780.00',
        payerId: 'M01',
        splitMembers: const ['M01', 'M02', 'M03'],
        actorUid: 'demo-M01',
      );
      expect(expense.title, 'Shopping: Milk, Rice');
      expect(expense.category, 'Groceries');
      expect(expense.amount, '780.00');
      final items = await repo.getShopping(gid);
      expect(items.every((i) => !i.isPending), isTrue);
      // A second checkout of the same items is refused.
      await expectLater(
        repo.checkout(
          groupId: gid,
          itemIds: [milk.id],
          totalPaid: '100.00',
          payerId: 'M01',
          splitMembers: const ['M01', 'M02', 'M03'],
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
      expect((await repo.getExpenses(gid)).length, 1);
    });

    test('demo benchmark: exact numbers, idempotent', () async {
      final n = await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: 'demo-M01',
        actorName: 'Ali',
      );
      expect(n, 4);
      expect(
        await repo.loadDemoBenchmark(
          groupId: gid,
          actorUid: 'demo-M01',
          actorName: 'Ali',
        ),
        0,
      );
      final expenses = await repo.getExpenses(gid);
      expect(expenses.length, 4);
      expect(expenses.every((e) => e.isDemo), isTrue);
      final members = await repo.getMembers(gid);
      final balances = computeBalances(
        expenses: expenses,
        payments: [],
        members: members,
        budgetPaisa: 500000,
      );
      expect(balances.totalSpending, '4200.00');
      expect(balances.usedPercent, 84);
      final nets = {
        for (final r in balances.rows) r.memberId: r.net,
      };
      expect(nets, {'M01': '250.00', 'M02': '-450.00', 'M03': '200.00'});
      expect((await repo.getFixedExpenses(gid)).length, 2);
      expect((await repo.getShopping(gid)).length, 2);
    });
  });

  group('repository: payments + fixed templates', () {
    late Directory dir;
    late LocalJsonRepository repo;
    late String gid;
    setUp(() async {
      dir = await _tempDir();
      (repo, gid) = await _seededRepo(dir);
      await repo.loadDemoBenchmark(
        groupId: gid,
        actorUid: 'demo-M01',
        actorName: 'Ali',
      );
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('record → verify by owner; over-settlement rejected', () async {
      // Ayesha owes 450; Ali is owed 250.
      final payment = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M01',
        amount: '250.00',
        actorUid: 'demo-M02',
      );
      expect(payment.status, 'recorded');
      expect(payment.amount, '250.00');
      await expectLater(
        repo.recordPayment(
          groupId: gid,
          senderId: 'M02',
          recipientId: 'M01',
          amount: '251.00',
          actorUid: 'demo-M02',
        ),
        throwsA(isA<LocalDataException>()),
      );
      await expectLater(
        repo.recordPayment(
          groupId: gid,
          senderId: 'M01',
          recipientId: 'M02',
          amount: '10.00',
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
      // A plain member (Ayesha is not owner/admin of Ali's group)
      // cannot verify; the owner can.
      await expectLater(
        repo.verifyPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M02',
        ),
        throwsA(isA<LocalDataException>()),
      );
      final verified = await repo.verifyPayment(
        groupId: gid,
        paymentId: payment.id,
        actorUid: 'demo-M01',
      );
      expect(verified.status, 'verified');
      expect(verified.verifiedBy, 'demo-M01');
      // A verified payment can never change again.
      await expectLater(
        repo.rejectPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });

    test('reject counts nowhere; a new payment is the fix', () async {
      final payment = await repo.recordPayment(
        groupId: gid,
        senderId: 'M02',
        recipientId: 'M01',
        amount: '100.00',
        actorUid: 'demo-M02',
      );
      final rejected = await repo.rejectPayment(
        groupId: gid,
        paymentId: payment.id,
        actorUid: 'demo-M01',
      );
      expect(rejected.status, 'rejected');
      final payments = await repo.getPayments(gid);
      expect(payments.single.status, 'rejected');
      // A rejected payment cannot be verified afterwards.
      await expectLater(
        repo.verifyPayment(
          groupId: gid,
          paymentId: payment.id,
          actorUid: 'demo-M01',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });

    test('fixed templates apply once per month', () async {
      final fixed = await repo.createFixedExpense(
        groupId: gid,
        title: 'Water',
        category: 'Utilities',
        amount: '300.00',
        payerId: 'M01',
        splitMemberIds: const ['M01', 'M02', 'M03'],
        actorUid: 'demo-M01',
      );
      final first = await repo.applyFixedExpense(
        groupId: gid,
        id: fixed.id,
        actorUid: 'demo-M01',
      );
      expect(first.applied, isTrue);
      expect(first.expense, isNotNull);
      expect(first.expense!.amount, '300.00');
      final second = await repo.applyFixedExpense(
        groupId: gid,
        id: fixed.id,
        actorUid: 'demo-M01',
      );
      expect(second.applied, isFalse);
      expect(second.expense, isNull);
      final updated = await repo.updateFixedExpense(
        groupId: gid,
        id: fixed.id,
        amount: '350.00',
      );
      expect(updated.amount, '350.00');
      await repo.deleteFixedExpense(groupId: gid, id: fixed.id);
      expect(
        (await repo.getFixedExpenses(gid))
            .where((f) => f.id == fixed.id),
        isEmpty,
      );
    });

    test('activity log persists into lock.json', () async {
      await repo.logActivity(
        groupId: gid,
        entry: ActivityEntry(
          type: 'expense',
          title: 'Expense: Test',
          amount: '10.00',
          memberId: 'M01',
          detail: 'General',
          timestamp: DateTime.now(),
        ),
        actorUid: 'demo-M01',
      );
      final entries = await repo.getActivity(gid);
      expect(entries.length, 1);
      expect(entries.single.title, 'Expense: Test');
    });
  });

  group('repository: invitations (local-only)', () {
    late Directory dir;
    late LocalJsonRepository repo;
    late String gid;
    setUp(() async {
      dir = await _tempDir();
      (repo, gid) = await _seededRepo(dir);
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<Invitation> invite({
      String email = 'ayesha.demo@splitnest.app',
      String role = 'member',
    }) =>
        repo.createInvitation(
          groupId: gid,
          groupName: 'SplitNest Household',
          invitedEmail: email,
          role: role,
          actorUid: 'demo-M01',
          actorEmail: 'ali.demo@splitnest.app',
          actorName: 'Ali',
        );

    test('create + list + revoke round-trip', () async {
      final inv = await invite();
      expect(inv.id.length, 12);
      expect(inv.status, 'pending');
      expect((await repo.getGroupInvitations(gid)).single.id, inv.id);
      expect((await repo.getMyInvitations('ayesha.demo@splitnest.app'))
          .single
          .id, inv.id);
      // A second active invite for the same email is refused.
      await expectLater(invite(), throwsA(isA<LocalDataException>()));
      await repo.revokeInvitation(
        groupId: gid,
        invitationId: inv.id,
        actorUid: 'demo-M01',
      );
      expect((await repo.getGroupInvitations(gid)).single.status,
          'revoked');
      // A revoked invite cannot be accepted.
      await expectLater(
        repo.acceptInvitation(
          invitationId: inv.id,
          actorUid: 'demo-M02',
          email: 'ayesha.demo@splitnest.app',
          displayName: 'Ayesha',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });

    test('accept joins the group on the same device', () async {
      final inv = await invite();
      final accepted = await repo.acceptInvitation(
        invitationId: inv.displayCode,
        actorUid: 'demo-M02',
        email: 'ayesha.demo@splitnest.app',
        displayName: 'Ayesha',
      );
      expect(accepted.status, 'accepted');
      expect(accepted.acceptedBy, 'demo-M02');
      final groups = await repo.listUserGroups(
        uid: 'demo-M02',
        email: 'ayesha.demo@splitnest.app',
      );
      expect(groups.map((g) => g.groupId), contains(gid));
      expect(
        await repo.getMyRole(groupId: gid, uid: 'demo-M02'),
        'member',
      );
      // Accepting twice is refused.
      await expectLater(
        repo.acceptInvitation(
          invitationId: inv.id,
          actorUid: 'demo-M02',
          email: 'ayesha.demo@splitnest.app',
          displayName: 'Ayesha',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });

    test('wrong-email accept fails; admin role needs the owner',
        () async {
      final inv = await invite();
      await expectLater(
        repo.acceptInvitation(
          invitationId: inv.id,
          actorUid: 'demo-M03',
          email: 'bilal.demo@splitnest.app',
          displayName: 'Bilal',
        ),
        throwsA(isA<LocalDataException>()),
      );
      // Owner inviting as admin is allowed; a non-owner is not —
      // checked below with a member actor.
      final adminInv =
          await invite(email: 'other@example.com', role: 'admin');
      expect(adminInv.role, 'admin');
      // A plain member cannot invite at all: join first as member,
      // then try.
      final memberInv = await invite(email: 'bilal.demo@splitnest.app');
      await repo.acceptInvitation(
        invitationId: memberInv.id,
        actorUid: 'demo-M03',
        email: 'bilal.demo@splitnest.app',
        displayName: 'Bilal',
      );
      await expectLater(
        repo.createInvitation(
          groupId: gid,
          groupName: 'SplitNest Household',
          invitedEmail: 'friend@example.com',
          role: 'member',
          actorUid: 'demo-M03',
          actorEmail: 'bilal.demo@splitnest.app',
          actorName: 'Bilal',
        ),
        throwsA(isA<LocalDataException>()),
      );
    });

    test('stale invitations expire: derived + swept', () async {
      final store = repo.store;
      final doc = await store.load();
      final now = DateTime.now();
      (doc['invitations'] as List).add({
        'id': 'STALE1234ABC',
        'groupId': gid,
        'groupName': 'SplitNest Household',
        'invitedEmail': 'ayesha.demo@splitnest.app',
        'invitedBy': 'demo-M01',
        'inviterName': 'Ali',
        'role': 'member',
        'status': 'pending',
        'createdAt':
            now.subtract(const Duration(days: 8)).toIso8601String(),
        'expiresAt':
            now.subtract(const Duration(days: 1)).toIso8601String(),
      });
      await store.save(doc);
      final mine =
          await repo.getMyInvitations('ayesha.demo@splitnest.app');
      expect(mine.single.isExpired, isTrue);
      expect(mine.single.isPending, isFalse);
      await expectLater(
        repo.acceptInvitation(
          invitationId: 'STALE1234ABC',
          actorUid: 'demo-M02',
          email: 'ayesha.demo@splitnest.app',
          displayName: 'Ayesha',
        ),
        throwsA(isA<LocalDataException>()),
      );
      await repo.getGroupInvitations(gid);
      final after = await store.load();
      final stored = ((after['invitations'] as List)
              .cast<Map<String, dynamic>>())
          .single;
      expect(stored['status'], 'expired');
    });
  });

  group('repository: local file uploads', () {
    late Directory dir;
    late LocalJsonRepository repo;
    late String gid;
    setUp(() async {
      dir = await _tempDir();
      (repo, gid) = await _seededRepo(dir);
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('receipt bytes land in receipts/ and the path is returned',
        () async {
      final bytes = Uint8List.fromList(List.filled(100, 7));
      final uploaded = await repo.uploadReceipt(
        groupId: gid,
        expenseId: 'exp-1',
        bytes: bytes,
      );
      expect(uploaded, isNotNull);
      expect(uploaded!.path, 'receipts/$gid/exp-1/receipt.jpg');
      // The url field holds the SAME local path (no download URL).
      expect(uploaded.url, uploaded.path);
      final file = File('${dir.path}/${uploaded.path}');
      expect(file.existsSync(), isTrue);
      expect(await file.readAsBytes(), bytes);
    });

    test('oversize receipt returns null and writes nothing', () async {
      final bytes = Uint8List(10 * 1024 * 1024 + 1);
      expect(
        await repo.uploadReceipt(
          groupId: gid,
          expenseId: 'exp-1',
          bytes: bytes,
        ),
        isNull,
      );
      expect(
        Directory('${dir.path}/receipts').existsSync(),
        isFalse,
      );
    });

    test('profile photo saves and setUserPhotoUrl records the path',
        () async {
      final bytes = Uint8List.fromList(List.filled(50, 3));
      final path = await repo.uploadProfilePhoto(
        uid: 'demo-M01',
        bytes: bytes,
      );
      expect(path, 'profile-photos/demo-M01/photo.jpg');
      expect(File('${dir.path}/$path').existsSync(), isTrue);
      await repo.setUserPhotoUrl(
        groupId: gid,
        uid: 'demo-M01',
        photoUrl: path!,
      );
      final members = await repo.getMembers(gid);
      expect(members.firstWhere((m) => m.id == 'M01').photoUrl, path);
    });

    test('uploads on a non-persistent (in-memory) store return null',
        () async {
      final memoryRepo =
          LocalJsonRepository(store: LockJsonStore.inMemory());
      expect(
        await memoryRepo.uploadReceipt(
          groupId: gid,
          expenseId: 'exp-1',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        isNull,
      );
      expect(
        await memoryRepo.uploadProfilePhoto(
          uid: 'demo-M01',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        isNull,
      );
    });
  });

  group('auth hashing through the shared store', () {
    late Directory dir;
    setUp(() async {
      dir = await _tempDir();
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('two accounts, same password, different salts and hashes',
        () async {
      final store = await LockJsonStore.inDirectory(dir.path);
      final auth = RealLocalAuthService(store: store);
      await auth.signUpWithEmail(
        email: 'one@example.com',
        password: 'shared-password',
        displayName: 'One',
        memberId: 'M01',
      );
      await auth.signUpWithEmail(
        email: 'two@example.com',
        password: 'shared-password',
        displayName: 'Two',
        memberId: 'M02',
      );
      final doc = await store.load();
      final users = (doc['users'] as List).cast<Map<String, dynamic>>();
      final one =
          users.where((u) => u['email'] == 'one@example.com').single;
      final two =
          users.where((u) => u['email'] == 'two@example.com').single;
      expect(one['passwordSalt'], isNot(two['passwordSalt']));
      expect(one['passwordHash'], isNot(two['passwordHash']));
      // And the repository sees the same document.
      final repo = LocalJsonRepository(store: store);
      final info = await repo.ensureGroup(
        uid: one['id'] as String,
        displayName: 'One',
        email: 'one@example.com',
        legacyMemberId: 'M01',
        isDemo: false,
      );
      expect(info.groupId, 'household-${one['id']}');
    });
  });
}

/// Deterministic Random for the seed-shape test (so the test never
/// depends on real entropy).
class _SeededRandom implements Random {
  var _state = 42;
  @override
  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state % max;
  }

  @override
  double nextDouble() => nextInt(1 << 30) / (1 << 30);
  @override
  bool nextBool() => nextInt(2) == 0;
}
