import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Firebase Auth behind an interface, so the app logic (and its tests)
/// never touches [FirebaseAuth] directly. The production
/// implementation is [RealFirebaseAuthService]; tests inject a fake.
///
/// Design notes (Phase 2):
/// - Firebase is the IDENTITY layer only. The household data still
///   lives on the Node backend, which issues its own Bearer sessions
///   for member passwords and verified Google ID tokens — an
///   email-only Firebase sign-in therefore has no backend token (see
///   AppState._applyFirebaseSession, which says so on screen).
/// - The Firestore profile write is BEST-EFFORT: the Firestore
///   database may not exist yet (console creation is still pending).
///   It is fire-and-forget, logs when skipped, and NEVER blocks or
///   fails a login. It is retried on the next sign-in.
/// - Demo accounts are seeded Firebase identities on the clearly
///   demo domain `splitnest.app`. They bypass the email-verification
///   gate (they are demo identities, not real users' emails) — that
///   bypass is deliberate and documented here, not a hole in the gate.
/// - No hardcoded admin credentials anywhere; no Admin SDK in the app.

/// One signed-in Firebase user, as the app needs to see them.
class FirebaseSession {
  const FirebaseSession({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.emailVerified,
    required this.isDemo,
  });

  factory FirebaseSession.fromUser(User user) => FirebaseSession(
        uid: user.uid,
        email: user.email,
        displayName: user.displayName,
        emailVerified: user.emailVerified,
        isDemo: isDemoEmail(user.email),
      );

  final String uid;
  final String? email;
  final String? displayName;
  final bool emailVerified;

  /// True for the seeded demo accounts (see [demoAccounts]).
  final bool isDemo;
}

/// A Firebase user counts as a demo identity when their email is on
/// the demo domain. Real users can never have such an address — the
/// domain is not a real mail domain.
bool isDemoEmail(String? email) =>
    email != null && email.toLowerCase().endsWith('@splitnest.app');

/// Gate state driven by [FirebaseAuthService.authStateChanges].
enum FirebaseAuthStatus {
  /// No Firebase user signed in.
  signedOut,

  /// Signed in, but the email is not verified yet (and not a demo
  /// account). The app must show the verification screen, not Home.
  needsVerification,

  /// Signed in and verified (or a demo account): may enter the app.
  signedIn,
}

/// Result of one Firebase auth call. The UI switches on this — it
/// never sees a [FirebaseAuthException], so no raw exception text
/// ever reaches the screen.
sealed class FirebaseAuthResult {
  const FirebaseAuthResult();
}

/// The call succeeded. [session] is null only for calls that do not
/// produce a session (password-reset email sent).
class FirebaseAuthSuccess extends FirebaseAuthResult {
  const FirebaseAuthSuccess([this.session]);
  final FirebaseSession? session;
}

/// The call failed. [message] is safe to show on screen, verbatim.
class FirebaseAuthFailure extends FirebaseAuthResult {
  const FirebaseAuthFailure(this.message);
  final String message;
}

/// One demo account: a fixed household member with a Firebase identity
/// on the demo domain. The passwords are the same demo passwords the
/// backend seeds (ali123 / ayesha123 / bilal123) so prior behaviour
/// is preserved.
class DemoAccount {
  const DemoAccount({
    required this.memberId,
    required this.name,
    required this.email,
    required this.password,
  });

  final String memberId;
  final String name;
  final String email;
  final String password;
}

const List<DemoAccount> demoAccounts = [
  DemoAccount(
    memberId: 'M01',
    name: 'Ali',
    email: 'ali.demo@splitnest.app',
    password: 'ali123',
  ),
  DemoAccount(
    memberId: 'M02',
    name: 'Ayesha',
    email: 'ayesha.demo@splitnest.app',
    password: 'ayesha123',
  ),
  DemoAccount(
    memberId: 'M03',
    name: 'Bilal',
    email: 'bilal.demo@splitnest.app',
    password: 'bilal123',
  ),
];

DemoAccount? demoForMember(String memberId) {
  for (final demo in demoAccounts) {
    if (demo.memberId == memberId) return demo;
  }
  return null;
}

/// Maps a [FirebaseAuthException] code to a plain, specific
/// user-facing message. Unknown codes and non-Firebase errors get the
/// generic message — raw exception text is never shown.
String firebaseAuthErrorMessageForCode(String code) {
  switch (code) {
    case 'user-not-found':
      return 'No account exists for that email. '
          'Check the email or create an account.';
    case 'wrong-password':
      return 'Wrong password. Try again or reset your password.';
    case 'invalid-credential':
      return 'That email or password is not correct. '
          'Try again or reset your password.';
    case 'email-already-in-use':
      return 'An account already exists for that email. '
          'Try signing in instead.';
    case 'weak-password':
      return 'Password must be at least 6 characters.';
    case 'invalid-email':
      return 'Enter a valid email address, like name@example.com.';
    case 'network-request-failed':
      return 'No connection. Check your internet and try again.';
    case 'operation-not-allowed':
      return 'Email sign-in is not enabled for this project yet. '
          'Enable it in the Firebase console (Authentication → '
          'Sign-in method → Email/Password), then try again.';
    case 'too-many-requests':
      return 'Too many attempts. Wait a few minutes and try again.';
    case 'user-disabled':
      return 'This account has been disabled.';
    case 'requires-recent-login':
      return 'Please sign in again and retry.';
    default:
      return 'Something went wrong. Please try again.';
  }
}

