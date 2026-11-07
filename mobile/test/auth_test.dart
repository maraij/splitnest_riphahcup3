// Phase 6 — local-only auth (lock.json accounts, salted hashes).
//
// Covers, in three layers:
//   1. the pure password hashing (salt/hash/verify) — no store;
//   2. RealLocalAuthService against an in-memory store: sign-up,
//      sign-in, demo sign-in, session restore, sign-out, and the
//      device-local password reset (on-device code, no email);
//   3. AppState end-to-end with the fake repository: the login /
//      sign-up / demo / reset flows through the store, plus session
//      restore across AppState instances sharing one auth service.
//
// There is no verification step any more (no mail backend) and no
// third-party sign-in — sign-up signs in directly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/data/demo_accounts.dart';
import 'package:splitnest/data/local_auth_service.dart';
import 'package:splitnest/data/local_json_repository.dart';
import 'package:splitnest/data/password_hash.dart';
import 'package:splitnest/main.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';

RealLocalAuthService _service() =>
    RealLocalAuthService(store: LockJsonStore.inMemory());

Future<void> _settle() async {
  // Lets unawaited background work (e.g. the persisted session
  // uid) finish before the next assertion reads it.
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  group('password hashing (pure)', () {
    test('same password + different salts -> different hashes', () {
      const password = 'same-password-123';
      final saltA = generateSalt();
      final saltB = generateSalt();
      expect(saltA, isNot(saltB));
      expect(saltA.length, 32);
      expect(saltB.length, 32);
      final hashA = hashPassword(password, saltA);
      final hashB = hashPassword(password, saltB);
      expect(hashA, isNot(hashB));
      expect(hashA.length, 64);
      expect(verifyPassword(
          password: password, salt: saltA, storedHash: hashA), isTrue);
      expect(verifyPassword(
          password: password, salt: saltB, storedHash: hashA), isFalse);
      expect(verifyPassword(
          password: 'wrong', salt: saltA, storedHash: hashA), isFalse);
    });

    test('generateSalt is random, not sequential', () {
      final salts = {
        for (var i = 0; i < 100; i++) generateSalt(),
      };
      expect(salts.length, 100);
    });
  });

  group('RealLocalAuthService (in-memory store)', () {
    late RealLocalAuthService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = _service();
    });

    test('demo accounts are seeded: all three sign in', () async {
      for (final demo in demoAccounts) {
        final result = await service.signInDemo(demo);
        expect(result, isA<LocalAuthSuccess>());
        final session = (result as LocalAuthSuccess).session!;
        expect(session.uid, demoUidForMember(demo.memberId));
        expect(session.email, demo.email);
        expect(session.isDemo, isTrue);
        expect(session.memberId, demo.memberId);
      }
    });

    test('sign-up creates the account and signs in directly', () async {
      final result = await service.signUpWithEmail(
        email: '  Talha@Example.COM ',
        password: 'secret123',
        displayName: 'Talha',
        memberId: 'M01',
      );
      expect(result, isA<LocalAuthSuccess>());
      final session = (result as LocalAuthSuccess).session!;
      expect(session.email, 'talha@example.com');
      expect(session.displayName, 'Talha');
      expect(session.isDemo, isFalse);
      expect(session.memberId, 'M01');
      expect(await service.memberIdFor(session.uid), 'M01');
      // The stored record holds a salt + hash, never the password.
      final doc = await service.store.load();
      final users = (doc['users'] as List).cast<Map<String, dynamic>>();
      final stored =
          users.where((u) => u['id'] == session.uid).single;
      expect(stored['passwordSalt'], isNotNull);
      expect(stored['passwordHash'], isNotNull);
      expect(stored['passwordHash'], isNot(contains('secret123')));
      expect(
        verifyPassword(
          password: 'secret123',
          salt: stored['passwordSalt'] as String,
          storedHash: stored['passwordHash'] as String,
        ),
        isTrue,
      );
    });

    test('sign-up rejects duplicates, bad emails, short passwords',
        () async {
      var result = await service.signUpWithEmail(
        email: 'user@example.com',
        password: 'secret123',
        displayName: 'User',
        memberId: 'M02',
      );
      expect(result, isA<LocalAuthSuccess>());
      result = await service.signUpWithEmail(
        email: 'USER@example.com',
        password: 'other123',
        displayName: 'Other',
        memberId: 'M03',
      );
      expect(result, isA<LocalAuthFailure>());
      expect((result as LocalAuthFailure).message,
          contains('already exists'));
      result = await service.signUpWithEmail(
        email: 'not-an-email',
        password: 'secret123',
        displayName: 'User',
        memberId: 'M02',
      );
      expect(result, isA<LocalAuthFailure>());
      result = await service.signUpWithEmail(
        email: 'new@example.com',
        password: 'short',
        displayName: 'User',
        memberId: 'M02',
      );
      expect(result, isA<LocalAuthFailure>());
      expect((result as LocalAuthFailure).message,
          contains('at least 6 characters'));
    });

    test('sign-in: wrong password and unknown email share one message',
        () async {
      await service.signUpWithEmail(
        email: 'user@example.com',
        password: 'secret123',
        displayName: 'User',
        memberId: 'M02',
      );
      const message = 'That email or password is not correct.';
      var result = await service.signInWithEmail(
        email: 'user@example.com',
        password: 'wrong-password',
      );
      expect(result, isA<LocalAuthFailure>());
      expect((result as LocalAuthFailure).message, contains(message));
      result = await service.signInWithEmail(
        email: 'nobody@example.com',
        password: 'secret123',
      );
      expect(result, isA<LocalAuthFailure>());
      expect((result as LocalAuthFailure).message, contains(message));
      result = await service.signInWithEmail(
        email: 'user@example.com',
        password: 'secret123',
      );
      expect(result, isA<LocalAuthSuccess>());
    });

    test('sign-out clears the session and emits null', () async {
      final seen = <LocalSession?>[];
      final sub = service.authStateChanges.listen(seen.add);
      await service.signInDemo(demoAccounts.first);
      expect(service.currentSession, isNotNull);
      await service.signOut();
      await _settle();
      expect(service.currentSession, isNull);
      expect(seen.last, isNull);
      await sub.cancel();
    });

    test('session restores from the persisted uid', () async {
      await service.signUpWithEmail(
        email: 'user@example.com',
        password: 'secret123',
        displayName: 'User',
        memberId: 'M02',
      );
      await _settle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('local_session_uid'), isNotNull);
      // A second service over the SAME store restores the session.
      final service2 = RealLocalAuthService(store: service.store);
      final restored = await service2.restoreSession();
      expect(restored, isNotNull);
      expect(restored!.email, 'user@example.com');
      expect(restored.memberId, 'M02');
    });

    test('restore returns null when nothing was persisted', () async {
      final restored = await service.restoreSession();
      expect(restored, isNull);
    });

    test('device-local reset: code on device, single-use, signs in',
        () async {
      await service.signUpWithEmail(
        email: 'user@example.com',
        password: 'old-password',
        displayName: 'User',
        memberId: 'M02',
      );
      // Unknown email: no code (null), nothing to enumerate.
      expect(
        await service.requestPasswordReset(email: 'nobody@example.com'),
        isNull,
      );
      final code = await service.requestPasswordReset(
          email: 'user@example.com');
      expect(code, isNotNull);
      expect(code!.length, 6);
      expect(int.tryParse(code), isNotNull);
      // Wrong code is rejected; the old password still works.
      var result = await service.resetPasswordWithCode(
        email: 'user@example.com',
        code: '000000',
        newPassword: 'new-password',
      );
      expect(result, isA<LocalAuthFailure>());
      result = await service.signInWithEmail(
        email: 'user@example.com',
        password: 'old-password',
      );
      expect(result, isA<LocalAuthSuccess>());
      // Right code resets, signs in, and is single-use.
      result = await service.resetPasswordWithCode(
        email: 'user@example.com',
        code: code,
        newPassword: 'new-password',
      );
      expect(result, isA<LocalAuthSuccess>());
      expect((result as LocalAuthSuccess).session!.email,
          'user@example.com');
      await service.signOut();
      result = await service.signInWithEmail(
        email: 'user@example.com',
        password: 'old-password',
      );
      expect(result, isA<LocalAuthFailure>());
      result = await service.signInWithEmail(
        email: 'user@example.com',
        password: 'new-password',
      );
      expect(result, isA<LocalAuthSuccess>());
      result = await service.resetPasswordWithCode(
        email: 'user@example.com',
        code: code,
        newPassword: 'another-one',
      );
      expect(result, isA<LocalAuthFailure>());
    });

    test('reset rejects a short new password', () async {
      await service.signUpWithEmail(
        email: 'user@example.com',
        password: 'old-password',
        displayName: 'User',
        memberId: 'M02',
      );
      final code = (await service.requestPasswordReset(
          email: 'user@example.com'))!;
      final result = await service.resetPasswordWithCode(
        email: 'user@example.com',
        code: code,
        newPassword: 'short',
      );
      expect(result, isA<LocalAuthFailure>());
    });

    test('saveMemberId updates the link', () async {
      final result = await service.signUpWithEmail(
        email: 'user@example.com',
        password: 'secret123',
        displayName: 'User',
        memberId: 'M02',
      );
      final uid = (result as LocalAuthSuccess).session!.uid;
      await service.saveMemberId(uid, 'M03');
      expect(await service.memberIdFor(uid), 'M03');
    });
  });

  group('AppState + local auth (fake repository)', () {
    AppState makeState({LocalAuthService? localAuth, bool resetPrefs = true}) {
      if (resetPrefs) SharedPreferences.setMockInitialValues({});
      return AppState(
        repository: FakeSplitNestRepository.empty(),
        localAuth: localAuth ?? _service(),
      );
    }

    test('sign-up via AppState logs in and loads the household',
        () async {
      final state = makeState();
      final ok = await state.signUpWithEmail(
        displayName: 'Talha',
        email: 'talha@example.com',
        password: 'secret123',
        memberId: 'M01',
      );
      expect(ok, isTrue);
      expect(state.isLoggedIn, isTrue);
      expect(state.loggedInMemberId, 'M01');
      expect(state.isDemoUser, isFalse);
      expect(state.members.map((m) => m.id), ['M01', 'M02', 'M03']);
    });

    test('sign-up with a taken email fails with a plain message',
        () async {
      final service = _service();
      final state = makeState(localAuth: service);
      expect(
        await state.signUpWithEmail(
          displayName: 'Talha',
          email: 'talha@example.com',
          password: 'secret123',
          memberId: 'M01',
        ),
        isTrue,
      );
      await state.logout();
      final ok = await state.signUpWithEmail(
        displayName: 'Other',
        email: 'talha@example.com',
        password: 'other123',
        memberId: 'M02',
      );
      expect(ok, isFalse);
      expect(state.errorMessage, contains('already exists'));
      expect(state.isLoggedIn, isFalse);
    });

    test('sign-in via AppState after logout', () async {
      final service = _service();
      final state = makeState(localAuth: service);
      await state.signUpWithEmail(
        displayName: 'Talha',
        email: 'talha@example.com',
        password: 'secret123',
        memberId: 'M02',
      );
      await state.logout();
      expect(state.isLoggedIn, isFalse);
      expect(
        await state.signInWithEmail(
          email: 'talha@example.com',
          password: 'wrong-password',
        ),
        isFalse,
      );
      expect(state.isLoggedIn, isFalse);
      expect(
        await state.signInWithEmail(
          email: 'talha@example.com',
          password: 'secret123',
        ),
        isTrue,
      );
      expect(state.isLoggedIn, isTrue);
      expect(state.loggedInMemberId, 'M02');
    });

    test('demo login via AppState: all three, demo users', () async {
      final state = makeState();
      for (final demo in demoAccounts) {
        expect(await state.loginWithDemo(memberId: demo.memberId),
            isTrue);
        expect(state.isLoggedIn, isTrue);
        expect(state.isDemoUser, isTrue);
        expect(state.loggedInMemberId, demo.memberId);
        expect(state.localSession?.email, demo.email);
        await state.logout();
      }
    });

    test('logout clears the session and the app login', () async {
      final state = makeState();
      await state.loginWithDemo(memberId: 'M01');
      expect(state.isLoggedIn, isTrue);
      await state.logout();
      expect(state.isLoggedIn, isFalse);
      expect(state.localSession, isNull);
      expect(state.members, isEmpty);
    });

    test('reset via AppState signs in with the new password', () async {
      final service = _service();
      final state = makeState(localAuth: service);
      await state.signUpWithEmail(
        displayName: 'Talha',
        email: 'talha@example.com',
        password: 'old-password',
        memberId: 'M01',
      );
      await state.logout();
      final code =
          await state.requestPasswordReset('talha@example.com');
      expect(code, isNotNull);
      expect(code!.length, 6);
      expect(
        await state.resetPasswordWithCode(
          email: 'talha@example.com',
          code: '000000',
          newPassword: 'new-password',
        ),
        isFalse,
      );
      expect(
        await state.resetPasswordWithCode(
          email: 'talha@example.com',
          code: code,
          newPassword: 'new-password',
        ),
        isTrue,
      );
      expect(state.isLoggedIn, isTrue);
      await state.logout();
      expect(
        await state.signInWithEmail(
          email: 'talha@example.com',
          password: 'new-password',
        ),
        isTrue,
      );
    });

    test('reset for an unknown email fails plainly', () async {
      final state = makeState();
      final code =
          await state.requestPasswordReset('nobody@example.com');
      expect(code, isNull);
      expect(state.errorMessage, contains('No account exists'));
    });

    test('session restores across AppState instances (shared service)',
        () async {
      final service = _service();
      final state1 = makeState(localAuth: service);
      await state1.signUpWithEmail(
        displayName: 'Talha',
        email: 'talha@example.com',
        password: 'secret123',
        memberId: 'M03',
      );
      await _settle();
      // A fresh AppState over the same auth service restores the
      // persisted session and re-enters the app. Do NOT reset the
      // mock prefs here — that would wipe the persisted session uid
      // this test is restoring from.
      final state2 = makeState(localAuth: service, resetPrefs: false);
      var restored = false;
      for (var i = 0; i < 50 && !restored; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        restored = state2.isLoggedIn;
      }
      expect(restored, isTrue);
      expect(state2.loggedInMemberId, 'M03');
    });
  });

  group('login screen (widget)', () {
    Future<void> pumpApp(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppState(
            repository: FakeSplitNestRepository.benchmark(),
          )..refresh(),
          child: const SplitNestApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('invalid email is rejected locally, before any auth call',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'not-an-email');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'secret123');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(
          find.text('Enter a valid email address, like name@example.com.'),
          findsOneWidget);
      expect(find.text('Log in'), findsOneWidget);
    });

    testWidgets('email sign-in with a demo account enters Home',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Email'),
          'ali.demo@splitnest.app');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'ali123');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      // The welcome popup proves the login went through real auth.
      expect(find.text('You are using SplitNest as Ali (M01)'),
          findsOneWidget);
    });

    testWidgets('forgot password shows an on-device code, no email claim',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      expect(find.text('Reset your password'), findsOneWidget);
      expect(find.textContaining('No email is sent'), findsOneWidget);
      expect(find.textContaining('Anyone holding this device'),
          findsOneWidget);
    });
  });
}
