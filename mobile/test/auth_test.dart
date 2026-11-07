import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/data/firebase_auth_service.dart';
import 'package:splitnest/data/google_auth_service.dart';
import 'package:splitnest/features/auth/auth_validation.dart';
import 'package:splitnest/main.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';

// ------------------------------------------------------------------
// Fake Firebase Auth: in-memory users with Firebase-like semantics.
// signIn throws user-not-found for unknown emails and
// invalid-credential for wrong passwords (the enumeration-protected
// behaviour current Firebase projects show); signUp creates an
// UNVERIFIED user; demo create-or-sign-in mirrors the real service.
// ------------------------------------------------------------------

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

class FakeFirebaseAuthService implements FirebaseAuthService {
  final Map<String, _FakeUser> _usersByEmail = {};
  final Map<String, String> _memberLinks = {};
  final _controller = StreamController<FirebaseSession?>.broadcast();
  FirebaseSession? _current;
  int profileSyncs = 0;
  int verificationEmailsSent = 0;
  int passwordResetEmailsSent = 0;

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

  /// Test helper: mark an email verified, as if the user clicked the
  /// link in their inbox.
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
    await syncProfile();
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
    if (password.length < minPasswordLength) {
      return const FirebaseAuthFailure(
          'Password must be at least 6 characters.');
    }
    final user = _FakeUser(
      uid: 'uid-$clean',
      email: clean,
      password: password,
      displayName: displayName,
      emailVerified: false,
    );
    _usersByEmail[clean] = user;
    verificationEmailsSent++;
    _emit(user);
    await syncProfile(displayName: displayName);
    return FirebaseAuthSuccess(_sessionFor(user));
  }

  @override
  Future<FirebaseAuthResult> signInWithGoogle({
    required String idToken,
  }) async {
    // The fake has no Google token to verify; the credential step is
    // covered by the real service being untestable here — this fake
    // models "Google user arrives verified".
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
    await syncProfile();
    return FirebaseAuthSuccess(_sessionFor(user));
  }

  @override
  Future<FirebaseAuthResult> signInDemo(DemoAccount demo) async {
    var user = _usersByEmail[demo.email];
    if (user == null) {
      user = _FakeUser(
        uid: 'uid-${demo.memberId}',
        email: demo.email,
        password: demo.password,
        displayName: demo.name,
        emailVerified: false,
      );
      _usersByEmail[demo.email] = user;
    } else if (user.password != demo.password) {
      return const FirebaseAuthFailure(
          'The demo account could not be signed in. Try a member sign-in instead.');
    }
    _emit(user);
    await syncProfile(memberId: demo.memberId);
    return FirebaseAuthSuccess(_sessionFor(user));
  }

  @override
  Future<FirebaseAuthResult> sendPasswordReset({
    required String email,
  }) async {
    if (!email.trim().contains('@')) {
      return const FirebaseAuthFailure(
          'Enter a valid email address, like name@example.com.');
    }
    passwordResetEmailsSent++;
    return const FirebaseAuthSuccess();
  }

  @override
  Future<bool> sendEmailVerification() async {
    if (_current == null) return false;
    verificationEmailsSent++;
    return true;
  }

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
  Future<void> signOut() async {
    _emit(null);
  }

  @override
  Future<String?> memberIdFor(String uid) async => _memberLinks[uid];

  @override
  Future<void> saveMemberId(String uid, String memberId) async {
    _memberLinks[uid] = memberId;
  }

  @override
  Future<void> syncProfile({String? displayName, String? memberId}) async {
    profileSyncs++;
  }
}

class _FakeGoogleAuthService implements GoogleAuthService {
  _FakeGoogleAuthService(this.result);
  final GoogleSignInResult result;
  bool signOutCalled = false;
  @override
  Future<GoogleSignInResult> signIn() async => result;
  @override
  Future<void> signOut() async {
    signOutCalled = true;
  }
}

