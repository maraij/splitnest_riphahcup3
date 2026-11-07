import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_client.dart';
import '../data/firebase_auth_service.dart';
import '../data/google_auth_service.dart';
import '../data/repository.dart';
import '../domain/insights.dart';
import '../domain/models.dart';

/// AppState — the SINGLE source of truth for the whole app.
///
/// One store holds members, budget (via balances), shopping, expenses
/// (session-only recent list), balances and the logged-in member.
/// Widgets read from Provider and call these store methods only — they
/// never call HTTP, never hold app data in their own setState, and
/// never refresh per-screen. Every mutation refreshes this store once
/// and all screens rebuild from it.
class AppState extends ChangeNotifier {
  AppState({
    SplitNestRepository? repository,
    GoogleAuthService? googleAuth,
    this.firebaseAuth,
    bool? initialDarkMode,
  })  : _repository = repository ?? SplitNestRepository(),
        googleAuth = googleAuth ?? RealGoogleAuthService() {
    _isDarkMode = initialDarkMode ?? false;
    // When the caller did not preload the saved theme (tests), load
    // it here; main() preloads it before first paint instead.
    if (initialDarkMode == null) _loadThemeMode();
    _loadCaps();
    _loadProfileImages();
    // Phase 2 (Auth): when a Firebase auth service is wired in
    // (production, Firebase initialised), the AuthGate listens to
    // FirebaseAuth.authStateChanges(). Without one (tests, or
    // Firebase init failed) the app runs backend-only exactly as
    // before — member + password login drives isLoggedIn.
    final firebaseService = firebaseAuth;
    if (firebaseService != null) {
      firebaseSession = firebaseService.currentSession;
      _updateFirebaseStatus();
      _firebaseSub =
          firebaseService.authStateChanges.listen(_onFirebaseSession);
      _restoreFirebaseSession();
    }
  }

  final SplitNestRepository _repository;

  /// Google sign-in service (real in production, fake in widget
  /// tests). The login screen calls it; the store never talks to
  /// Google directly.
  final GoogleAuthService googleAuth;

  /// Firebase Auth service (real in production when Firebase
  /// initialised, fake in auth tests, null in the older widget
  /// tests and when Firebase init failed). Null means the Firebase
  /// auth flows are unavailable and the backend login is the only
  /// way in — the login screen hides the email mode then.
  final FirebaseAuthService? firebaseAuth;
  StreamSubscription<FirebaseSession?>? _firebaseSub;

  /// The current Firebase session, if any. Null when signed out or
  /// when no Firebase auth service is wired in.
  FirebaseSession? firebaseSession;

  /// Gate state from the Firebase session (see [FirebaseAuthStatus]).
  /// Meaningless when [firebaseAuth] is null — the backend login
  /// decides then.
  FirebaseAuthStatus firebaseStatus = FirebaseAuthStatus.signedOut;

  bool get firebaseAuthEnabled => firebaseAuth != null;

  /// True once a Google sign-in happened this session, so logout
  /// knows to sign out of Google too. (Widget tests that only use
  /// password login never touch the Google plugin this way.)
  bool _usedGoogleSignIn = false;

  @override
  void dispose() {
    _firebaseSub?.cancel();
    super.dispose();
  }

  /// A Firebase session changed underneath us (sign-in, sign-out,
  /// token refresh, verification). The gate state follows it; an
  /// external sign-out also clears the app login, so Home is
  /// unreachable without a Firebase session when Firebase auth is
  /// enabled. Token refresh / expiry is the SDK's job — nothing here
  /// handles tokens manually.
  void _onFirebaseSession(FirebaseSession? session) {
    firebaseSession = session;
    _updateFirebaseStatus();
    if (session == null && isLoggedIn) _clearLocalSession();
    notifyListeners();
  }

  void _updateFirebaseStatus() {
    final session = firebaseSession;
    if (session == null) {
      firebaseStatus = FirebaseAuthStatus.signedOut;
    } else if (session.emailVerified || session.isDemo) {
      firebaseStatus = FirebaseAuthStatus.signedIn;
    } else {
      firebaseStatus = FirebaseAuthStatus.needsVerification;
    }
  }