/// Maps any error thrown by a Firebase Auth call to a safe message.
String firebaseAuthErrorMessage(Object error) {
  if (error is FirebaseAuthException) {
    return firebaseAuthErrorMessageForCode(error.code);
  }
  return 'Something went wrong. Please try again.';
}

abstract class FirebaseAuthService {
  /// Emits the current session on sign-in, sign-out and verification
  /// changes. The AppState AuthGate listens to this; the Firebase SDK
  /// handles token refresh and expired sessions itself — no manual
  /// token handling anywhere in the app.
  Stream<FirebaseSession?> get authStateChanges;

  /// The currently signed-in user, if any.
  FirebaseSession? get currentSession;

  /// Email/password sign-in. Success carries the session; when the
  /// session is unverified the caller routes to the verification
  /// screen instead of Home.
  Future<FirebaseAuthResult> signInWithEmail({
    required String email,
    required String password,
  });

  /// Email/password sign-up. Sends the verification email; the
  /// returned session is unverified until the user confirms it.
  Future<FirebaseAuthResult> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
  });

  /// Signs in with a Google ID token (issued by the google_sign_in
  /// plugin) via Firebase. Google users arrive email-verified.
  Future<FirebaseAuthResult> signInWithGoogle({required String idToken});

  /// Demo create-or-sign-in: signs in with the demo email/password,
  /// creating the Firebase user on first use. Demo sessions bypass
  /// the verification gate (see the file doc comment).
  Future<FirebaseAuthResult> signInDemo(DemoAccount demo);

  /// Sends the password-reset email. Success means the email was
  /// accepted for sending — it does not reveal whether the address
  /// has an account.
  Future<FirebaseAuthResult> sendPasswordReset({required String email});

  /// Sends (or re-sends) the verification email to the current user.
  /// Returns false when there is no signed-in user or sending failed.
  Future<bool> sendEmailVerification();

  /// Reloads the current user from Firebase and returns the fresh
  /// session (so a just-confirmed email shows as verified). Returns
  /// null when nobody is signed in.
  Future<FirebaseSession?> reloadCurrentUser();

  /// Signs out of Firebase (and clears the local session state in
  /// the caller — AppState also signs out of Google there).
  Future<void> signOut();

  /// The household member id linked to this Firebase user, saved at
  /// sign-up / member pick. Stored in SharedPreferences so it works
  /// even before Firestore exists. Null when never linked.
  Future<String?> memberIdFor(String uid);

  /// Saves the member link (see [memberIdFor]).
  Future<void> saveMemberId(String uid, String memberId);

  /// Best-effort Firestore profile write (`users/{uid}`: displayName,
  /// email, legacyMemberId, createdAt/updatedAt — the fields in
  /// docs/FIRESTORE_STRUCTURE.md). Never throws and never blocks a
  /// login: when Firestore does not exist yet it logs and returns.
  Future<void> syncProfile({String? displayName, String? memberId});
}

class RealFirebaseAuthService implements FirebaseAuthService {
  RealFirebaseAuthService({FirebaseAuth? auth, FirebaseFirestore? firestore}) {
    // Stored, not resolved, here: the Firebase singletons are only
    // touched inside the methods, so constructing this service is
    // safe even before Firebase has finished initialising.
    _auth = auth;
    _firestore = firestore;
  }

  FirebaseAuth? _auth;
  FirebaseFirestore? _firestore;

  FirebaseAuth get _firebaseAuth => _auth ??= FirebaseAuth.instance;
  FirebaseFirestore get _store => _firestore ??= FirebaseFirestore.instance;

  @override
  Stream<FirebaseSession?> get authStateChanges => _firebaseAuth
      .authStateChanges()
      .map((user) => user == null ? null : FirebaseSession.fromUser(user));

  @override
  FirebaseSession? get currentSession {
    final user = _firebaseAuth.currentUser;
    return user == null ? null : FirebaseSession.fromUser(user);
  }