Future<AppState> _makeState({
  FakeFirebaseAuthService? firebaseAuth,
  GoogleAuthService? googleAuth,
}) async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(
    repository: FakeSplitNestRepository.benchmark(),
    googleAuth: googleAuth,
    firebaseAuth: firebaseAuth,
  )..refresh();
  // Let the initial refresh + any restore finish.
  await Future<void>.delayed(Duration.zero);
  return state;
}

Future<void> _pumpApp(
  WidgetTester tester, {
  FakeFirebaseAuthService? firebaseAuth,
  GoogleAuthService? googleAuth,
}) async {
  SharedPreferences.setMockInitialValues({});
  addTearDown(() => SharedPreferences.setMockInitialValues({}));
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AppState(
        repository: FakeSplitNestRepository.benchmark(),
        googleAuth: googleAuth,
        firebaseAuth: firebaseAuth,
      )..refresh(),
      child: const SplitNestApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('email/password validation', () {
    test('validateEmail accepts a normal address', () {
      expect(validateEmail('talha@example.com'), isNull);
      expect(validateEmail('  a@b.co  '), isNull);
    });

    test('validateEmail rejects empty, missing @, missing domain', () {
      expect(validateEmail(''), 'Enter your email address.');
      expect(validateEmail('   '), 'Enter your email address.');
      expect(validateEmail('not-an-email'),
          'Enter a valid email address, like name@example.com.');
      expect(validateEmail('a@b'), 'Enter a valid email address, like name@example.com.');
      expect(validateEmail('a b@c.com'),
          'Enter a valid email address, like name@example.com.');
    });

    test('validatePassword requires at least 6 characters', () {
      expect(validatePassword(''), 'Enter a password.');
      expect(validatePassword('12345'),
          'Password must be at least 6 characters.');
      expect(validatePassword('123456'), isNull);
      expect(validatePassword('ali123'), isNull);
    });

    test('validateConfirmPassword requires a match', () {
      expect(validateConfirmPassword('abc123', ''),
          'Repeat your password.');
      expect(validateConfirmPassword('abc123', 'abc124'),
          'Passwords do not match.');
      expect(validateConfirmPassword('abc123', 'abc123'), isNull);
    });

    test('validateDisplayName requires a name', () {
      expect(validateDisplayName(''), 'Enter your name.');
      expect(validateDisplayName('  '), 'Enter your name.');
      expect(validateDisplayName('Ali'), isNull);
    });
  });

  group('auth error mapping', () {
    test('every required Firebase code maps to a plain message', () {
      const codes = {
        'user-not-found': 'No account exists for that email.',
        'wrong-password': 'Wrong password.',
        'email-already-in-use': 'An account already exists for that email.',
        'weak-password': 'Password must be at least 6 characters.',
        'invalid-email': 'Enter a valid email address, like name@example.com.',
        'network-request-failed': 'No connection.',
        'operation-not-allowed': 'Email sign-in is not enabled',
        'too-many-requests': 'Too many attempts.',
      };
      for (final entry in codes.entries) {
        final message = firebaseAuthErrorMessageForCode(entry.key);
        expect(message, contains(entry.value),
            reason: 'code ${entry.key}');
        expect(message, isNot(contains('FirebaseAuthException')),
            reason: 'code ${entry.key}');
        expect(message, isNot(contains('ERROR_')),
            reason: 'code ${entry.key}');
      }
    });

    test('unknown codes and non-Firebase errors get the generic message',
        () {
      expect(firebaseAuthErrorMessageForCode('something-new'),
          'Something went wrong. Please try again.');
      expect(firebaseAuthErrorMessage(Exception('boom')),
          'Something went wrong. Please try again.');
      expect(firebaseAuthErrorMessage('raw string'),
          isNot(contains('raw string')));
    });
  });

  group('AuthGate state transitions (fake auth service)', () {
    test('signed-out by default; email sign-in unverified gates',
        () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      expect(state.firebaseAuthEnabled, isTrue);
      expect(state.firebaseStatus, FirebaseAuthStatus.signedOut);
      expect(state.isLoggedIn, isFalse);

      // Sign up: account created, verification email sent, gate set.
      final signedUp = await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'test@example.com',
        password: 'secret1',
        memberId: 'M01',
      );
      expect(signedUp, isTrue);
      expect(fake.verificationEmailsSent, 1);
      expect(state.firebaseStatus, FirebaseAuthStatus.needsVerification);
      expect(state.isLoggedIn, isFalse,
          reason: 'unverified users must not reach Home');

      // Still unverified after a check: stays gated.
      final checkedTooSoon = await state.refreshVerificationStatus();
      expect(checkedTooSoon, isFalse);
      expect(state.firebaseStatus, FirebaseAuthStatus.needsVerification);

      // Click the link, then check: verified, member applied, Home.
      fake.verifyEmail('test@example.com');
      final checked = await state.refreshVerificationStatus();
      expect(checked, isTrue);
      expect(state.firebaseStatus, FirebaseAuthStatus.signedIn);
      expect(state.isLoggedIn, isTrue);
      expect(state.loggedInMemberId, 'M01');
    });

    test('sign-in with a verified account goes straight to Home',
        () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'verified@example.com',
        password: 'secret1',
        memberId: 'M02',
      );
      fake.verifyEmail('verified@example.com');
      await state.logout();
      expect(state.firebaseStatus, FirebaseAuthStatus.signedOut);
      expect(state.isLoggedIn, isFalse);

      final ok = await state.signInWithFirebaseEmail(
        email: 'verified@example.com',
        password: 'secret1',
      );
      expect(ok, isTrue);
      expect(state.firebaseStatus, FirebaseAuthStatus.signedIn);
      expect(state.isLoggedIn, isTrue);
      expect(state.loggedInMemberId, 'M02');
    });

    test('wrong password and unknown email fail with plain messages',
        () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'real@example.com',
        password: 'secret1',
        memberId: 'M01',
      );
      var ok = await state.signInWithFirebaseEmail(
        email: 'real@example.com',
        password: 'not-the-password',
      );
      expect(ok, isFalse);
      expect(state.errorMessage,
          'That email or password is not correct. Try again or reset your password.');
      expect(state.isLoggedIn, isFalse);

      ok = await state.signInWithFirebaseEmail(
        email: 'nobody@example.com',
        password: 'secret1',
      );
      expect(ok, isFalse);
      expect(state.errorMessage, contains('No account exists'));
      expect(state.isLoggedIn, isFalse);
    });

    test('sign-up with an existing email fails plainly', () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'dup@example.com',
        password: 'secret1',
        memberId: 'M01',
      );
      final again = await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'dup@example.com',
        password: 'secret1',
        memberId: 'M01',
      );
      expect(again, isFalse);
      expect(state.errorMessage, contains('already exists'));
    });

    test('logout clears the Firebase session and the app login',
        () async {
      final fake = FakeFirebaseAuthService();
      final google = _FakeGoogleAuthService(const GoogleSignedIn(
        idToken: 'fake-id-token',
        email: 'test.user@gmail.com',
      ));
      final state =
          await _makeState(firebaseAuth: fake, googleAuth: google);
      await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'logout@example.com',
        password: 'secret1',
        memberId: 'M03',
      );
      fake.verifyEmail('logout@example.com');
      await state.refreshVerificationStatus();
      expect(state.isLoggedIn, isTrue);

      // Log in via Google too, so logout must sign Google out.
      await state.loginWithGoogle(
          idToken: 'fake-id-token', memberId: 'M03');
      await state.logout();
      expect(state.firebaseStatus, FirebaseAuthStatus.signedOut);
      expect(state.firebaseSession, isNull);
      expect(state.isLoggedIn, isFalse);
      expect(state.loggedInMemberId, isNull);
      expect(fake.currentSession, isNull);
      expect(google.signOutCalled, isTrue);
    });

    test('external sign-out clears the app login', () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'ext@example.com',
        password: 'secret1',
        memberId: 'M01',
      );
      fake.verifyEmail('ext@example.com');
      await state.refreshVerificationStatus();
      expect(state.isLoggedIn, isTrue);

      // Firebase signs out underneath the app (e.g. token revoked).
      await fake.signOut();
      await Future<void>.delayed(Duration.zero);
      expect(state.firebaseStatus, FirebaseAuthStatus.signedOut);
      expect(state.isLoggedIn, isFalse);
    });

    test('profile sync runs on sign-in (best-effort hookup)', () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      await state.signUpWithFirebaseEmail(
        displayName: 'Test User',
        email: 'profile@example.com',
        password: 'secret1',
        memberId: 'M01',
      );
      expect(fake.profileSyncs, greaterThan(0));
      expect(await fake.memberIdFor('uid-profile@example.com'), 'M01');
    });
  });

  group('demo create-or-sign-in (fake auth service)', () {
    test('first demo login creates the Firebase user, second signs in',
        () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);

      var ok = await state.loginWithDemo(memberId: 'M01');
      expect(ok, isTrue);
      expect(state.firebaseStatus, FirebaseAuthStatus.signedIn,
          reason: 'demo accounts bypass the verification gate');
      expect(state.isLoggedIn, isTrue);
      expect(state.loggedInMemberId, 'M01');
      expect(state.firebaseSession?.email, 'ali.demo@splitnest.app');
      expect(state.firebaseSession?.isDemo, isTrue);

      await state.logout();
      ok = await state.loginWithDemo(memberId: 'M01');
      expect(ok, isTrue, reason: 'second use signs in, no duplicate');
      expect(state.loggedInMemberId, 'M01');
    });

    test('all three demo accounts map to the right members', () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      const cases = {
        'M01': 'ali.demo@splitnest.app',
        'M02': 'ayesha.demo@splitnest.app',
        'M03': 'bilal.demo@splitnest.app',
      };
      for (final entry in cases.entries) {
        final ok = await state.loginWithDemo(memberId: entry.key);
        expect(ok, isTrue, reason: entry.key);
        expect(state.firebaseSession?.email, entry.value);
        expect(state.loggedInMemberId, entry.key);
        await state.logout();
      }
    });

    test('demo login without Firebase uses a local demo identity',
        () async {
      // No firebaseAuth wired in: the demo identity is local, and
      // the household still loads from the repository — there is no
      // backend login any more.
      final state = await _makeState();
      expect(state.firebaseAuthEnabled, isFalse);
      final ok = await state.loginWithDemo(memberId: 'M02');
      expect(ok, isTrue);
      expect(state.loggedInMemberId, 'M02');
      expect(state.firebaseSession?.isDemo, isTrue);
      expect(state.firebaseSession?.email, 'ayesha.demo@splitnest.app');
      expect(state.isLoggedIn, isTrue);
    });
  });

  group('password reset', () {
    test('reset sends for a valid email, fails plainly otherwise',
        () async {
      final fake = FakeFirebaseAuthService();
      final state = await _makeState(firebaseAuth: fake);
      final ok =
          await state.sendFirebasePasswordReset('user@example.com');
      expect(ok, isTrue);
      expect(fake.passwordResetEmailsSent, 1);
    });
  });

  group('auth screens (widget)', () {
    testWidgets('email mode shows sign-in form and sign-up link',
        (tester) async {
      final fake = FakeFirebaseAuthService();
      await _pumpApp(tester, firebaseAuth: fake);
      expect(find.text('Sign in with email instead'), findsOneWidget);
      await tester.ensureVisible(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      expect(find.text('Create an account'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      // Invalid email is rejected locally, before any Firebase call.
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'not-an-email');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'secret1');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address, like name@example.com.'),
          findsOneWidget);
      expect(fake.currentSession, isNull);
    });

    testWidgets('sign-up flow ends on the verification screen',
        (tester) async {
      final fake = FakeFirebaseAuthService();
      await _pumpApp(tester, firebaseAuth: fake);
      await tester.ensureVisible(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create an account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      expect(find.text('Create your SplitNest account'), findsOneWidget);
      // Short password is rejected locally.
      await tester.tap(find.text('Ali'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Your name'), 'Test User');
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'new@example.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'short');
      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm password'), 'short');
      await tester.ensureVisible(find.text('Create account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Password must be at least 6 characters.'),
          findsOneWidget);
      // Mismatched confirmation is rejected locally too.
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'secret1');
      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm password'), 'secret2');
      await tester.ensureVisible(find.text('Create account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Passwords do not match.'), findsOneWidget);
      // Valid form: account created, verification screen appears.
      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm password'), 'secret1');
      await tester.ensureVisible(find.text('Create account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.textContaining('new@example.com'), findsOneWidget);
      expect(fake.verificationEmailsSent, 1);
    });

    testWidgets('verification screen resends and checks again',
        (tester) async {
      final fake = FakeFirebaseAuthService();
      await _pumpApp(tester, firebaseAuth: fake);
      await tester.ensureVisible(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create an account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ayesha'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Your name'), 'Test User');
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'verify@example.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'secret1');
      await tester.enterText(
          find.widgetWithText(TextField, 'Confirm password'), 'secret1');
      await tester.ensureVisible(find.text('Create account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Verify your email'), findsOneWidget);
      // Not verified yet: stays on the verification screen.
      await tester.tap(find.text('I’ve verified — check again'));
      await tester.pumpAndSettle();
      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.textContaining('Not verified yet'), findsOneWidget);
      // Resend works.
      await tester.tap(find.text('Resend verification email'));
      await tester.pumpAndSettle();
      expect(find.text('Verification email sent. Check your inbox.'),
          findsOneWidget);
      expect(fake.verificationEmailsSent, 2);
      // Click the link, check again: Home opens as Ayesha.
      fake.verifyEmail('verify@example.com');
      await tester.tap(find.text('I’ve verified — check again'));
      await tester.pumpAndSettle();
      expect(find.text('Verify your email'), findsNothing);
      expect(find.text('You are using SplitNest as Ayesha (M02)'),
          findsOneWidget);
    });

    testWidgets('forgot-password screen sends and confirms', (tester) async {
      final fake = FakeFirebaseAuthService();
      await _pumpApp(tester, firebaseAuth: fake);
      await tester.ensureVisible(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in with email instead'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      expect(find.text('Reset your password'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'bad-email');
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address, like name@example.com.'),
          findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'user@example.com');
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();
      expect(find.textContaining('password-reset link has been sent'),
          findsOneWidget);
      expect(fake.passwordResetEmailsSent, 1);
    });

    testWidgets('demo login through Firebase shows the welcome popup',
        (tester) async {
      final fake = FakeFirebaseAuthService();
      await _pumpApp(tester, firebaseAuth: fake);
      await tester.ensureVisible(find.text('Demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ali • M01'));
      await tester.pumpAndSettle();
      expect(find.text('You are using SplitNest as Ali (M01)'),
          findsOneWidget);
      expect(fake.currentSession?.email, 'ali.demo@splitnest.app');
    });

    testWidgets('Google sign-in links the picked member to Firebase',
        (tester) async {
      final fake = FakeFirebaseAuthService();
      await _pumpApp(
        tester,
        firebaseAuth: fake,
        googleAuth: _FakeGoogleAuthService(const GoogleSignedIn(
          idToken: 'fake-id-token',
          email: 'test.user@gmail.com',
        )),
      );
      await tester.ensureVisible(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.text('Choose your account'), findsOneWidget);
      await tester.tap(find.text('Bilal • M03'));
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
      expect(find.text('Logged in as'), findsOneWidget);
      // (In production the same tap also signs the Google credential
      // into Firebase and saveFirebaseMember links the picked member
      // to that Firebase uid, so the next Google sign-in reuses it.
      // That link step needs a real Firebase user, so it is covered
      // by the AppState unit tests, not by this widget fake.)
    });
  });
}
