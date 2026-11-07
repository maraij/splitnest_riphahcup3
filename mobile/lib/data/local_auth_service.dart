/// Local-only auth (Phase 6) — email/password accounts stored in
/// lock.json, no server, no email, no third-party sign-in.
///
/// Replaces the old cloud auth services (both deleted 2026-11-07).
/// Accounts live in the lock.json
/// `users` table with salted SHA-256 password hashes (see
/// data/password_hash.dart) — NEVER plaintext. The session is the
/// signed-in uid persisted in SharedPreferences; the app restores
/// it on launch.
///
/// - Sign-up creates a local account directly (validated email +
///   password rules from `features/auth/auth_validation.dart`).
///   There is NO email verification — there is no mail backend.
/// - Demo accounts (ali/ayesha/bilal) sign in locally with the
///   demo passwords from data/demo_accounts.dart, seeded hashed on
///   first run by the store.
/// - There is NO third-party sign-in. The old sign-in button is
///   gone from the login screen — no fake button, no placeholder.
/// - Forgot/reset is device-local only (see [requestPasswordReset]):
///   the reset code is SHOWN ON THIS DEVICE in the app — no email
///   is ever sent, and the UI says so plainly. Anyone holding the
///   device can reset the password; that is the honest limit of a
///   single-device practice app, not a bug being hidden.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_accounts.dart';
import 'local_json_repository.dart';
import 'password_hash.dart';

/// One signed-in local user, as the app needs to see them.
class LocalSession {
  const LocalSession({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.isDemo,
    this.memberId,
  });

  final String uid;
  final String? email;
  final String? displayName;
  final bool isDemo;

  /// The household member this account is linked to (picked at
  /// sign-up, or the demo member). Null only for an account that
  /// never picked one — sign-up always sets it.
  final String? memberId;
}

/// Result of one local auth call. The UI switches on this — it never
/// sees a raw exception, so no raw error text ever reaches the
/// screen.
sealed class LocalAuthResult {
  const LocalAuthResult();
}

/// The call succeeded. [session] is null only for calls that do not
/// produce a session (a password reset).
class LocalAuthSuccess extends LocalAuthResult {
  const LocalAuthSuccess([this.session]);
  final LocalSession? session;
}

/// The call failed. [message] is safe to show on screen, verbatim.
class LocalAuthFailure extends LocalAuthResult {
  const LocalAuthFailure(this.message);
  final String message;
}

/// A pending device-local password reset: a code shown on this
/// device, valid for 15 minutes, single-use.
class _PendingReset {
  _PendingReset({required this.code, required this.expiresAt});
  final String code;
  final DateTime expiresAt;
}

abstract class LocalAuthService {
  /// Emits the current session on sign-in and sign-out. There is no
  /// token to refresh and no expiry — the session lasts until the
  /// user signs out (or the app data is cleared).
  Stream<LocalSession?> get authStateChanges;

  /// The currently signed-in user, if any.
  LocalSession? get currentSession;

  /// Email/password sign-in. Wrong email or wrong password both get
  /// the same message (no enumeration).
  Future<LocalAuthResult> signInWithEmail({
    required String email,
    required String password,
  });

  /// Email/password sign-up: creates the local account (salted
  /// hash) and signs in immediately. There is no verification email
  /// — the returned session is usable at once.
  Future<LocalAuthResult> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
    required String memberId,
  });

  /// Demo sign-in: the demo account from data/demo_accounts.dart.
  /// The account already exists in the seeded lock.json; this only
  /// verifies the (local, hashed) demo password and signs in.
  Future<LocalAuthResult> signInDemo(DemoAccount demo);

  /// Starts a device-local password reset for [email]. Returns the
  /// reset code to SHOW ON THIS DEVICE (the caller displays it in
  /// the app — no email is sent), or null when no account exists
  /// for that email. A code is valid for 15 minutes and single-use.
  Future<String?> requestPasswordReset({required String email});

  /// Completes a device-local password reset with the code from
  /// [requestPasswordReset] and a new password. Returns a session
  /// when the reset also signs the user in.
  Future<LocalAuthResult> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  });

  /// Signs out (clears the persisted session).
  Future<void> signOut();

  /// The household member id linked to this account. Null when
  /// never linked.
  Future<String?> memberIdFor(String uid);

  /// Saves the member link (see [memberIdFor]).
  Future<void> saveMemberId(String uid, String memberId);

  /// Restores the persisted session (if any) from SharedPreferences
  /// + lock.json. Called by AppState on launch.
  Future<LocalSession?> restoreSession();
}

