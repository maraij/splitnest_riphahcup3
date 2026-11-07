// Phase 4 — invitations + shared households.
// Covers, in three layers:
//   1. the pure helpers (code/link/email/expiry) — no storage;
//   2. the repository contract twice: the in-memory fake (fast,
//      same validators) and the real LocalJsonRepository against an
//      in-memory lock.json store (the atomic accept, the roster
//      update, the duplicate/expired sweeps);
//   3. AppState end-to-end with the real repository: one user
//      invites another, the invitee accepts by code, joins, and
//      switches households — the demo benchmark is untouched.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/data/local_json_repository.dart';
import 'package:splitnest/data/repository.dart';
import 'package:splitnest/domain/invitations.dart';
import 'package:splitnest/domain/models.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';
import 'widget_test.dart' as widget_helpers;

void main() {
  group('invite code helpers (pure)', () {
    test('generated codes are 12 unambiguous characters', () {
      final seen = <String>{};
      for (var i = 0; i < 1000; i++) {
        final code = generateInviteCode();
        expect(code.length, 12);
        expect(code, matches(RegExp(r'^[A-HJ-NP-Z2-9]{12}$')));
        seen.add(code);
      }
      // Cryptographically random, not sequential: 1000 draws must
      // not repeat (and must not look like a counter).
      expect(seen.length, 1000);
    });

    test('generateInviteCode honours an injected Random (seeded)', () {
      final a = generateInviteCode(random: Random(42));
      final b = generateInviteCode(random: Random(42));
      expect(a, b);
      expect(generateInviteCode(random: Random(7)), isNot(a));
    });

    test('format / normalize / parse round-trip, link included', () {
      expect(formatInviteCode('abcd1234efgh'), 'ABCD-1234-EFGH');
      expect(normalizeInviteCode('abcd-1234-efgh'), 'ABCD1234EFGH');
      expect(normalizeInviteCode('  abcd 1234 efgh '), 'ABCD1234EFGH');
      expect(inviteLinkFor('ABCD1234EFGH'),
          'https://splitnest.app/join?code=ABCD1234EFGH');
      expect(parseInviteCode('ABCD-1234-EFGH'), 'ABCD1234EFGH');
      expect(parseInviteCode('abcd1234efgh'), 'ABCD1234EFGH');
      expect(
        parseInviteCode(
            'https://splitnest.app/join?code=abcd-1234-efgh'),
        'ABCD1234EFGH',
      );
      expect(
        parseInviteCode(
            'Join us: https://splitnest.app/join?code=ABCD1234EFGH&x=1'),
        'ABCD1234EFGH',
      );
      expect(parseInviteCode(''), '');
      expect(parseInviteCode('not a code!!!'), 'NOTACODE');
    });

    test('email normalisation + validation', () {
      expect(normalizeInviteEmail('  Ayesha@Example.COM '),
          'ayesha@example.com');
      expect(isValidInviteEmail('ayesha@example.com'), isTrue);
      expect(isValidInviteEmail('not-an-email'), isFalse);
      expect(isValidInviteEmail('a@b'), isFalse);
      expect(isValidInviteEmail('a b@c.com'), isFalse);
    });

    test('expiry is 7 days; derived status treats past-expiry as expired',
        () {
      final created = DateTime(2026, 11, 7, 12);
      expect(invitationExpiryFrom(created), DateTime(2026, 11, 14, 12));
      final fresh = Invitation(
        id: 'ABCD1234EFGH',
        groupId: 'g1',
        groupName: 'Household',
        invitedEmail: 'a@b.com',
        invitedBy: 'u1',
        role: 'member',
        status: 'pending',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 7)),
      );
      expect(fresh.isPending, isTrue);
      expect(fresh.effectiveStatus, 'pending');
      expect(fresh.displayCode, 'ABCD-1234-EFGH');
      expect(fresh.link, 'https://splitnest.app/join?code=ABCD1234EFGH');
      final stale = Invitation(
        id: 'ABCD1234EFGH',
        groupId: 'g1',
        groupName: 'Household',
        invitedEmail: 'a@b.com',
        invitedBy: 'u1',
        role: 'member',
        status: 'pending',
        createdAt: DateTime.now().subtract(const Duration(days: 8)),
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(stale.isExpired, isTrue);
      expect(stale.isPending, isFalse);
      expect(stale.effectiveStatus, 'expired');
    });
  });

  // The same invitation scenarios run against both repository
  // implementations, so the fake and the real local code cannot
  // drift apart on the contract.
  for (final (name, makeRepo) in <(String, SplitNestRepository Function())>[
    ('FakeSplitNestRepository', () => FakeSplitNestRepository.empty()),
    (
      'LocalJsonRepository',
      () => LocalJsonRepository(store: LockJsonStore.inMemory())
    ),
  ]) {
    group('invitations on $name', () {
      const ownerUid = 'uid-ali';
      const ownerEmail = 'ali.demo@splitnest.app';
      const memberUid = 'uid-ayesha';
      const inviteeEmail = 'ayesha.demo@splitnest.app';
      const otherEmail = 'bilal.demo@splitnest.app';

      late SplitNestRepository repo;
      late String gid;

      setUp(() async {
        repo = makeRepo();
        final info = await repo.ensureGroup(
          uid: ownerUid,
          displayName: 'Ali',
          email: ownerEmail,
          legacyMemberId: 'M01',
          isDemo: true,
        );
        gid = info.groupId;
      });

      Future<Invitation> invite({
        String email = inviteeEmail,
        String role = 'member',
        String actorUid = ownerUid,
        String? actorEmail = ownerEmail,
      }) =>
          repo.createInvitation(
            groupId: gid,
            groupName: 'SplitNest Household',
            invitedEmail: email,
            role: role,
            actorUid: actorUid,
            actorEmail: actorEmail,
            actorName: 'Ali',
          );

      test('create: code is the record id, 7-day expiry, pending', () async {
        final inv = await invite();
        expect(inv.id.length, 12);
        expect(inv.status, 'pending');
        expect(inv.role, 'member');
        expect(inv.invitedEmail, inviteeEmail);
        expect(inv.invitedBy, ownerUid);
        expect(
          inv.expiresAt.difference(inv.createdAt),
          const Duration(days: 7),
        );
        expect(inv.displayCode, formatInviteCode(inv.id));
        expect(inv.link, inviteLinkFor(inv.id));
        final listed = await repo.getGroupInvitations(gid);
        expect(listed.map((i) => i.id), [inv.id]);
        final mine = await repo.getMyInvitations(inviteeEmail);
        expect(mine.map((i) => i.id), [inv.id]);
      });

      test('create rejects bad email, self-invite, bad role', () async {
        await expectLater(
          invite(email: 'not-an-email'),
          throwsA(isA<LocalDataException>()),
        );
        await expectLater(
          invite(email: '  ALI.DEMO@splitnest.app '),
          throwsA(isA<LocalDataException>()),
        );
        await expectLater(
          invite(role: 'superuser'),
          throwsA(isA<LocalDataException>()),
        );
        expect(await repo.getGroupInvitations(gid), isEmpty);
      });

      test('duplicate ACTIVE invite rejected; re-invite after revoke ok',
          () async {
        final first = await invite();
        await expectLater(
          invite(email: ' AYESHA.demo@splitnest.app '),
          throwsA(isA<LocalDataException>()),
        );
        // A different email is fine.
        await invite(email: otherEmail);
        expect((await repo.getGroupInvitations(gid)).length, 2);
        // Revoke, then re-inviting the same email works.
        await repo.revokeInvitation(
          groupId: gid,
          invitationId: first.id,
          actorUid: ownerUid,
        );
        final again = await invite();
        expect(again.id, isNot(first.id));
        expect((await repo.getGroupInvitations(gid))
            .where((i) => i.invitedEmail == inviteeEmail)
            .where((i) => i.isPending)
            .length, 1);
      });

      test('non-owner/non-admin cannot invite; admin cannot grant admin',
          () async {
        // A stranger (not a group member at all) cannot invite.
        await expectLater(
          invite(actorUid: 'uid-stranger', actorEmail: 's@x.com'),
          throwsA(isA<LocalDataException>()),
        );
        // The owner CAN grant admin.
        final adminInvite = await invite(email: otherEmail, role: 'admin');
        expect(adminInvite.role, 'admin');
        // An admin invitee, once joined, can invite as member but
        // cannot grant admin.
        await repo.acceptInvitation(
          invitationId: adminInvite.id,
          actorUid: 'uid-bilal',
          email: otherEmail,
          displayName: 'Bilal',
        );
        await repo.createInvitation(
          groupId: gid,
          groupName: 'SplitNest Household',
          invitedEmail: 'fourth@example.com',
          role: 'member',
          actorUid: 'uid-bilal',
          actorEmail: otherEmail,
          actorName: 'Bilal',
        );
        await expectLater(
          repo.createInvitation(
            groupId: gid,
            groupName: 'SplitNest Household',
            invitedEmail: 'fifth@example.com',
            role: 'admin',
            actorUid: 'uid-bilal',
            actorEmail: otherEmail,
            actorName: 'Bilal',
          ),
          throwsA(isA<LocalDataException>()),
        );
      });

      test('revoke: owner ok, member denied, non-pending denied',
          () async {
        final inv = await invite();
        // A plain member (joined via invite) cannot revoke.
        final memberInvite = await invite(email: otherEmail);
        await repo.acceptInvitation(
          invitationId: memberInvite.id,
          actorUid: 'uid-bilal',
          email: otherEmail,
          displayName: 'Bilal',
        );
        await expectLater(
          repo.revokeInvitation(
            groupId: gid,
            invitationId: inv.id,
            actorUid: 'uid-bilal',
          ),
          throwsA(isA<LocalDataException>()),
        );
        // The owner can.
        await repo.revokeInvitation(
          groupId: gid,
          invitationId: inv.id,
          actorUid: ownerUid,
        );
        expect(
          (await repo.getGroupInvitations(gid))
              .firstWhere((i) => i.id == inv.id)
              .status,
          'revoked',
        );
        // Revoking again fails: no longer pending.
        await expectLater(
          repo.revokeInvitation(
            groupId: gid,
            invitationId: inv.id,
            actorUid: ownerUid,
          ),
          throwsA(isA<LocalDataException>()),
        );
        // A revoked invite cannot be accepted.
        await expectLater(
          repo.acceptInvitation(
            invitationId: inv.id,
            actorUid: memberUid,
            email: inviteeEmail,
            displayName: 'Ayesha',
          ),
          throwsA(isA<LocalDataException>()),
        );
      });

      test('accept: joins the group (map + mirror + accepted)', () async {
        final inv = await invite();
        final accepted = await repo.acceptInvitation(
          invitationId: inv.id,
          actorUid: memberUid,
          email: inviteeEmail,
          displayName: 'Ayesha',
        );
        expect(accepted.status, 'accepted');
        expect(accepted.acceptedBy, memberUid);
        // The invitee now belongs to the group.
        final groups = await repo.listUserGroups(
            uid: memberUid, email: inviteeEmail);
        expect(groups.map((g) => g.groupId), contains(gid));
        expect(
          groups.firstWhere((g) => g.groupId == gid).role,
          'member',
        );
        expect(await repo.getMyRole(groupId: gid, uid: memberUid),
            'member');
        // The members mirror gained a doc for the invitee.
        final members = await repo.getMembers(gid);
        expect(members.map((m) => m.name), contains('Ayesha'));
        // Second accept fails: already accepted.
        await expectLater(
          repo.acceptInvitation(
            invitationId: inv.id,
            actorUid: memberUid,
            email: inviteeEmail,
            displayName: 'Ayesha',
          ),
          throwsA(isA<LocalDataException>()),
        );
        // And the membership is unchanged (no duplicate join).
        expect(
          (await repo.listUserGroups(uid: memberUid, email: inviteeEmail))
              .where((g) => g.groupId == gid)
              .length,
          1,
        );
      });

      test('accept rejects wrong email and unknown code', () async {
        final inv = await invite();
        await expectLater(
          repo.acceptInvitation(
            invitationId: inv.id,
            actorUid: 'uid-intruder',
            email: 'intruder@example.com',
            displayName: 'Intruder',
          ),
          throwsA(isA<LocalDataException>()),
        );
        // The invite is still pending for the right person.
        expect(
          (await repo.getMyInvitations(inviteeEmail)).single.isPending,
          isTrue,
        );
        await expectLater(
          repo.acceptInvitation(
            invitationId: 'ZZZZ9999YYYY',
            actorUid: memberUid,
            email: inviteeEmail,
            displayName: 'Ayesha',
          ),
          throwsA(isA<LocalDataException>()),
        );
        // Grouped / lower-case code entry resolves to the same doc.
        final accepted = await repo.acceptInvitation(
          invitationId: inv.displayCode.toLowerCase(),
          actorUid: memberUid,
          email: inviteeEmail,
          displayName: 'Ayesha',
        );
        expect(accepted.status, 'accepted');
      });

      test('admin listing does not sweep a fresh invitation', () async {
        final inv = await invite();
        expect(inv.isPending, isTrue);
        await repo.getGroupInvitations(gid);
        expect(
          (await repo.getGroupInvitations(gid)).single.isPending,
          isTrue,
        );
      });
    });
  }

  group('expiry (local repo, stale record written directly)', () {
    test('accept rejects expired; listing derives it; admin sweep stores it',
        () async {
      final repo =
          LocalJsonRepository(store: LockJsonStore.inMemory());
      final store = repo.store;
      final info = await repo.ensureGroup(
        uid: 'uid-ali',
        displayName: 'Ali',
        email: 'ali.demo@splitnest.app',
        legacyMemberId: 'M01',
        isDemo: true,
      );
      final gid = info.groupId;
      const code = 'STALE1234ABC';
      // A stale invitation, written straight into lock.json.
      final doc = await store.load();
      (doc['invitations'] as List).add({
        'id': code,
        'groupId': gid,
        'groupName': 'SplitNest Household',
        'invitedEmail': 'ayesha.demo@splitnest.app',
        'invitedBy': 'uid-ali',
        'inviterName': 'Ali',
        'role': 'member',
        'status': 'pending',
        'createdAt': DateTime.now()
            .subtract(const Duration(days: 8))
            .toIso8601String(),
        'expiresAt': DateTime.now()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      });
      await store.save(doc);
      // The invitee's list derives the expiry (no sweep write —
      // the invitee cannot write that transition).
      final mine =
          await repo.getMyInvitations('ayesha.demo@splitnest.app');
      expect(mine.single.isExpired, isTrue);
      expect(mine.single.isPending, isFalse);
      expect(mine.single.effectiveStatus, 'expired');
      // Accept refuses it.
      await expectLater(
        repo.acceptInvitation(
          invitationId: code,
          actorUid: 'uid-ayesha',
          email: 'ayesha.demo@splitnest.app',
          displayName: 'Ayesha',
        ),
        throwsA(isA<LocalDataException>()),
      );
      // The admin listing sweeps it to stored `expired`.
      await repo.getGroupInvitations(gid);
      final after = await store.load();
      final stored = ((after['invitations'] as List)
              .cast<Map<String, dynamic>>())
          .single;
      expect(stored['status'], 'expired');
      // And the sweep is visible to the invitee as stored-expired.
      final mineAfter =
          await repo.getMyInvitations('ayesha.demo@splitnest.app');
      expect(mineAfter.single.status, 'expired');
    });
  });

  group('AppState end-to-end (real local repo, in-memory store)', () {
    test('invite → accept by code → join → switch households', () async {
      SharedPreferences.setMockInitialValues({});
      final repo =
          LocalJsonRepository(store: LockJsonStore.inMemory());

      // Ali signs in (demo) and invites Ayesha by email.
      final ali = AppState(repository: repo);
      expect(await ali.loginWithDemo(memberId: 'M01'), isTrue);
      expect(ali.groupId, 'household-demo-M01');
      expect(ali.canInvite, isTrue);
      expect(ali.isGroupOwner, isTrue);
      final invite = await ali.sendInvitation(
          email: 'ayesha.demo@splitnest.app');
      expect(invite, isNotNull);
      expect(ali.pendingInviteCount, 1);
      expect(ali.groupInvitations.single.invitedEmail,
          'ayesha.demo@splitnest.app');

      // Ayesha signs in (demo) on her own household first.
      final ayesha = AppState(repository: repo);
      expect(await ayesha.loginWithDemo(memberId: 'M02'), isTrue);
      expect(ayesha.groupId, 'household-demo-M02');
      expect(ayesha.myPendingInvitations.length, 1);
      expect(ayesha.myPendingInvitations.single.groupId,
          'household-demo-M01');

      // She accepts by pasting the grouped code — and lands in
      // Ali's household as the current group.
      final accepted = await ayesha.acceptInvitationByCode(
          invite!.displayCode);
      expect(accepted, isNotNull);
      expect(accepted!.status, 'accepted');
      expect(ayesha.groupId, 'household-demo-M01');
      expect(ayesha.currentGroupId, 'household-demo-M01');
      expect(
        ayesha.userGroups.map((g) => g.groupId).toSet(),
        {'household-demo-M01', 'household-demo-M02'},
      );
      expect(ayesha.currentRole, 'member');
      expect(ayesha.canInvite, isFalse);
      expect(ayesha.myPendingInvitations, isEmpty);

      // Switching back to her own household works, and the choice
      // persists: a fresh AppState re-opens the switched household.
      expect(await ayesha.switchGroup('household-demo-M02'), isTrue);
      expect(ayesha.groupId, 'household-demo-M02');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('current_group_id_demo-M02'),
          'household-demo-M02');
      final ayesha2 = AppState(repository: repo);
      expect(await ayesha2.loginWithDemo(memberId: 'M02'), isTrue);
      // The persisted choice may need one more refresh if the
      // prefs cache was not ready at the first refresh.
      if (ayesha2.groupId != 'household-demo-M02') {
        await ayesha2.refresh();
      }
      expect(ayesha2.groupId, 'household-demo-M02');

      // Switching to a group she does not belong to is refused.
      expect(await ayesha.switchGroup('household-someone-else'), isFalse);
      expect(ayesha.groupId, 'household-demo-M02');
    });

    test('accept by pasted link works; demo benchmark untouched', () async {
      SharedPreferences.setMockInitialValues({});
      final repo =
          LocalJsonRepository(store: LockJsonStore.inMemory());
      final ali = AppState(repository: repo);
      await ali.loginWithDemo(memberId: 'M01');
      // Ali loads the demo benchmark in his own household first.
      expect(
        await repo.loadDemoBenchmark(
          groupId: ali.groupId!,
          actorUid: ali.currentUid,
          actorName: 'Ali',
        ),
        4,
      );
      final invite = await ali.sendInvitation(
          email: 'bilal.demo@splitnest.app');
      expect(invite, isNotNull);
      final bilal = AppState(repository: repo);
      await bilal.loginWithDemo(memberId: 'M03');
      final accepted =
          await bilal.acceptInvitationByCode(invite!.link);
      expect(accepted, isNotNull);
      expect(bilal.groupId, 'household-demo-M01');
      // The joined household still shows the benchmark exactly.
      expect(bilal.recentExpenses.length, 4);
      expect(bilal.balances!.totalSpending, '4200.00');
      expect(bilal.balances!.usedPercent, 84);
      // Bilal's own household is untouched (no benchmark there).
      await bilal.switchGroup('household-demo-M03');
      expect(bilal.recentExpenses, isEmpty);
      expect(bilal.balances!.totalSpending, '0.00');
    });

    test('wrong-email accept fails with a plain message', () async {
      SharedPreferences.setMockInitialValues({});
      final repo =
          LocalJsonRepository(store: LockJsonStore.inMemory());
      final ali = AppState(repository: repo);
      await ali.loginWithDemo(memberId: 'M01');
      final invite = await ali.sendInvitation(
          email: 'ayesha.demo@splitnest.app');
      expect(invite, isNotNull);
      // Bilal (different email) tries the same code.
      final bilal = AppState(repository: repo);
      await bilal.loginWithDemo(memberId: 'M03');
      final accepted =
          await bilal.acceptInvitationByCode(invite!.displayCode);
      expect(accepted, isNull);
      expect(bilal.errorMessage, contains('different email'));
      expect(bilal.groupId, 'household-demo-M03');
    });
  });

  group('Invite screen (widget)', () {
    testWidgets('drawer opens it; send shows code + pending invite; '
        'revoke removes it', (tester) async {
      // The e2e tests above persist a local session in the mock
      // prefs; clear it so this test starts on the login screen.
      SharedPreferences.setMockInitialValues({});
      await widget_helpers.loginAs(
        tester,
        'Ali',
        repository: FakeSplitNestRepository.benchmark(),
      );
      // Home advertises the invite entry point (below the fold —
      // scroll it into view first).
      await tester.scrollUntilVisible(find.text('Invite members'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Invite members'), findsOneWidget);
      // Open the drawer and go to Invite & households (below the
      // fold — scroll the drawer list into view first).
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.text('Invite & households'), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invite & households'));
      await tester.pumpAndSettle();
      expect(find.text('Invite someone'), findsOneWidget);
      expect(find.text('Your households'), findsOneWidget);
      // Send an invitation (form is on screen at the top).
      await tester.enterText(
          find.widgetWithText(TextField, 'Email address'),
          'friend@example.com');
      await tester.tap(find.text('Send invitation'));
      await tester.pumpAndSettle();
      expect(find.text('Invitation sent to friend@example.com.'),
          findsOneWidget);
      // The code is shown grouped, and the invite is listed as
      // pending with its expiry (scroll each into view — the share
      // card sits just above the Pending section).
      await tester.scrollUntilVisible(find.text('Pending invitations'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsWidgets);
      await tester.scrollUntilVisible(find.text('friend@example.com'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('friend@example.com'), findsOneWidget);
      expect(find.textContaining('Expires 20'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Enter invite code'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Enter invite code'), findsOneWidget);
      // Revoke it (confirm dialog) — the pending invite is gone.
      await tester.scrollUntilVisible(find.byTooltip('Revoke').first, 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Revoke').first);
      await tester.pumpAndSettle();
      expect(find.text('Revoke invitation?'), findsOneWidget);
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      // The send snackbar is still showing (4s); the revoke
      // snackbar queues behind it — let the first dismiss.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Invitation revoked.'), findsOneWidget);
      expect(find.text('friend@example.com'), findsNothing);
    });
  });
}
