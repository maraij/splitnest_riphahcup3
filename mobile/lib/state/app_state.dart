import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/money.dart';
import '../data/firebase_auth_service.dart';
import '../data/google_auth_service.dart';
import '../data/repository.dart';
import '../domain/balances.dart';
import '../domain/insights.dart';
import '../domain/invitations.dart';
import '../domain/models.dart';

/// AppState — the SINGLE source of truth for the whole app.
///
/// One store holds members, budget (via balances), shopping, expenses,
/// payments, balances and the logged-in member. Widgets read from
/// Provider and call these store methods only — they never call
/// Firestore, never hold app data in their own setState, and never
/// refresh per-screen. Every mutation refreshes this store once and
/// all screens rebuild from it.
///
/// Data flow (Phase 3): Firebase Auth identity → [ensureGroup] in
/// the [SplitNestRepository] (a per-user household group, seeded with
/// the 3-member roster and the PKR 5,000 budget) → the repository's
/// typed Firestore reads → [computeBalances] here → the screens.
/// There is no Node backend any more: no API base URL, no HTTP, no
/// backend session token. The repository interface is the seam tests
/// substitute fakes through.
class AppState extends ChangeNotifier {
  AppState({
    SplitNestRepository? repository,
    GoogleAuthService? googleAuth,
    this.firebaseAuth,
    bool? initialDarkMode,
  })  : _repository = repository ?? const UnavailableSplitNestRepository(),
        googleAuth = googleAuth ?? RealGoogleAuthService() {
    _isDarkMode = initialDarkMode ?? false;
    // When the caller did not preload the saved theme (tests), load
    // it here; main() preloads it before first paint instead.
    if (initialDarkMode == null) _loadThemeMode();
    // Warm the prefs cache in the background (see [_prefs]): the
    // first refresh after login reads the persisted current group
    // from it without ever awaiting the store.
    unawaited(_ensurePrefs());
    _loadCaps();
    _loadProfileImages();
    // Phase 2 (Auth): when a Firebase auth service is wired in
    // (production, Firebase initialised), the AuthGate listens to
    // FirebaseAuth.authStateChanges(). Without one (tests, or
    // Firebase init failed) the app runs on a local demo/Google
    // identity instead — the data still comes from the repository,
    // which is the Unavailable one when Firebase never initialised,
    // so the app shows the cloud-unavailable state honestly.
    final firebaseService = firebaseAuth;
    if (firebaseService != null) {
      firebaseSession = firebaseService.currentSession;
      _updateFirebaseStatus();
      _firebaseSub =
          firebaseService.authStateChanges.listen(_onFirebaseSession);
      _restoreFirebaseSession();
    }
  }

  SplitNestRepository _repository;

  /// Swaps the data source (used by main.dart when a Firebase retry
  /// succeeds after the app started on the Unavailable repository).
  /// Reloads the household when a user is already signed in.
  void useRepository(SplitNestRepository repository) {
    _repository = repository;
    groupId = null;
    if (isLoggedIn) {
      unawaited(refresh());
    } else {
      notifyListeners();
    }
  }

  /// Google sign-in service (real in production, fake in widget
  /// tests). The login screen calls it; the store never talks to
  /// Google directly.
  final GoogleAuthService googleAuth;

  /// Firebase Auth service (real in production when Firebase
  /// initialised, fake in auth tests, null in the older widget
  /// tests and when Firebase init failed). Null means the Firebase
  /// auth flows are unavailable — demo and Google fall back to a
  /// local identity (see [loginWithDemo] / [loginWithGoogle]) and
  /// the login screen hides the email mode.
  final FirebaseAuthService? firebaseAuth;
  StreamSubscription<FirebaseSession?>? _firebaseSub;

  /// The current Firebase session, if any. Null when signed out or
  /// when no Firebase auth service is wired in and no local demo /
  /// Google identity has been created yet.
  FirebaseSession? firebaseSession;

  /// Gate state from the Firebase session (see [FirebaseAuthStatus]).
  /// Meaningless when [firebaseAuth] is null — the login state
  /// decides then.
  FirebaseAuthStatus firebaseStatus = FirebaseAuthStatus.signedOut;

  bool get firebaseAuthEnabled => firebaseAuth != null;