class RealLocalAuthService implements LocalAuthService {
  /// [store] defaults to an in-memory store (tests and widget
  /// previews). PRODUCTION MUST pass the shared file-backed store:
  /// main.dart wires the same [LockJsonStore] into the repository
  /// and this service. A file-backed default here would hang in
  /// widget tests, where the documents directory never resolves.
  RealLocalAuthService({LockJsonStore? store})
      : _store = store ?? LockJsonStore.inMemory();

  final LockJsonStore _store;

  /// The store, so the app can share ONE store between auth and the
  /// repository (main.dart wires the same instance into both).
  LockJsonStore get store => _store;

  static const _sessionUidKey = 'local_session_uid';

  final _controller = StreamController<LocalSession?>.broadcast();
  LocalSession? _current;

  final Map<String, _PendingReset> _pendingResets = {};

  @override
  Stream<LocalSession?> get authStateChanges => _controller.stream;

  @override
  LocalSession? get currentSession => _current;

  Map<String, dynamic>? _userByEmail(
      Map<String, dynamic> doc, String email) {
    final clean = email.trim().toLowerCase();
    for (final u in (doc['users'] as List).cast<Map<String, dynamic>>()) {
      if ((u['email'] as String?)?.toLowerCase() == clean) return u;
    }
    return null;
  }

  Map<String, dynamic>? _userById(Map<String, dynamic> doc, String uid) {
    for (final u in (doc['users'] as List).cast<Map<String, dynamic>>()) {
      if (u['id'] == uid) return u;
    }
    return null;
  }

  LocalSession _sessionFor(Map<String, dynamic> user) => LocalSession(
        uid: user['id'] as String,
        email: user['email'] as String?,
        displayName: user['displayName'] as String?,
        isDemo: user['isDemo'] == true,
        memberId: user['memberId'] as String?,
      );

  /// Sets the in-memory session and persists the uid in the
  /// background. The persist is deliberately NEVER awaited: in
  /// widget tests without mock values `getInstance()` never
  /// completes, and awaiting it here would hang the login itself
  /// (the old code had the same rule for the same reason). The
  /// session works in-memory regardless; the persisted uid only
  /// decides next launch's restore.
  void _setSession(Map<String, dynamic> user) {
    _current = _sessionFor(user);
    _controller.add(_current);
    unawaited(_persistSessionUid(user['id'] as String));
  }