  /// Restores a persisted Firebase session on launch: a verified (or
  /// demo) user with a saved member link re-enters the app without
  /// signing in again. Demo users also silently restore their
  /// backend session (their demo password is known to the app);
  /// Google/email users keep Firebase identity only — the backend
  /// issues no token without a fresh Google ID token or member
  /// password, so they re-authenticate for data (see
  /// _applyFirebaseSession's notice).
  Future<void> _restoreFirebaseSession() async {
    final service = firebaseAuth;
    final session = service?.currentSession;
    if (service == null || session == null) return;
    firebaseSession = session;
    _updateFirebaseStatus();
    if (firebaseStatus != FirebaseAuthStatus.signedIn) {
      notifyListeners();
      return;
    }
    final memberId = await service.memberIdFor(session.uid);
    if (memberId == null) {
      notifyListeners();
      return;
    }
    final demo = demoForMember(memberId);
    if (demo != null) {
      try {
        final result = await _repository.login(
          memberId: memberId,
          password: demo.password,
        );
        sessionToken = result.token;
      } catch (_) {
        // Backend down: Firebase identity stands, data stays
        // unloaded until the backend is back.
      }
    }
    await _applyFirebaseSession(session, memberId);
  }

  // ---- Theme (light / dark) — one state, AppBar + drawer toggles ----
  static const _themeModeKey = 'theme_mode';

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;
  ThemeMode get themeMode => _isDarkMode ? ThemeMode.dark : ThemeMode.light;