  /// True only for the seeded demo identities
  /// (`*.demo@splitnest.app`, or a local demo session when Firebase
  /// is not wired in). Demo users may load the demo benchmark; real
  /// users never see that action.
  bool get isDemoUser => firebaseSession?.isDemo ?? false;

  /// True only when the popup may be shown: logged in, balances loaded
  /// (so the balance line is never a wrong/zero guess), and not yet
  /// shown or scheduled for this login.
  bool get shouldShowWelcome =>
      isLoggedIn &&
      balances != null &&
      activeBalance != null &&
      _welcomeShownForMemberId != loggedInMemberId &&
      !_welcomeDialogPending;

  /// The UID the repository records as the actor of writes: the
  /// Firebase UID when signed in through Firebase, otherwise a
  /// stable local identity for the logged-in member.
  String get currentUid =>
      firebaseSession?.uid ?? 'local-${loggedInMemberId ?? 'unknown'}';

  /// True only when a Google sign-in happened this session, so logout
  /// knows to sign out of Google too. (Widget tests that only use
  /// demo login never touch the Google plugin this way.)
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
  /// signing in again, and their Firestore household loads — this is
  /// the path that makes email-only users work end-to-end now that
  /// data lives in Firestore instead of behind a backend token.
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

  /// The household group this session loads data from. Null until
  /// the first successful refresh after login.
  String? groupId;

  /// Alias for [groupId]: the currently selected household
  /// (Phase 4 — the user may belong to several groups and switch
  /// between them; persisted per user, see [switchGroup]).
  String? get currentGroupId => groupId;

  /// Every group the signed-in user belongs to (own household first),
  /// for the group switcher.
  List<GroupSummary> userGroups = [];

  /// The user's own role in the current group (`owner` | `admin` |
  /// `member`), or null when it is not known yet. Drives invite
  /// gating in the UI; the repository and the security rules enforce
  /// it again on every write.
  String? currentRole;

  /// True when the user may send and revoke invitations in the
  /// current group (owner or admin).
  bool get canInvite => currentRole == 'owner' || currentRole == 'admin';

  /// True when the user owns the current group (only an owner may
  /// grant the admin role).
  bool get isGroupOwner => currentRole == 'owner';

  /// Invitations this group sent, newest first (owner/admin only).
  List<Invitation> groupInvitations = [];

  /// Invitations addressed to the signed-in user's email, newest
  /// first (any status; expiry is derived — see [Invitation]).
  List<Invitation> myInvitations = [];

  /// Pending invitations this group sent.
  int get pendingInviteCount =>
      groupInvitations.where((i) => i.isPending).length;

  /// Pending invitations addressed to the signed-in user.
  List<Invitation> get myPendingInvitations =>
      myInvitations.where((i) => i.isPending).toList();

  /// Monthly household budget in integer paisa (PKR 5,000 = 500000).
  /// Loaded from the group document; the default is the seeded value.
  int budgetPaisa = defaultBudgetPaisa;

  List<Member> members = [];

  /// Members to offer in the sign-up / member-pick lists. Normally
  /// the group roster; when it is empty (not logged in yet) the
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

  /// All expenses in the group, newest first — the full Firestore
  /// history, not a session-only list. (There was no GET /api/expenses
  /// endpoint on the old backend, so this used to be session-only;
  /// the migration makes the history persist across reloads.)
  List<ExpenseRecord> recentExpenses = [];

  /// All recorded payments (settlements) in the group, newest first.
  List<PaymentRecord> payments = [];

  /// Fixed monthly expense templates (persisted in Firestore).
  List<FixedExpense> fixedExpenses = [];

  /// Whether any loaded expense is clearly-labelled demo benchmark
  /// data. The "Load demo benchmark" action hides once this is true.
  bool demoDataLoaded = false;

  /// Activity log (Timeline screen): every successful checkout,
  /// expense post and settlement this session, newest last. The app
  /// also persists each entry to the cloud log (best-effort — the
  /// rules make cloud activity Functions-written until they deploy),
  /// but this session log is the Timeline source of truth.
  List<ActivityEntry> activityLog = [];

  /// Profile pictures, picked by the user, keyed by member id.
  /// Kept in memory; also persisted as base64 in SharedPreferences
  /// when small enough (best effort — a huge photo stays
  /// session-only rather than breaking storage). Local for now —
  /// Storage upload is a later phase.
  Map<String, Uint8List> profileImages = {};