  Future<void> _persistSessionUid(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionUidKey, uid);
    } catch (_) {
      // Session stays in memory for this launch; the user signs in
      // again next time. Never blocks a login.
    }
  }

  @override
  Future<LocalAuthResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final doc = await _store.load();
    final user = _userByEmail(doc, email);
    if (user == null) {
      return const LocalAuthFailure(
          'That email or password is not correct. '
          'Try again or reset your password.');
    }
    final salt = user['passwordSalt'] as String?;
    final hash = user['passwordHash'] as String?;
    if (salt == null ||
        hash == null ||
        !verifyPassword(password: password, salt: salt, storedHash: hash)) {
      return const LocalAuthFailure(
          'That email or password is not correct. '
          'Try again or reset your password.');
    }
    _setSession(user);
    return LocalAuthSuccess(_current);
  }

  @override
  Future<LocalAuthResult> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
    required String memberId,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    if (!_isEmailShape(cleanEmail)) {
      return const LocalAuthFailure(
          'Enter a valid email address, like name@example.com.');
    }
    if (password.length < 6) {
      return const LocalAuthFailure(
          'Password must be at least 6 characters.');
    }
    final doc = await _store.load();
    if (_userByEmail(doc, cleanEmail) != null) {
      return const LocalAuthFailure(
          'An account already exists for that email. '
          'Try signing in instead.');
    }
    final salt = generateSalt();
    final uid = 'u-${DateTime.now().millisecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final user = <String, dynamic>{
      'id': uid,
      'email': cleanEmail,
      'displayName': displayName.trim(),
      'memberId': memberId,
      'passwordSalt': salt,
      'passwordHash': hashPassword(password, salt),
      'isDemo': false,
      'photoUrl': null,
      'createdAt': DateTime.now().toIso8601String(),
    };
    (doc['users'] as List).add(user);
    await _store.save(doc);
    _setSession(user);
    return LocalAuthSuccess(_current);
  }

  @override
  Future<LocalAuthResult> signInDemo(DemoAccount demo) async {
    final doc = await _store.load();
    final user = _userByEmail(doc, demo.email);
    if (user == null) {
      return const LocalAuthFailure(
          'The demo account could not be signed in. '
          'Try a member sign-in instead.');
    }
    final salt = user['passwordSalt'] as String?;
    final hash = user['passwordHash'] as String?;
    if (salt == null ||
        hash == null ||
        !verifyPassword(
            password: demo.password, salt: salt, storedHash: hash)) {
      return const LocalAuthFailure(
          'The demo account could not be signed in. '
          'Try a member sign-in instead.');
    }
    _setSession(user);
    return LocalAuthSuccess(_current);
  }

  @override
  Future<String?> requestPasswordReset({required String email}) async {
    final doc = await _store.load();
    final user = _userByEmail(doc, email);
    if (user == null) return null;
    // A 6-digit code, valid 15 minutes, single-use. Shown ON THIS
    // DEVICE by the caller — no email exists to send it to, and
    // the UI says so plainly.
    final code = (100000 + Random.secure().nextInt(900000)).toString();
    _pendingResets[email.trim().toLowerCase()] = _PendingReset(
      code: code,
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    );
    return code;
  }

  @override
  Future<LocalAuthResult> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    if (newPassword.length < 6) {
      return const LocalAuthFailure(
          'Password must be at least 6 characters.');
    }
    final cleanEmail = email.trim().toLowerCase();
    final pending = _pendingResets[cleanEmail];
    if (pending == null ||
        pending.code != code.trim() ||
        DateTime.now().isAfter(pending.expiresAt)) {
      return const LocalAuthFailure(
          'That reset code is not correct or has expired. '
          'Request a new code and try again.');
    }
    final doc = await _store.load();
    final user = _userByEmail(doc, cleanEmail);
    if (user == null) {
      return const LocalAuthFailure(
          'No account exists for that email. '
          'Check the email or create an account.');
    }
    final salt = generateSalt();
    user['passwordSalt'] = salt;
    user['passwordHash'] = hashPassword(newPassword, salt);
    _pendingResets.remove(cleanEmail);
    await _store.save(doc);
    _setSession(user);
    return LocalAuthSuccess(_current);
  }

  @override
  Future<void> signOut() async {
    _current = null;
    _controller.add(null);
    // Best-effort, never awaited (see [_setSession]): the in-memory
    // session is already cleared, so logout never hangs on prefs.
    unawaited(_clearPersistedSessionUid());
  }

  Future<void> _clearPersistedSessionUid() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionUidKey);
    } catch (_) {
      // The in-memory session is already cleared.
    }
  }

  @override
  Future<String?> memberIdFor(String uid) async {
    final doc = await _store.load();
    return _userById(doc, uid)?['memberId'] as String?;
  }

  @override
  Future<void> saveMemberId(String uid, String memberId) async {
    final doc = await _store.load();
    final user = _userById(doc, uid);
    if (user == null) return;
    if (user['memberId'] == memberId) return;
    user['memberId'] = memberId;
    await _store.save(doc);
    if (_current?.uid == uid) {
      _current = LocalSession(
        uid: _current!.uid,
        email: _current!.email,
        displayName: _current!.displayName,
        isDemo: _current!.isDemo,
        memberId: memberId,
      );
      _controller.add(_current);
    }
  }

  @override
  Future<LocalSession?> restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = prefs.getString(_sessionUidKey);
      if (uid == null || uid.isEmpty) return null;
      final doc = await _store.load();
      final user = _userById(doc, uid);
      if (user == null) return null;
      _current = _sessionFor(user);
      // Deliberately NO _controller.add here: restoring is a read,
      // not a sign-in. The caller applies the returned session.
      // Emitting would let a stale launch-time restore overwrite a
      // newer explicit login through the auth-state stream.
      return _current;
    } catch (e) {
      debugPrint('SplitNest: session restore skipped ($e)');
      return null;
    }
  }

  bool _isEmailShape(String email) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
}