  @override
  Future<FirebaseAuthResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        return const FirebaseAuthFailure(
            'Something went wrong. Please try again.');
      }
      unawaited(_upsertProfile(user));
      return FirebaseAuthSuccess(FirebaseSession.fromUser(user));
    } on FirebaseAuthException catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    } catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    }
  }

  @override
  Future<FirebaseAuthResult> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        return const FirebaseAuthFailure(
            'Something went wrong. Please try again.');
      }
      try {
        await user.updateDisplayName(displayName.trim());
      } catch (_) {
        // Display-name save is cosmetic; the account already exists
        // and the verification email below still goes out.
      }
      try {
        await user.sendEmailVerification();
      } catch (e) {
        // The account exists even if the verification email failed
        // to send — the verification screen offers a resend.
        debugPrint('SplitNest: verification email failed to send ($e)');
      }
      unawaited(_upsertProfile(user));
      return FirebaseAuthSuccess(FirebaseSession.fromUser(user));
    } on FirebaseAuthException catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    } catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    }
  }

  @override
  Future<FirebaseAuthResult> signInWithGoogle({
    required String idToken,
  }) async {
    try {
      final credential = await _firebaseAuth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
      final user = credential.user;
      if (user == null) {
        return const FirebaseAuthFailure(
            'Something went wrong. Please try again.');
      }
      unawaited(_upsertProfile(user));
      return FirebaseAuthSuccess(FirebaseSession.fromUser(user));
    } on FirebaseAuthException catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    } catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    }
  }

  @override
  Future<FirebaseAuthResult> signInDemo(DemoAccount demo) async {
    try {
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: demo.email,
        password: demo.password,
      );
      final user = credential.user;
      if (user == null) {
        return const FirebaseAuthFailure(
            'Something went wrong. Please try again.');
      }
      unawaited(_upsertProfile(user, memberId: demo.memberId));
      return FirebaseAuthSuccess(FirebaseSession.fromUser(user));
    } on FirebaseAuthException catch (e) {
      // First use (or email-enumeration protection hiding a
      // not-found as invalid-credential): create the demo user.
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        try {
          final credential =
              await _firebaseAuth.createUserWithEmailAndPassword(
            email: demo.email,
            password: demo.password,
          );
          final user = credential.user;
          if (user == null) {
            return const FirebaseAuthFailure(
                'Something went wrong. Please try again.');
          }
          try {
            await user.updateDisplayName(demo.name);
          } catch (_) {
            // Cosmetic only; the demo account already exists.
          }
          unawaited(_upsertProfile(user, memberId: demo.memberId));
          return FirebaseAuthSuccess(FirebaseSession.fromUser(user));
        } on FirebaseAuthException catch (createError) {
          if (createError.code == 'email-already-in-use') {
            // The demo account exists but the saved demo password no
            // longer signs into it (e.g. changed in the console).
            return const FirebaseAuthFailure(
                'The demo account could not be signed in. '
                'Try a member sign-in instead.');
          }
          return FirebaseAuthFailure(
              firebaseAuthErrorMessage(createError));
        } catch (error) {
          return FirebaseAuthFailure(firebaseAuthErrorMessage(error));
        }
      }
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    } catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    }
  }

  @override
  Future<FirebaseAuthResult> sendPasswordReset({
    required String email,
  }) async {
    try {
      await _firebaseAuth.sendPasswordResetEmail(email: email.trim());
      return const FirebaseAuthSuccess();
    } on FirebaseAuthException catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    } catch (e) {
      return FirebaseAuthFailure(firebaseAuthErrorMessage(e));
    }
  }

  @override
  Future<bool> sendEmailVerification() async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return false;
    try {
      await user.sendEmailVerification();
      return true;
    } catch (e) {
      debugPrint('SplitNest: resending verification email failed ($e)');
      return false;
    }
  }

  @override
  Future<FirebaseSession?> reloadCurrentUser() async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return null;
    try {
      await user.reload();
    } catch (e) {
      // Reload failed (e.g. offline): report the last known session
      // rather than failing the check outright.
      debugPrint('SplitNest: user reload failed ($e)');
    }
    final fresh = _firebaseAuth.currentUser;
    return fresh == null ? null : FirebaseSession.fromUser(fresh);
  }

  @override
  Future<void> signOut() => _firebaseAuth.signOut();

  static const _memberIdKeyPrefix = 'firebase_member_';

  @override
  Future<String?> memberIdFor(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_memberIdKeyPrefix$uid');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveMemberId(String uid, String memberId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_memberIdKeyPrefix$uid', memberId);
    } catch (_) {
      // Best-effort: the link is re-asked on next launch instead.
    }
  }

  @override
  Future<void> syncProfile({String? displayName, String? memberId}) async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return;
    await _upsertProfile(user, memberId: memberId);
  }

  /// Best-effort `users/{uid}` write. Never throws: when Firestore
  /// does not exist yet (or the network is down) the failure is
  /// logged and the login that triggered it is unaffected. Retried on
  /// the next sign-in. Only the documented profile fields are
  /// written (see docs/FIRESTORE_STRUCTURE.md).
  Future<void> _upsertProfile(User user, {String? memberId}) async {
    try {
      final ref = _store.collection('users').doc(user.uid);
      final data = <String, Object?>{
        'displayName': user.displayName,
        'email': user.email?.toLowerCase(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (memberId != null) data['legacyMemberId'] = memberId;
      final snap = await ref.get();
      if (!snap.exists) {
        data['createdAt'] = FieldValue.serverTimestamp();
      }
      await ref.set(data, SetOptions(merge: true));
    } catch (e) {
      // Firestore unavailable (database not created yet, offline,
      // rules not deployed): log and continue — login never blocks.
      debugPrint('SplitNest: Firestore profile sync skipped ($e)');
    }
  }
}