  /// Per-category budget caps in paisa, keyed by cap category.
  /// UNSET by default: no cap = no bar, no alert. Persisted in
  /// SharedPreferences; a missing entry means the user never set it.
  Map<String, int> categoryCaps = {};

  String activeMemberId = 'M01';

  /// Logged-in member id. Null until a successful login; Home is
  /// unreachable while null.
  String? loggedInMemberId;
  bool get isLoggedIn => loggedInMemberId != null;

  /// Welcome popup, once per login session: the member id the popup was
  /// last shown for (null = not shown this login), plus a scheduling
  /// guard so a rebuild before the first frame cannot queue it twice.
  String? _welcomeShownForMemberId;
  bool _welcomeDialogPending = false;

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
    final entry = ActivityEntry(
      type: type,
      title: title,
      amount: amount,
      memberId: memberId,
      detail: detail,
      timestamp: DateTime.now(),
    );
    activityLog.add(entry);
    // Persist to the cloud log too (best-effort — see
    // SplitNestRepository.logActivity; a rules denial there never
    // fails the mutation this entry describes).
    final gid = groupId;
    if (gid != null) {
      unawaited(
        _repository.logActivity(
          groupId: gid,
          entry: entry,
          actorUid: currentUid,
        ),
      );
    }
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

  // ---- Firebase Auth (identity) + Firestore (data) ----

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

  String _displayNameFor(String memberId) {
    final session = firebaseSession;
    if (session?.displayName != null && session!.displayName!.isNotEmpty) {
      return session.displayName!;
    }
    final demo = demoForMember(memberId);
    if (demo != null) return demo.name;
    return memberOptions
        .where((m) => m.id == memberId)
        .firstOrNull
        ?.name ??
        'Member';
  }

  /// Applies a signed-in session to the app: the member becomes
  /// logged-in + active, the welcome popup is armed, and the
  /// Firestore household loads. This is the same path for demo,
  /// Google and email sign-ins — data no longer needs any backend
  /// token, so email-only users now load their household here too
  /// (the Phase 2 limit this migration fixes).
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