  Future<void> _loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_themeModeKey);
      if (saved == 'dark' || saved == 'light') {
        _isDarkMode = saved == 'dark';
        notifyListeners();
      }
    } catch (_) {
      // No saved preference (or storage unavailable): stay light.
    }
  }

  /// Switches the whole app's theme and persists the choice, so it
  /// survives restarts.
  Future<void> setDarkMode(bool dark) async {
    if (_isDarkMode == dark) return;
    _isDarkMode = dark;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeModeKey, dark ? 'dark' : 'light');
    } catch (_) {
      // Persistence is best-effort; the in-memory theme still applies.
    }
  }

  Future<void> toggleTheme() => setDarkMode(!_isDarkMode);

  /// Base URL of the backend, for display only (Home footer).
  String get apiBaseUrl => _repository.baseUrl;

  List<Member> members = [];

  /// Members to offer in the sign-up / member-pick lists. Normally
  /// the backend list; when it is empty (backend unreachable or not
  /// logged in — the members endpoint itself needs a session) the
  /// three seeded household members stand in, so sign-up and the
  /// Firebase-session member pick still work.
  List<Member> get memberOptions =>
      members.isEmpty ? _fallbackHouseholdMembers : members;

  static final _fallbackHouseholdMembers = [
    Member(id: 'M01', name: 'Ali'),
    Member(id: 'M02', name: 'Ayesha'),
    Member(id: 'M03', name: 'Bilal'),
  ];
  List<ShoppingItem> shopping = [];
  Balances? balances;
  List<ExpenseRecord> recentExpenses = [];

  /// Fixed monthly expense templates (persisted in the backend).
  List<FixedExpense> fixedExpenses = [];

  /// Activity log (Timeline screen): every successful checkout,
  /// expense post and settlement this session, newest last.
  /// Session-only — it resets when the app reloads.
  List<ActivityEntry> activityLog = [];

  /// Profile pictures, picked by the user, keyed by member id.
  /// Kept in memory; also persisted as base64 in SharedPreferences
  /// when small enough (best effort — a huge photo stays
  /// session-only rather than breaking storage).
  Map<String, Uint8List> profileImages = {};

  /// Per-category budget caps in paisa, keyed by cap category.
  /// UNSET by default: no cap = no bar, no alert. Persisted in
  /// SharedPreferences; a missing entry means the user never set it.
  Map<String, int> categoryCaps = {};

  String activeMemberId = 'M01';

  /// Session token from POST /api/auth/login (in-memory only, practice
  /// build). Null until a successful login; cleared on logout, after
  /// which no endpoint call may succeed.
  String? sessionToken;

  /// Logged-in member id. Null until a successful login; Home is
  /// unreachable while null.
  String? loggedInMemberId;
  bool get isLoggedIn => loggedInMemberId != null;

  /// Welcome popup, once per login session: the member id the popup was
  /// last shown for (null = not shown this login), plus a scheduling
  /// guard so a rebuild before the first frame cannot queue it twice.
  String? _welcomeShownForMemberId;
  bool _welcomeDialogPending = false;

  /// True only when the popup may be shown: logged in, balances loaded
  /// (so the balance line is never a wrong/zero guess), and not yet
  /// shown or scheduled for this login.
  bool get shouldShowWelcome =>
      isLoggedIn &&
      balances != null &&
      activeBalance != null &&
      _welcomeShownForMemberId != loggedInMemberId &&
      !_welcomeDialogPending;

  /// Marks the popup as scheduled. No notify — no UI depends on this flag.
  void markWelcomeScheduled() {
    _welcomeDialogPending = true;
  }

  /// Marks the popup as shown for this login. Notifies so Home rebuilds
  /// with shouldShowWelcome false.
  void markWelcomeShown() {
    _welcomeShownForMemberId = loggedInMemberId;
    _welcomeDialogPending = false;
    notifyListeners();
  }

  /// Clears the scheduling guard (e.g. Home was disposed before the
  /// first frame ran) so the popup can be scheduled again this login.
  void clearWelcomePending() {
    _welcomeDialogPending = false;
  }

  // ---- Savings celebration (once per login, after the welcome popup) ----
  String? _celebrationShownForMemberId;
  bool _celebrationDialogPending = false;

  /// Amount the logged-in member saved this month, or null when no
  /// celebration applies: saved = fair share (budget / 3) - the
  /// member's share, only when saved > 0 AND the house is under
  /// budget (spent < budget). Computed from live balances, never
  /// hardcoded. On the benchmark: Ali 116.67, Ayesha 316.67,
  /// Bilal 366.67.
  double? get celebrationSavedAmount {
    final b = balances;
    final active = activeBalance;
    if (b == null || active == null) return null;
    final budget = double.tryParse(b.budget) ?? 0;
    final spent = double.tryParse(b.totalSpending) ?? 0;
    final share = double.tryParse(active.share) ?? 0;
    if (budget <= 0 || spent >= budget) return null;
    final saved = budget / 3 - share;
    if (saved <= 0) return null;
    return saved;
  }

  /// Month-over-month savings for the logged-in member (see
  /// [monthOverMonthSavedFor]): last month's share minus this
  /// month's share from the recorded expense history. Null when
  /// there is no last-month history or no improvement — the
  /// celebration then shows without a comparison line or poppers.
  double? get monthOverMonthSaved {
    final id = loggedInMember?.id;
    if (id == null) return null;
    return monthOverMonthSavedFor(recentExpenses, id);
  }

  bool get shouldShowCelebration =>
      isLoggedIn &&
      celebrationSavedAmount != null &&
      _celebrationShownForMemberId != loggedInMemberId &&
      !_celebrationDialogPending;

  void markCelebrationScheduled() {
    _celebrationDialogPending = true;
  }

  void markCelebrationShown() {
    _celebrationShownForMemberId = loggedInMemberId;
    _celebrationDialogPending = false;
    notifyListeners();
  }

  void clearCelebrationPending() {
    _celebrationDialogPending = false;
  }

  // ---- Activity log ----
  void _logActivity({
    required String type,
    required String title,
    required String amount,
    required String memberId,
    String detail = '',
  }) {
    activityLog.add(ActivityEntry(
      type: type,
      title: title,
      amount: amount,
      memberId: memberId,
      detail: detail,
      timestamp: DateTime.now(),
    ));
  }

  // ---- Profile picture ----
  Uint8List? profileImageFor(String memberId) => profileImages[memberId];

  Future<void> setProfileImage(Uint8List bytes) async {
    final id = loggedInMemberId;
    if (id == null) return;
    profileImages[id] = bytes;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = base64Encode(bytes);
      if (encoded.length < 1000000) {
        await prefs.setString('profile_image_$id', encoded);
      }
    } catch (_) {
      // Session-only then; the picture still shows until reload.
    }
  }

  Future<void> _loadProfileImages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var changed = false;
      for (final m in members.isEmpty
          ? ['M01', 'M02', 'M03']
          : members.map((m) => m.id)) {
        final encoded = prefs.getString('profile_image_$m');
        if (encoded != null) {
          profileImages[m] = base64Decode(encoded);
          changed = true;
        }
      }
      if (changed) notifyListeners();
    } catch (_) {
      // No persisted pictures; avatars stay initials-based.
    }
  }

  // ---- Category caps (persisted locally) ----
  Future<void> _loadCaps() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('category_caps');
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        categoryCaps = map.map((k, v) => MapEntry(k, (v as num).toInt()));
        notifyListeners();
      }
    } catch (_) {
      // No caps persisted yet; everything stays unset.
    }
  }

  Future<void> _persistCaps() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('category_caps', jsonEncode(categoryCaps));
    } catch (_) {
      // Caps stay in memory for this session.
    }
  }

  Future<void> setCategoryCap(String category, int paisa) async {
    categoryCaps[category] = paisa;
    notifyListeners();
    await _persistCaps();
  }

  Future<void> clearCategoryCap(String category) async {
    categoryCaps.remove(category);
    notifyListeners();
    await _persistCaps();
  }

  /// Real login: member + password, checked by POST /api/auth/login.
  /// On success the token is stored, the logged-in member AND the
  /// active member become that member at once (so Home, Shopping,
  /// Expenses and Settle Up all agree immediately), the welcome popup
  /// is armed for this login, and data is refreshed. On a wrong
  /// password returns false with errorMessage 'Wrong password, try
  /// again' and stays logged out.
  Future<bool> loginWithPassword({
    required String memberId,
    required String password,
  }) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result =
          await _repository.login(memberId: memberId, password: password);
      sessionToken = result.token;
      loggedInMemberId = result.member.id;
      activeMemberId = result.member.id;
      _welcomeShownForMemberId = null;
      _welcomeDialogPending = false;
      await refresh();
      return true;
    } on ApiException catch (e) {
      errorMessage = e.message;
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Google login: a Google ID token the backend has verified, plus
  /// the member the user picked. Same session handling as the
  /// password login — token stored, logged-in + active member set,
  /// welcome popup armed, data refreshed. A rejected token returns
  /// false with the verification error and stays logged out.
  /// (The Firebase credential sign-in for this Google account
  /// already happened inside RealGoogleAuthService.signIn().)
  Future<bool> loginWithGoogle({
    required String idToken,
    required String memberId,
  }) async {
    if (isBusy) return false;
    _usedGoogleSignIn = true;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await _repository.loginWithGoogle(
        idToken: idToken,
        memberId: memberId,
      );
      sessionToken = result.token;
      loggedInMemberId = result.member.id;
      activeMemberId = result.member.id;
      _welcomeShownForMemberId = null;
      _welcomeDialogPending = false;
      await refresh();
      return true;
    } on ApiException catch (e) {
      errorMessage = e.message;
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  // ---- Phase 2: Firebase Auth ----

  /// The member id linked to the current Firebase session, if any.
  /// Null when signed out or never linked (then the login screen
  /// shows the member pick).
  Future<String?> firebaseMemberId() async {
    final service = firebaseAuth;
    final session = firebaseSession;
    if (service == null || session == null) return null;
    return service.memberIdFor(session.uid);
  }

  /// Picks up the Firebase session after a Google sign-in (the
  /// credential sign-in already happened in RealGoogleAuthService)
  /// so the gate state is current before the member pick.
  void syncFirebaseSession() {
    final session = firebaseAuth?.currentSession;
    if (session == null) return;
    firebaseSession = session;
    _updateFirebaseStatus();
    notifyListeners();
  }

  /// Remembers which household member this Firebase user is, and
  /// syncs the Firestore profile (best-effort, inside the service).
  Future<void> saveFirebaseMember(String memberId) async {
    final service = firebaseAuth;
    final session = firebaseSession;
    if (service == null || session == null) return;
    await service.saveMemberId(session.uid, memberId);
    await service.syncProfile(memberId: memberId);
  }

  /// Applies a signed-in Firebase session to the app: the member
  /// becomes logged-in + active, the welcome popup is armed, and
  /// data is refreshed. When there is no backend token (email-only
  /// sign-in) the refresh 401s — the notice below replaces the
  /// backend's misleading 'Session expired' text (see refresh()).
  Future<void> _applyFirebaseSession(
    FirebaseSession session,
    String memberId,
  ) async {
    loggedInMemberId = memberId;
    activeMemberId = memberId;
    _welcomeShownForMemberId = null;
    _welcomeDialogPending = false;
    await firebaseAuth?.saveMemberId(session.uid, memberId);
    await refresh();
    notifyListeners();
  }

  /// Email/password sign-in via Firebase. Returns false with
  /// [errorMessage] set on failure. On success the AuthGate state
  /// decides what the user sees next: unverified → verification
  /// screen; verified with a saved member link → Home; verified
  /// without one → the login screen's member pick.
  Future<bool> signInWithFirebaseEmail({
    required String email,
    required String password,
  }) async {
    final service = firebaseAuth;
    if (service == null || isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result =
          await service.signInWithEmail(email: email, password: password);
      switch (result) {
        case FirebaseAuthFailure(:final message):
          errorMessage = message;
          return false;
        case FirebaseAuthSuccess(:final session):
          final s = session;
          if (s == null) {
            errorMessage = 'Something went wrong. Please try again.';
            return false;
          }
          firebaseSession = s;
          _updateFirebaseStatus();
          if (firebaseStatus == FirebaseAuthStatus.needsVerification) {
            return true;
          }
          final memberId = await service.memberIdFor(s.uid);
          if (memberId == null) return true;
          await _applyFirebaseSession(s, memberId);
          return true;
      }
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Email/password sign-up via Firebase: creates the account, sends
  /// the verification email, links the picked household member, and
  /// routes the user to the verification screen (the gate blocks app
  /// access until the email is verified). Returns false with
  /// [errorMessage] set on failure.
  Future<bool> signUpWithFirebaseEmail({
    required String displayName,
    required String email,
    required String password,
    required String memberId,
  }) async {
    final service = firebaseAuth;
    if (service == null || isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await service.signUpWithEmail(
        email: email,
        password: password,
        displayName: displayName,
      );
      switch (result) {
        case FirebaseAuthFailure(:final message):
          errorMessage = message;
          return false;
        case FirebaseAuthSuccess(:final session):
          final s = session;
          if (s == null) {
            errorMessage = 'Something went wrong. Please try again.';
            return false;
          }
          firebaseSession = s;
          _updateFirebaseStatus();
          await service.saveMemberId(s.uid, memberId);
          await service.syncProfile(
              displayName: displayName, memberId: memberId);
          return true;
      }
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Demo login via Firebase Auth: create-or-sign-in the demo user
  /// (ali.demo@splitnest.app etc.), then take a backend session with
  /// the same demo password so household data loads. Demo sessions
  /// bypass the verification gate. Without a Firebase service wired
  /// in (tests, Firebase init failed) this is exactly the old
  /// backend-only demo login.
  Future<bool> loginWithDemo({required String memberId}) async {
    final demo = demoForMember(memberId);
    if (demo == null) return false;
    final service = firebaseAuth;
    if (service == null) {
      return loginWithPassword(memberId: memberId, password: demo.password);
    }
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await service.signInDemo(demo);
      switch (result) {
        case FirebaseAuthFailure(:final message):
          errorMessage = message;
          return false;
        case FirebaseAuthSuccess(:final session):
          final s = session;
          if (s == null) {
            errorMessage = 'Something went wrong. Please try again.';
            return false;
          }
          firebaseSession = s;
          _updateFirebaseStatus();
          try {
            final backend = await _repository.login(
              memberId: memberId,
              password: demo.password,
            );
            sessionToken = backend.token;
          } on ApiException {
            // Backend down or unreachable: the Firebase demo identity
            // still signs the user in; data stays unloaded and the
            // refresh below surfaces the backend error honestly.
          }
          await service.syncProfile(
              displayName: demo.name, memberId: memberId);
          await _applyFirebaseSession(s, memberId);
          return true;
      }
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Completes a Firebase sign-in that has no member link yet (the
  /// login screen's member pick): links the member and enters Home.
  Future<bool> completeFirebaseMemberPick(String memberId) async {
    final session = firebaseSession;
    final service = firebaseAuth;
    if (service == null || session == null || isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await service.saveMemberId(session.uid, memberId);
      await service.syncProfile(memberId: memberId);
      await _applyFirebaseSession(session, memberId);
      return true;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Re-checks whether the signed-in user's email is verified (after
  /// they clicked the link). True when verified — the member link is
  /// applied and Home opens. False keeps the user on the
  /// verification screen.
  Future<bool> refreshVerificationStatus() async {
    final service = firebaseAuth;
    if (service == null) return false;
    final session = await service.reloadCurrentUser();
    if (session == null) {
      errorMessage = 'You are signed out. Please sign in again.';
      notifyListeners();
      return false;
    }
    firebaseSession = session;
    _updateFirebaseStatus();
    if (firebaseStatus != FirebaseAuthStatus.signedIn) {
      notifyListeners();
      return false;
    }
    final memberId = await service.memberIdFor(session.uid);
    if (memberId == null) {
      notifyListeners();
      return true;
    }
    await _applyFirebaseSession(session, memberId);
    return true;
  }

  /// Re-sends the verification email to the current user.
  Future<bool> resendVerificationEmail() async {
    final service = firebaseAuth;
    if (service == null) return false;
    final sent = await service.sendEmailVerification();
    if (!sent) {
      errorMessage =
          'Could not send the verification email. Try again in a bit.';
      notifyListeners();
    }
    return sent;
  }

  /// Sends the password-reset email. True means accepted for
  /// sending (it does not reveal whether the address has an
  /// account). False sets [errorMessage].
  Future<bool> sendFirebasePasswordReset(String email) async {
    final service = firebaseAuth;
    if (service == null) return false;
    final result = await service.sendPasswordReset(email: email);
    switch (result) {
      case FirebaseAuthFailure(:final message):
        errorMessage = message;
        notifyListeners();
        return false;
      case FirebaseAuthSuccess():
        return true;
    }
  }

  /// Logout: signs out of Firebase AND Google, clears the backend
  /// token and all local session state, and returns to login. Each
  /// provider sign-out is best-effort — a provider failure never
  /// blocks the local logout. Callers need not await it.
  Future<void> logout() async {
    final firebaseService = firebaseAuth;
    if (firebaseService != null && firebaseSession != null) {
      try {
        await firebaseService.signOut();
      } catch (_) {
        // Local logout continues regardless of a provider hiccup.
      }
    }
    if (_usedGoogleSignIn) {
      _usedGoogleSignIn = false;
      try {
        await googleAuth.signOut();
      } catch (_) {
        // Local logout continues regardless.
      }
    }
    _clearLocalSession();
    firebaseSession = null;
    firebaseStatus = FirebaseAuthStatus.signedOut;
    notifyListeners();
  }

  /// Clears the in-app session (backend token, logged-in member,
  /// welcome/celebration state, activity log, error). Used by
  /// [logout] and by the auth-state listener on external sign-out.
  void _clearLocalSession() {
    _repository.clearToken();
    sessionToken = null;
    loggedInMemberId = null;
    _welcomeShownForMemberId = null;
    _welcomeDialogPending = false;
    _celebrationShownForMemberId = null;
    _celebrationDialogPending = false;
    activityLog = [];
    errorMessage = null;
  }

  Member? get loggedInMember => members
      .where((m) => m.id == loggedInMemberId)
      .firstOrNull;

  bool isLoading = false;
  bool isBusy = false;
  String? errorMessage;

  BalanceRow? get activeBalance => balances?.rows
      .where((b) => b.memberId == activeMemberId)
      .firstOrNull;

  int get pendingCount => shopping.where((i) => i.isPending).length;

  // NOTE: there is no free member switcher. The member is set at
  // login() and changed via logout + login again.

  Future<void> refresh() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _repository.getMembers(),
        _repository.getShopping(),
        _repository.getBalances(),
        _repository.getFixedExpenses(),
      ]);
      members = results[0] as List<Member>;
      shopping = results[1] as List<ShoppingItem>;
      balances = results[2] as Balances;
      fixedExpenses = results[3] as List<FixedExpense>;
      if (members.isNotEmpty &&
          members.every((m) => m.id != activeMemberId)) {
        activeMemberId = members.first.id;
      }
    } on ApiException catch (e) {
      errorMessage = e.message;
      // Email-only Firebase sign-in: there is no backend token (the
      // Node backend issues sessions only for member passwords and
      // verified Google ID tokens), so every call 401s. Say so
      // plainly instead of the backend's 'Session expired' text.
      if (sessionToken == null &&
          firebaseSession != null &&
          firebaseStatus == FirebaseAuthStatus.signedIn) {
        errorMessage =
            'Signed in as ${firebaseSession?.email ?? 'your email'}. '
            'The household data still lives on the Node backend, '
            'which does not accept email sign-in yet — sign in with '
            'a member password or Google to load it.';
      }
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Runs a mutation with the submit lock held; refreshes the single
  /// store once on success so every screen rebuilds from fresh data.
  Future<bool> _runMutation(Future<dynamic> Function() fn) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await fn();
      if (result is ExpenseRecord) recentExpenses.insert(0, result);
      await refresh();
      return true;
    } on ApiException catch (e) {
      errorMessage = e.message;
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  // ---- Store actions (the only mutations widgets may call) ----

  Future<bool> addShoppingItem({
    required String title,
    required String unit,
    required int qty,
  }) =>
      _runMutation(() => _repository.addShopping(
            title: title,
            unit: unit,
            qty: qty,
          ));

  Future<bool> checkout({
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
  }) async {
    final ok = await _runMutation(() => _repository.checkout(
          itemIds: itemIds,
          totalPaid: totalPaid,
          payerId: payerId,
          splitMembers: splitMembers,
        ));
    if (ok) {
      _logActivity(
        type: 'checkout',
        title: 'Checkout',
        amount: totalPaid,
        memberId: payerId,
        detail: '${itemIds.length} item(s) · one shared expense',
      );
    }
    return ok;
  }

  Future<bool> addExpense({
    required String title,
    required String category,
    required String date,
    required String amount,
    required String payerId,
    required String splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
    bool repeatMonthly = false,
  }) async {
    final ok = await _runMutation(() => _repository.addExpense(
          title: title,
          category: category,
          date: date,
          amount: amount,
          payerId: payerId,
          splitType: splitType,
          splits: splits,
          splitMembers: splitMembers,
        ));
    if (ok) {
      _logActivity(
        type: 'expense',
        title: 'Expense: $title',
        amount: amount,
        memberId: payerId,
        detail: category,
      );
    }
    // "Repeat monthly": also save it as a fixed template, split
    // equally among the members this expense was split between.
    if (ok && repeatMonthly) {
      final members = splitType == 'custom'
          ? (splits ?? []).map((s) => s['member_id']!).toList()
          : (splitMembers ?? this.members.map((m) => m.id).toList());
      await _runMutation(() => _repository.createFixedExpense(
            title: title,
            category: category,
            amount: amount,
            payerId: payerId,
            splitMemberIds: members,
          ));
    }
    return ok;
  }

  Future<bool> addFixedExpense({
    required String title,
    required String category,
    required String amount,
    required String payerId,
    List<String>? splitMemberIds,
  }) =>
      _runMutation(() => _repository.createFixedExpense(
            title: title,
            category: category,
            amount: amount,
            payerId: payerId,
            splitMemberIds: splitMemberIds,
          ));

  Future<bool> updateFixedExpense({
    required String id,
    String? amount,
  }) =>
      _runMutation(
          () => _repository.updateFixedExpense(id: id, amount: amount));

  Future<bool> deleteFixedExpense(String id) =>
      _runMutation(() => _repository.deleteFixedExpense(id));

  /// Applies every fixed template for the current month (each posts
  /// at most once per month — the backend enforces it). Returns how
  /// many expenses were actually posted this call.
  Future<int> applyFixedForMonth() async {
    if (isBusy) return 0;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    var applied = 0;
    try {
      for (final f in fixedExpenses) {
        final result = await _repository.applyFixedExpense(f.id);
        if (result.applied) {
          applied++;
          if (result.expense != null) {
            recentExpenses.insert(0, result.expense!);
          }
          _logActivity(
            type: 'expense',
            title: 'Fixed: ${f.title}',
            amount: f.amount,
            memberId: f.payerId,
            detail: 'Fixed monthly',
          );
        }
      }
      await refresh();
      return applied;
    } on ApiException catch (e) {
      errorMessage = e.message;
      return applied;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<bool> settle({
    required String senderId,
    required String recipientId,
    required String amount,
  }) async {
    final ok = await _runMutation(() => _repository.settle(
          senderId: senderId,
          recipientId: recipientId,
          amount: amount,
        ));
    if (ok) {
      _logActivity(
        type: 'settle',
        title: 'Settlement',
        amount: amount,
        memberId: senderId,
        detail: '$senderId → $recipientId',
      );
    }
    return ok;
  }

  /// Shows a message on the login page (e.g. a cancelled Google
  /// sign-in). The login screen's error banner displays it.
  void showError(String message) {
    errorMessage = message;
    notifyListeners();
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }
}