  /// Demo login: create-or-sign-in the demo user
  /// (ali.demo@splitnest.app etc.) through Firebase Auth, then load
  /// their Firestore household. Demo sessions bypass the verification
  /// gate. Without a Firebase service wired in (tests, Firebase init
  /// failed) the demo identity is local — the data still comes from
  /// the repository, which is the Unavailable one when Firebase
  /// never initialised, so the app shows the cloud-unavailable state
  /// instead of fake data.
  Future<bool> loginWithDemo({required String memberId}) async {
    final demo = demoForMember(memberId);
    if (demo == null) return false;
    final service = firebaseAuth;
    if (service == null) {
      if (isBusy) return false;
      isBusy = true;
      errorMessage = null;
      notifyListeners();
      try {
        firebaseSession = FirebaseSession(
          uid: 'demo-$memberId',
          email: demo.email,
          displayName: demo.name,
          emailVerified: false,
          isDemo: true,
        );
        _updateFirebaseStatus();
        await _applyFirebaseSession(firebaseSession!, memberId);
        return true;
      } finally {
        isBusy = false;
        notifyListeners();
      }
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

  /// Google login: the Google account chooser and the Firebase
  /// credential sign-in already happened inside GoogleAuthService —
  /// this only links the picked household member to that Firebase
  /// identity and loads the Firestore household. There is no backend
  /// token exchange any more. Without a Firebase service wired in
  /// (tests, Firebase init failed) the identity is local; the data
  /// still comes from the repository (Unavailable when Firebase
  /// never initialised, so the cloud-unavailable state shows).
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
      final service = firebaseAuth;
      if (service == null) {
        firebaseSession = const FirebaseSession(
          uid: 'local-google',
          email: null,
          displayName: null,
          emailVerified: true,
          isDemo: false,
        );
        _updateFirebaseStatus();
        await _applyFirebaseSession(firebaseSession!, memberId);
        return true;
      }
      var session = service.currentSession;
      if (session == null) {
        final result =
            await service.signInWithGoogle(idToken: idToken);
        switch (result) {
          case FirebaseAuthFailure(:final message):
            errorMessage = message;
            return false;
          case FirebaseAuthSuccess(session: final s):
            session = s;
        }
      }
      if (session == null) {
        errorMessage ??= 'Something went wrong. Please try again.';
        return false;
      }
      firebaseSession = session;
      _updateFirebaseStatus();
      await _applyFirebaseSession(session, memberId);
      return true;
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

  /// Logout: signs out of Firebase AND Google, clears all local
  /// session state and the loaded household data, and returns to
  /// login. Each provider sign-out is best-effort — a provider
  /// failure never blocks the local logout. Callers need not await it.
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

  /// Clears the in-app session (logged-in member, loaded household
  /// data, welcome/celebration state, activity log, error). Used by
  /// [logout] and by the auth-state listener on external sign-out.
  /// The loaded data is cleared so a later login never flashes the
  /// previous user's household.
  void _clearLocalSession() {
    loggedInMemberId = null;
    groupId = null;
    userGroups = [];
    currentRole = null;
    groupInvitations = [];
    myInvitations = [];
    _groupOverride = null;
    budgetPaisa = defaultBudgetPaisa;
    members = [];
    shopping = [];
    balances = null;
    recentExpenses = [];
    payments = [];
    fixedExpenses = [];
    demoDataLoaded = false;
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

  /// Payments still waiting for verification (status `recorded`).
  List<PaymentRecord> get pendingPayments =>
      payments.where((p) => p.status == 'recorded').toList();

  // NOTE: there is no free member switcher. The member is set at
  // login() and changed via logout + login again.

  /// Loads the signed-in user's household from the repository:
  /// resolves (or creates) the group, reads members, shopping,
  /// expenses, payments and fixed templates, and computes balances
  /// from that history. Before login this is a no-op — there is no
  /// household to load and no error to show. When Firestore is
  /// unavailable (database not created yet, offline, rules not
  /// deployed) [errorMessage] carries the plain cloud-unavailable
  /// text and every data list stays as it was — the app never shows
  /// fake data.
  Future<void> refresh() async {
    if (!isLoggedIn) {
      isLoading = false;
      return;
    }
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final memberId = loggedInMemberId!;
      final info = await _repository.ensureGroup(
        uid: currentUid,
        displayName: _displayNameFor(memberId),
        email: firebaseSession?.email,
        legacyMemberId: memberId,
        isDemo: isDemoUser,
      );
      // Phase 4 (shared households): the user may belong to several
      // groups — their own household group plus every group they
      // joined by accepting an invitation. The current group is the
      // persisted choice when it is still one of theirs, otherwise
      // their own household group. Single-group users (the demo
      // benchmark, every existing flow) always land on their own
      // group, exactly as before.
      var groups = <GroupSummary>[];
      try {
        groups = await _repository.listUserGroups(
          uid: currentUid,
          email: firebaseSession?.email,
        );
      } catch (_) {
        groups = [];
      }
      if (groups.isEmpty) {
        groups = [
          GroupSummary(
            groupId: info.groupId,
            name: 'SplitNest Household',
            budgetPaisa: info.budgetPaisa,
            role: 'owner',
          ),
        ];
      }
      userGroups = groups;
      // The current group, in priority order: this session's
      // explicit choice, then the persisted choice, then the user's
      // own household group. The persisted choice is only honoured
      // when no explicit choice exists, so it can never yank the
      // user out of a household they switched to; and it is read
      // on every refresh, so a prefs cache that was not ready at
      // the first refresh still restores the household on the next
      // one. Single-group users always land on their own group,
      // exactly as before.
      final saved = _prefs?.getString('$_currentGroupKeyPrefix$currentUid');
      unawaited(_ensurePrefs());
      final selected = (_groupOverride != null &&
              groups.any((g) => g.groupId == _groupOverride))
          ? _groupOverride!
          : (saved != null && groups.any((g) => g.groupId == saved))
              ? saved
              : info.groupId;
      groupId = selected;
      final gid = groupId!;
      budgetPaisa = groups
              .where((g) => g.groupId == gid)
              .firstOrNull
              ?.budgetPaisa ??
          info.budgetPaisa;
      final results = await Future.wait([
        _repository.getMembers(gid),
        _repository.getShopping(gid),
        _repository.getExpenses(gid),
        _repository.getPayments(gid),
        _repository.getFixedExpenses(gid),
      ]);
      members = results[0] as List<Member>;
      shopping = results[1] as List<ShoppingItem>;
      recentExpenses = results[2] as List<ExpenseRecord>;
      payments = results[3] as List<PaymentRecord>;
      fixedExpenses = results[4] as List<FixedExpense>;
      demoDataLoaded = recentExpenses.any((e) => e.isDemo);
      balances = computeBalances(
        expenses: recentExpenses,
        payments: payments,
        members: members,
        budgetPaisa: budgetPaisa,
      );
      if (members.isNotEmpty &&
          members.every((m) => m.id != activeMemberId)) {
        activeMemberId = members.first.id;
      }
      // Role + invitations load after the household data, and each
      // in its own try/catch: an invitation read must never break
      // the household load (e.g. a plain member may not list the
      // group's sent invitations — the rules deny it, so the list
      // is simply empty for them).
      try {
        currentRole = await _repository.getMyRole(
          groupId: gid,
          uid: currentUid,
        );
      } catch (_) {
        currentRole = null;
      }
      await _loadInvitations();
    } on CloudDataException catch (e) {
      errorMessage = e.message;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Runs a mutation with the submit lock held; refreshes the single
  /// store once on success so every screen rebuilds from fresh data.
  /// A cloud failure sets the plain error message and returns false;
  /// nothing is ever shown as succeeding when it did not.
  Future<bool> _runMutation(Future<dynamic> Function() fn) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await fn();
      await refresh();
      return true;
    } on CloudDataException catch (e) {
      errorMessage = e.message;
      return false;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  String get _groupOrUnavailable {
    final gid = groupId;
    if (gid == null) throw const CloudDataException(cloudUnavailableMessage);
    return gid;
  }

  // ---- Store actions (the only mutations widgets may call) ----

  Future<bool> addShoppingItem({
    required String title,
    required String unit,
    required int qty,
  }) =>
      _runMutation(() => _repository.addShopping(
            groupId: _groupOrUnavailable,
            title: title,
            unit: unit,
            qty: qty,
            actorUid: currentUid,
          ));

  Future<bool> checkout({
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
  }) async {
    final ok = await _runMutation(() => _repository.checkout(
          groupId: _groupOrUnavailable,
          itemIds: itemIds,
          totalPaid: totalPaid,
          payerId: payerId,
          splitMembers: splitMembers,
          actorUid: currentUid,
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
          groupId: _groupOrUnavailable,
          title: title,
          category: category,
          date: date,
          amount: amount,
          payerId: payerId,
          splitType: splitType,
          splits: splits,
          splitMembers: splitMembers,
          actorUid: currentUid,
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
            groupId: _groupOrUnavailable,
            title: title,
            category: category,
            amount: amount,
            payerId: payerId,
            splitMemberIds: members,
            actorUid: currentUid,
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
            groupId: _groupOrUnavailable,
            title: title,
            category: category,
            amount: amount,
            payerId: payerId,
            splitMemberIds: splitMemberIds,
            actorUid: currentUid,
          ));

  Future<bool> updateFixedExpense({
    required String id,
    String? amount,
  }) =>
      _runMutation(() => _repository.updateFixedExpense(
          groupId: _groupOrUnavailable, id: id, amount: amount));

  Future<bool> deleteFixedExpense(String id) =>
      _runMutation(() => _repository.deleteFixedExpense(
          groupId: _groupOrUnavailable, id: id));

  /// Applies every fixed template for the current month (each posts
  /// at most once per month — the repository enforces it). Returns how
  /// many expenses were actually posted this call.
  Future<int> applyFixedForMonth() async {
    final gid = groupId;
    if (gid == null || isBusy) return 0;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    var applied = 0;
    try {
      for (final f in fixedExpenses) {
        final result = await _repository.applyFixedExpense(
          groupId: gid,
          id: f.id,
          actorUid: currentUid,
        );
        if (result.applied) {
          applied++;
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
    } on CloudDataException catch (e) {
      errorMessage = e.message;
      return applied;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
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
    if (isBusy) return false;
    final paisa = parsePaisa(amount);
    if (paisa == null || paisa <= 0) {
      errorMessage = 'Settlement amount must be positive.';
      notifyListeners();
      return false;
    }
    // Pre-check against the live ledger so the user gets the plain
    // reason immediately; the repository re-validates before writing.
    final b = balances;
    if (b != null) {
      final error = settlementError(
        nets: {
          for (final r in b.rows) r.memberId: parsePaisa(r.net) ?? 0,
        },
        senderId: senderId,
        recipientId: recipientId,
        amountPaisa: paisa,
      );
      if (error != null) {
        errorMessage = error;
        notifyListeners();
        return false;
      }
    }
    final ok = await _runMutation(() => _repository.recordPayment(
          groupId: _groupOrUnavailable,
          senderId: senderId,
          recipientId: recipientId,
          amount: amount,
          actorUid: currentUid,
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

  /// Verifies a recorded payment (recorded → verified). Only an
  /// owner/admin can do this — on the real database the rules
  /// enforce it and a rejection surfaces as the plain cloud message.
  Future<bool> verifyPayment(String paymentId) => _runMutation(
        () => _repository.verifyPayment(
          groupId: _groupOrUnavailable,
          paymentId: paymentId,
          actorUid: currentUid,
        ),
      );

  // ---- Shared households + invitations (Phase 4) ----

  static const _currentGroupKeyPrefix = 'current_group_id_';

  /// Cached SharedPreferences instance, loaded once in the
  /// background at construction. The household load ([refresh])
  /// NEVER awaits the store: in widget tests without mock values
  /// `getInstance()` never completes, and awaiting it would hang
  /// the load (and its spinner) forever — a `Future.timeout`
  /// around it does not help either, because `pumpAndSettle`
  /// returns while such a timer is pending. In production the
  /// instance is ready long before login (main() already awaited
  /// it for the theme, and the plugin caches it), so the restore
  /// below works there; when the cache is not ready yet, the own
  /// group is the correct default.
  SharedPreferences? _prefs;

  Future<void> _ensurePrefs() async {
    if (_prefs != null) return;
    _prefs = await _prefsOrNull();
  }

  /// SharedPreferences, or null when the store cannot be reached.
  /// Deliberately NO timeout here: `Future.timeout` plants a Timer
  /// that outlives widget tests without mock values and fails them
  /// at teardown ("a Timer is still pending"). A never-completing
  /// background load is harmless; callers never await this on a
  /// UI path anyway (see [_prefs]).
  Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// Explicit current-group choice made this session (group switch
  /// or invite accept). It outranks the persisted choice, so a
  /// switch applies immediately even when the prefs cache is not
  /// ready yet (e.g. in tests).
  String? _groupOverride;

  /// Persists the current-group choice (fire-and-forget: never
  /// awaited on a UI path — see [_prefs]).
  void _persistCurrentGroupId(String gid) {
    unawaited(_storeGroupId(gid));
  }

  Future<void> _storeGroupId(String gid) async {
    try {
      final prefs = _prefs ?? await _prefsOrNull();
      _prefs ??= prefs;
      await prefs?.setString('$_currentGroupKeyPrefix$currentUid', gid);
    } catch (_) {
      // Persistence is best-effort; the in-memory choice still
      // applies for this session.
    }
  }

  String get _currentGroupName =>
      userGroups
          .where((g) => g.groupId == groupId)
          .firstOrNull
          ?.name ??
      'SplitNest Household';

  /// Loads the invitation lists for the current group / user.
  /// Failures leave the lists empty — never an error banner, since
  /// a plain member simply may not list the group's invitations.
  Future<void> _loadInvitations() async {
    groupInvitations = [];
    myInvitations = [];
    final gid = groupId;
    if (gid == null) return;
    final email = firebaseSession?.email;
    if (email != null && email.isNotEmpty) {
      try {
        myInvitations = await _repository.getMyInvitations(email);
      } catch (_) {
        myInvitations = [];
      }
    }
    if (canInvite) {
      try {
        groupInvitations = await _repository.getGroupInvitations(gid);
      } catch (_) {
        groupInvitations = [];
      }
    }
  }

  /// Reloads only the invitation lists (after a send/revoke).
  Future<void> refreshInvitations() async {
    await _loadInvitations();
    notifyListeners();
  }

  /// Switches the current household to one of the user's groups and
  /// reloads the household from it. The choice persists, so the
  /// next launch re-opens the same household. Returns false (with
  /// [errorMessage] set) when the group is not one of the user's.
  Future<bool> switchGroup(String newGroupId) async {
    if (isBusy) return false;
    if (!userGroups.any((g) => g.groupId == newGroupId)) {
      errorMessage = 'That household is not in your list.';
      notifyListeners();
      return false;
    }
    if (newGroupId == groupId) return true;
    _groupOverride = newGroupId;
    _persistCurrentGroupId(newGroupId);
    await refresh();
    return errorMessage == null;
  }

  /// Sends an invitation to join the current group. Only an
  /// owner/admin may invite; only an owner may grant `admin`.
  /// Returns the created invitation (its id is the shareable code),
  /// or null with [errorMessage] set.
  Future<Invitation?> sendInvitation({
    required String email,
    String role = 'member',
  }) async {
    final gid = groupId;
    if (gid == null || isBusy) return null;
    if (!canInvite) {
      errorMessage =
          'Only the household owner or an admin can invite.';
      notifyListeners();
      return null;
    }
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final invite = await _repository.createInvitation(
        groupId: gid,
        groupName: _currentGroupName,
        invitedEmail: email,
        role: role,
        actorUid: currentUid,
        actorEmail: firebaseSession?.email,
        actorName: _displayNameFor(loggedInMemberId!),
      );
      await _loadInvitations();
      _logActivity(
        type: 'invite_sent',
        title: 'Invite sent to ${invite.invitedEmail}',
        amount: '0.00',
        memberId: loggedInMemberId!,
        detail: _currentGroupName,
      );
      return invite;
    } on CloudDataException catch (e) {
      errorMessage = e.message;
      return null;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      return null;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Revokes a pending invitation the current group sent. Only an
  /// owner/admin may revoke.
  Future<bool> revokeInvitation(String invitationId) async {
    final gid = groupId;
    if (gid == null || isBusy) return false;
    if (!canInvite) {
      errorMessage =
          'Only the household owner or an admin can revoke an '
          'invitation.';
      notifyListeners();
      return false;
    }
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await _repository.revokeInvitation(
        groupId: gid,
        invitationId: invitationId,
        actorUid: currentUid,
      );
      await _loadInvitations();
      return true;
    } on CloudDataException catch (e) {
      errorMessage = e.message;
      return false;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Accepts an invitation by code (or a pasted
  /// `splitnest.app/join?code=...` link — the code is extracted
  /// from it). On success the joined group becomes the current
  /// group and its household loads. Returns the accepted invitation,
  /// or null with [errorMessage] set.
  Future<Invitation?> acceptInvitationByCode(String rawCode) async {
    final code = parseInviteCode(rawCode);
    if (code.isEmpty) {
      errorMessage = 'Enter an invite code to join a household.';
      notifyListeners();
      return null;
    }
    return acceptInvitation(code);
  }

  /// Accepts one invitation by id (= code). The repository runs the
  /// accept transaction (membership + mirror + accepted status);
  /// this only switches the current group to the joined household
  /// and logs the join.
  Future<Invitation?> acceptInvitation(String invitationId) async {
    if (isBusy) return null;
    final email = firebaseSession?.email;
    if (email == null || email.isEmpty) {
      errorMessage =
          'Sign in with an email address to accept an invitation.';
      notifyListeners();
      return null;
    }
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final accepted = await _repository.acceptInvitation(
        invitationId: invitationId,
        actorUid: currentUid,
        email: email,
        displayName: _displayNameFor(loggedInMemberId!),
      );
      _groupOverride = accepted.groupId;
      _persistCurrentGroupId(accepted.groupId);
      await refresh();
      _logActivity(
        type: 'member_joined',
        title: 'You joined ${accepted.groupName}',
        amount: '0.00',
        memberId: loggedInMemberId!,
        detail: accepted.groupName,
      );
      return accepted;
    } on CloudDataException catch (e) {
      errorMessage = e.message;
      return null;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      return null;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Loads the clearly-labelled DEMO benchmark into this group.
  /// Demo users only — real users never see the action (the Home
  /// card gates on [isDemoUser]) and the repository never auto-seeds
  /// it. Returns how many benchmark expenses were seeded (0 when
  /// already loaded).
  Future<int> loadDemoBenchmark() async {
    if (!isDemoUser) {
      errorMessage = 'Demo data is only available for demo accounts.';
      notifyListeners();
      return 0;
    }
    final gid = groupId;
    if (gid == null || isBusy) return 0;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final n = await _repository.loadDemoBenchmark(
        groupId: gid,
        actorUid: currentUid,
        actorName: loggedInMember?.name ?? 'Demo',
      );
      await refresh();
      return n;
    } on CloudDataException catch (e) {
      errorMessage = e.message;
      return 0;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      return 0;
    } finally {
      isBusy = false;
      notifyListeners();
    }
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
