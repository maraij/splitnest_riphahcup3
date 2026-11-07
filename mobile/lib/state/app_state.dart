import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/money.dart';
import '../core/services/app_logger.dart';
import '../data/demo_accounts.dart';
import '../data/local_auth_service.dart';
import '../data/local_json_repository.dart';
import '../data/receipt_service.dart';
import '../data/repository.dart';
import '../domain/balances.dart';
import '../domain/chat_message.dart';
import '../domain/expense_auth.dart';
import '../domain/insights.dart';
import '../domain/invitations.dart';
import '../domain/models.dart';
import '../domain/payment_tracking.dart';
import '../features/chatbot/data/chat_context.dart';

/// AppState — the SINGLE source of truth for the whole app.
///
/// One store holds members, budget (via balances), shopping, expenses,
/// payments, balances and the logged-in member. Widgets read from
/// Provider and call these store methods only — they never call
/// lock.json, never hold app data in their own setState, and never
/// refresh per-screen. Every mutation refreshes this store once and
/// all screens rebuild from it.
///
/// Data flow (Phase 6): local auth identity → [ensureGroup] in
/// the [SplitNestRepository] (a per-user household group, seeded with
/// the 3-member roster and the PKR 5,000 budget) → the repository's
/// typed lock.json reads → [computeBalances] here → the screens.
/// There is no backend of any kind any more: no API base URL, no
/// HTTP, no backend session token, no cloud service. The repository
/// interface is the seam tests substitute fakes through.
class AppState extends ChangeNotifier {
  AppState({
    SplitNestRepository? repository,
    LocalAuthService? localAuth,
    bool? initialDarkMode,
    ReceiptService? receiptService,
    AppLogger? logger,
  })  : _repository = repository ?? const UnavailableSplitNestRepository(),
        receiptService = receiptService ?? ReceiptService(),
        logger = logger ?? AppLogger.inMemory(),
        localAuth = localAuth ?? RealLocalAuthService() {
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
    // Phase 6 (Auth): the AuthGate listens to the local auth
    // service's session stream, and the persisted session is
    // restored in the background — a signed-in user re-enters the
    // app without signing in again, and their household loads from
    // lock.json. Without a session the app runs signed out; demo
    // login creates a local demo session (see [loginWithDemo]).
    localSession = this.localAuth.currentSession;
    _localAuthSub =
        this.localAuth.authStateChanges.listen(_onLocalSession);
    unawaited(_restoreLocalSession());
  }

  SplitNestRepository _repository;

  /// Receipt capture / OCR / local file save (Phase 5). Injectable
  /// so tests can substitute a stub; the default is the real
  /// service (the file save is resolved lazily inside the
  /// repository, so building AppState never touches lock.json).
  final ReceiptService receiptService;

  /// Structured log (Phase 7): app start, auth, repository errors,
  /// chatbot calls and invitation actions go here (see
  /// core/services/app_logger.dart). Defaults to a memory-only
  /// logger; main.dart wires the file-backed one. Never carries
  /// passwords, tokens or API keys — the logger redacts them.
  final AppLogger logger;

  /// Loads the store notice (web in-memory warning, recovery note)
  /// without logging in — used by main.dart so the banner can show
  /// on the login screen too. Loading the store also performs the
  /// first-run seed. Never throws; a failure leaves the notice null
  /// and the household load reports failures itself.
  Future<void> loadStoreNotice() async {
    try {
      final repo = _repository;
      if (repo is LocalJsonRepository) {
        await repo.store.load();
        dataNotice = repo.storeNotice;
        notifyListeners();
      }
    } catch (_) {
      // No notice then; the household load reports failures itself.
    }
  }

  /// Swaps the data source. Reloads the household when a user is
  /// already signed in. (Kept for tests; production always uses the
  /// local repository built in main.dart.)
  void useRepository(SplitNestRepository repository) {
    _repository = repository;
    groupId = null;
    if (isLoggedIn) {
      unawaited(refresh());
    } else {
      notifyListeners();
    }
  }

  /// Local auth service (real in production, fake in auth tests).
  /// The login / sign-up / reset screens call it through this
  /// store; the store never talks to lock.json users directly.
  final LocalAuthService localAuth;
  StreamSubscription<LocalSession?>? _localAuthSub;

  /// The current local session, if any. Null when signed out.
  LocalSession? localSession;

  /// True only for the seeded demo identities
  /// (`*.demo@splitnest.app`). Demo users may load the demo
  /// benchmark; real users never see that action.
  bool get isDemoUser => localSession?.isDemo ?? false;

  /// Plain notice from the local store's last load (web in-memory
  /// warning, corrupt-file recovery, …), or null on a normal load.
  /// main.dart shows it as a dismissible banner; null means there
  /// is nothing to warn about.
  String? dataNotice;

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
  /// local account uid when signed in, otherwise a stable local
  /// identity for the logged-in member.
  String get currentUid =>
      localSession?.uid ?? 'local-${loggedInMemberId ?? 'unknown'}';

  @override
  void dispose() {
    _localAuthSub?.cancel();
    super.dispose();
  }

  /// A local session changed underneath us (sign-in, sign-out).
  /// An external sign-out also clears the app login, so Home is
  /// unreachable without a local session.
  void _onLocalSession(LocalSession? session) {
    localSession = session;
    if (session == null && isLoggedIn) _clearLocalSession();
    notifyListeners();
  }

  /// Restores a persisted local session on launch: a signed-in user
  /// with a saved member link re-enters the app without signing in
  /// again, and their lock.json household loads.
  Future<void> _restoreLocalSession() async {
    final session = await localAuth.restoreSession();
    if (session == null) return;
    // A sign-in that landed while this restore was in flight wins.
    // Without this guard a stale launch-time restore can overwrite
    // an explicit login: two AppStates sharing one persisted uid
    // hit it in tests (the second AppState's restore re-applied
    // the first user's session after the second login), and a
    // slow restore could do the same on a real device. Guard on
    // loggedInMemberId, not localSession: the constructor seeds
    // localSession from the auth service's current session, so it
    // can already be set on a fresh AppState sharing a live
    // service — loggedInMemberId is only set once a login has
    // actually been applied (synchronously, at the start of
    // _applyLocalSession).
    if (loggedInMemberId != null) return;
    localSession = session;
    final memberId = session.memberId ??
        await localAuth.memberIdFor(session.uid);
    if (memberId == null) {
      notifyListeners();
      return;
    }
    // Re-check after the member lookup: a login for a different
    // user may have landed while we waited.
    if (loggedInMemberId != null) return;
    await _applyLocalSession(session, memberId);
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
  /// three seeded household members stand in, so sign-up still
  /// works before any household has loaded.
  List<Member> get memberOptions =>
      members.isEmpty ? _fallbackHouseholdMembers : members;

  static final _fallbackHouseholdMembers = [
    Member(id: 'M01', name: 'Ali'),
    Member(id: 'M02', name: 'Ayesha'),
    Member(id: 'M03', name: 'Bilal'),
  ];
  List<ShoppingItem> shopping = [];
  Balances? balances;

  /// All expenses in the group, newest first — the full lock.json
  /// history, not a session-only list. (There was no GET /api/expenses
  /// endpoint on the old backend, so this used to be session-only;
  /// the migration makes the history persist across reloads.)
  List<ExpenseRecord> recentExpenses = [];

  /// All recorded payments (settlements) in the group, newest first.
  List<PaymentRecord> payments = [];

  /// Fixed monthly expense templates (persisted in lock.json).
  List<FixedExpense> fixedExpenses = [];

  /// Whether any loaded expense is clearly-labelled demo benchmark
  /// data. The "Load demo benchmark" action hides once this is true.
  bool demoDataLoaded = false;

  /// Activity log (Timeline screen): every successful checkout,
  /// expense post and settlement this session, newest last. The app
  /// also persists each entry to the local log in lock.json, but
  /// this session log is the Timeline source of truth.
  List<ActivityEntry> activityLog = [];

  /// Profile pictures, picked by the user, keyed by member id.
  /// Kept in memory; also persisted as base64 in SharedPreferences
  /// when small enough (best effort — a huge photo stays
  /// session-only rather than breaking storage). The bytes are also
  /// saved to a local file by the repository (see [setProfileImage]).
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
    // Persist to the local log too (best-effort — see
    // SplitNestRepository.logActivity; a failure there never
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

  /// Profile-photo local paths, keyed by member id, persisted in
  /// SharedPreferences. The local bytes in [profileImages] win when
  /// both exist; the path is what the roster shows.
  Map<String, String> profilePhotoUrls = {};

  String? profilePhotoUrlFor(String memberId) =>
      profilePhotoUrls[memberId] ??
      members
          .where((m) => m.id == memberId)
          .firstOrNull
          ?.photoUrl;

  /// Saves the picked photo locally AND saves its bytes to a local
  /// file (`profile-photos/{uid}/photo.jpg` under the app documents
  /// directory), storing the path on the user's profile. Returns
  /// true when the file save + path store succeeded; false when only
  /// the in-memory copy was saved (file save failed, or web, where
  /// there is nowhere to write it) — the local photo still shows,
  /// and nothing here ever throws.
  Future<bool> setProfileImage(Uint8List bytes) async {
    final id = loggedInMemberId;
    if (id == null) return false;
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
    // Local file save (Phase 5, now local-only): through the
    // repository interface only (never files directly from here) —
    // the path is stored on the profile. Any failure leaves the
    // local photo in place.
    try {
      final url = await _repository.uploadProfilePhoto(
        uid: currentUid,
        bytes: bytes,
      );
      if (url == null) return false;
      final gid = groupId;
      if (gid != null) {
        try {
          await _repository.setUserPhotoUrl(
            groupId: gid,
            uid: currentUid,
            photoUrl: url,
          );
        } catch (_) {
          // The URL is still kept locally below; the profile write
          // is best-effort.
        }
      }
      profilePhotoUrls[id] = url;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('profile_photo_url_$id', url);
      } catch (_) {
        // In-memory URL still applies for this session.
      }
      notifyListeners();
      return true;
    } catch (_) {
      return false;
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
        final url = prefs.getString('profile_photo_url_$m');
        if (url != null) {
          profilePhotoUrls[m] = url;
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

  // ---- Local auth (identity) + lock.json (data) ----

  /// The member id linked to the current local session, if any.
  /// Null when signed out or never linked.
  Future<String?> localMemberId() async {
    final session = localSession;
    if (session == null) return null;
    return session.memberId ?? localAuth.memberIdFor(session.uid);
  }

  String _displayNameFor(String memberId) {
    final session = localSession;
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
  /// lock.json household loads. This is the same path for demo and
  /// email sign-ins — data lives in lock.json, so every signed-in
  /// user loads their household here.
  Future<void> _applyLocalSession(
    LocalSession session,
    String memberId,
  ) async {
    loggedInMemberId = memberId;
    activeMemberId = memberId;
    _welcomeShownForMemberId = null;
    _welcomeDialogPending = false;
    await localAuth.saveMemberId(session.uid, memberId);
    await refresh();
    notifyListeners();
  }

  /// Email/password sign-in against the local accounts in
  /// lock.json. Returns false with [errorMessage] set on failure.
  /// On success the member link decides what happens next: a saved
  /// link → Home; no link → stays on login with a plain message
  /// (sign-up always links a member, so this is defensive only).
  Future<bool> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await localAuth.signInWithEmail(
        email: email,
        password: password,
      );
      switch (result) {
        case LocalAuthFailure(:final message):
          logger.warn(
            'auth',
            'Sign-in failed',
            data: {'method': 'email'},
          );
          errorMessage = message;
          return false;
        case LocalAuthSuccess(:final session):
          final s = session;
          if (s == null) {
            errorMessage = 'Something went wrong. Please try again.';
            return false;
          }
          localSession = s;
          final memberId = s.memberId ??
              await localAuth.memberIdFor(s.uid);
          if (memberId == null) {
            errorMessage =
                'This account is not linked to a household member. '
                'Create a new account and pick your member.';
            return false;
          }
          await _applyLocalSession(s, memberId);
          logger.info('auth', 'Signed in', data: {'method': 'email'});
          return true;
      }
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Email/password sign-up against the local accounts in lock.json:
  /// creates the account (salted hash) and signs in immediately —
  /// there is no email verification, because there is no mail
  /// backend. Returns false with [errorMessage] set on failure.
  Future<bool> signUpWithEmail({
    required String displayName,
    required String email,
    required String password,
    required String memberId,
  }) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await localAuth.signUpWithEmail(
        email: email,
        password: password,
        displayName: displayName,
        memberId: memberId,
      );
      switch (result) {
        case LocalAuthFailure(:final message):
          logger.warn(
            'auth',
            'Sign-up failed',
            data: {'method': 'email'},
          );
          errorMessage = message;
          return false;
        case LocalAuthSuccess(:final session):
          final s = session;
          if (s == null) {
            errorMessage = 'Something went wrong. Please try again.';
            return false;
          }
          localSession = s;
          await _applyLocalSession(s, memberId);
          logger.info('auth', 'Signed up', data: {'method': 'email'});
          return true;
      }
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Demo login: signs in the demo user (ali/ayesha/bilal) from the
  /// seeded local accounts, then loads their lock.json household.
  /// Demo sessions are local — no network, no cloud account.
  Future<bool> loginWithDemo({required String memberId}) async {
    final demo = demoForMember(memberId);
    if (demo == null || isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await localAuth.signInDemo(demo);
      switch (result) {
        case LocalAuthFailure(:final message):
          logger.warn(
            'auth',
            'Demo sign-in failed',
            data: {'memberId': memberId},
          );
          errorMessage = message;
          return false;
        case LocalAuthSuccess(:final session):
          final s = session;
          if (s == null) {
            errorMessage = 'Something went wrong. Please try again.';
            return false;
          }
          localSession = s;
          await _applyLocalSession(s, memberId);
          logger.info(
            'auth',
            'Signed in',
            data: {'method': 'demo', 'memberId': memberId},
          );
          return true;
      }
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Starts a device-local password reset. Returns the reset code
  /// to SHOW ON THIS DEVICE (the forgot-password screen displays
  /// it — no email is sent), or null with [errorMessage] set when
  /// no account exists for that email.
  Future<String?> requestPasswordReset(String email) async {
    final code = await localAuth.requestPasswordReset(email: email);
    if (code == null) {
      errorMessage = 'No account exists for that email. '
          'Check the email or create an account.';
      notifyListeners();
      return null;
    }
    return code;
  }

  /// Completes a device-local password reset with the on-device
  /// code. On success the user is signed in with the new password
  /// and their household loads. Returns false with [errorMessage]
  /// set on a wrong/expired code or a bad new password.
  Future<bool> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final result = await localAuth.resetPasswordWithCode(
        email: email,
        code: code,
        newPassword: newPassword,
      );
      switch (result) {
        case LocalAuthFailure(:final message):
          errorMessage = message;
          return false;
        case LocalAuthSuccess(:final session):
          final s = session;
          if (s == null) {
            errorMessage = 'Something went wrong. Please try again.';
            return false;
          }
          localSession = s;
          final memberId = s.memberId ??
              await localAuth.memberIdFor(s.uid);
          if (memberId == null) {
            errorMessage =
                'This account is not linked to a household member. '
                'Create a new account and pick your member.';
            return false;
          }
          await _applyLocalSession(s, memberId);
          return true;
      }
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Logout: signs out of the local auth service, clears all local
  /// session state and the loaded household data, and returns to
  /// login. The sign-out is best-effort — a failure never blocks the
  /// local logout. Callers need not await it.
  Future<void> logout() async {
    try {
      await localAuth.signOut();
    } catch (_) {
      // Local logout continues regardless.
    }
    logger.info('auth', 'Signed out');
    _clearLocalSession();
    localSession = null;
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
    dataNotice = null;
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

  /// Verified payments (status `verified`), newest first.
  List<PaymentRecord> get verifiedPayments =>
      payments.where((p) => p.status == 'verified').toList();

  /// Rejected payments (status `rejected`), newest first. A
  /// rejected payment counts nowhere in any balance.
  List<PaymentRecord> get rejectedPayments =>
      payments.where((p) => p.status == 'rejected').toList();

  /// Per-member payment tracking (Phase 5): total owed / paid,
  /// verified vs pending settlements, settled remaining balance and
  /// status, monthly contribution, payment history — settled
  /// balances count `verified` payments only (see
  /// domain/payment_tracking.dart).
  List<MemberPaymentSummary> get paymentSummaries =>
      memberPaymentSummaries(
        expenses: recentExpenses,
        payments: payments,
        members: members,
      );

  /// Monthly breakdown for [month]: who paid, who did not pay, and
  /// how much each member contributed.
  List<MonthlyContribution> monthlyBreakdownFor(DateTime month) =>
      monthlyBreakdown(
        expenses: recentExpenses,
        payments: payments,
        members: members,
        month: month,
      );

  /// True when the signed-in user may verify or reject a recorded
  /// payment: group owner or admin only.
  bool get canVerifyPayments => canVerifyPayment(currentRole);

  /// True when the signed-in user may edit or delete [expense]:
  /// its payer/creator, or a group owner/admin.
  bool mayEditExpense(ExpenseRecord expense) => canEditExpense(
        isAdmin: canVerifyPayments,
        actorUid: currentUid,
        actorMemberId: loggedInMemberId,
        createdByUid: expense.createdByUid,
        payerMemberId: expense.payerId,
      );

  // NOTE: there is no free member switcher. The member is set at
  // login() and changed via logout + login again.

  /// Loads the signed-in user's household from the repository:
  /// resolves (or creates) the group, reads members, shopping,
  /// expenses, payments and fixed templates, and computes balances
  /// from that history. Before login this is a no-op — there is no
  /// household to load and no error to show. When the local store
  /// is unavailable (lock.json unreadable) [errorMessage] carries
  /// the plain local-unavailable text and every data list stays as
  /// it was — the app never shows fake data.
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
        email: localSession?.email,
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
          email: localSession?.email,
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
      // The store notice (web in-memory warning, corrupt-file
      // recovery, …) is surfaced once the household has loaded, so
      // main.dart can show it as a dismissible banner.
      if (_repository is LocalJsonRepository) {
        dataNotice = (_repository as LocalJsonRepository).storeNotice;
      }
      // Role + invitations load after the household data, and each
      // in its own try/catch: an invitation read must never break
      // the household load (e.g. a plain member may not list the
      // group's sent invitations, so the list is simply empty for
      // them).
      try {
        currentRole = await _repository.getMyRole(
          groupId: gid,
          uid: currentUid,
        );
      } catch (_) {
        currentRole = null;
      }
      await _loadInvitations();
    } on LocalDataException catch (e) {
      errorMessage = e.message;
      logger.error(
        'app_state',
        'Household refresh failed',
        data: {'error': e.message},
      );
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      logger.error('app_state', 'Household refresh failed');
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Runs a mutation with the submit lock held; refreshes the single
  /// store once on success so every screen rebuilds from fresh data.
  /// A local-store failure sets the plain error message and returns
  /// false; nothing is ever shown as succeeding when it did not.
  Future<bool> _runMutation(Future<dynamic> Function() fn) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await fn();
      await refresh();
      return true;
    } on LocalDataException catch (e) {
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
    if (gid == null) throw const LocalDataException(localDataUnavailableMessage);
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
    List<Map<String, String>>? percentageSplits,
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
          percentageSplits: percentageSplits,
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
          : splitType == 'percentage'
              ? (percentageSplits ?? [])
                  .map((s) => s['member_id']!)
                  .toList()
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

  /// Adds an expense with a receipt photo attached: creates the
  /// expense first (so the Storage path can use its id), uploads the
  /// photo to `receipts/{groupId}/{expenseId}/`, then attaches the
  /// URL/path to the expense. The expense is saved even when the
  /// upload fails — then [errorMessage] says the receipt could not
  /// be uploaded, so the failure is visible, never silent.
  Future<bool> addExpenseWithReceipt({
    required String title,
    required String category,
    required String date,
    required String amount,
    required String payerId,
    required String splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
    List<Map<String, String>>? percentageSplits,
    required XFile receiptImage,
  }) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final gid = _groupOrUnavailable;
      final record = await _repository.addExpense(
        groupId: gid,
        title: title,
        category: category,
        date: date,
        amount: amount,
        payerId: payerId,
        splitType: splitType,
        splits: splits,
        splitMembers: splitMembers,
        percentageSplits: percentageSplits,
        actorUid: currentUid,
      );
      var receiptAttached = false;
      try {
        final bytes = await receiptImage.readAsBytes();
        final uploaded = await _repository.uploadReceipt(
          groupId: gid,
          expenseId: record.id,
          bytes: bytes,
        );
        if (uploaded != null) {
          await _repository.updateExpense(
            groupId: gid,
            id: record.id,
            receiptUrl: uploaded.url,
            receiptPath: uploaded.path,
            actorUid: currentUid,
          );
          receiptAttached = true;
        }
      } catch (_) {
        receiptAttached = false;
      }
      await refresh();
      _logActivity(
        type: 'expense',
        title: 'Expense: $title',
        amount: amount,
        memberId: payerId,
        detail: category,
      );
      if (!receiptAttached) {
        errorMessage =
            'Expense saved, but the receipt photo could not be uploaded.';
        notifyListeners();
      }
      return true;
    } on LocalDataException catch (e) {
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

  /// Edits one expense (title, category, date, amount, payer and/or
  /// split). The repository recomputes the splits, so the
  /// integer-paisa invariant always holds after an edit. Only the
  /// payer/creator or an owner/admin may edit — the repository
  /// enforces it and a rejection surfaces as [errorMessage].
  Future<bool> updateExpense({
    required String id,
    String? title,
    String? category,
    String? date,
    String? amount,
    String? payerId,
    String? splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
    List<Map<String, String>>? percentageSplits,
  }) async {
    final ok = await _runMutation(() => _repository.updateExpense(
          groupId: _groupOrUnavailable,
          id: id,
          title: title,
          category: category,
          date: date,
          amount: amount,
          payerId: payerId,
          splitType: splitType,
          splits: splits,
          splitMembers: splitMembers,
          percentageSplits: percentageSplits,
          actorUid: currentUid,
        ));
    if (ok) {
      _logActivity(
        type: 'expense_edited',
        title: 'Expense edited: ${title ?? ''}',
        amount: amount ?? '0.00',
        memberId: payerId ?? loggedInMemberId ?? '',
        detail: category ?? '',
      );
    }
    return ok;
  }

  /// Deletes one expense (after the UI's confirmation dialog). Only
  /// the payer/creator or an owner/admin may delete.
  Future<bool> deleteExpense(ExpenseRecord expense) async {
    final ok = await _runMutation(() => _repository.deleteExpense(
          groupId: _groupOrUnavailable,
          id: expense.id,
          actorUid: currentUid,
        ));
    if (ok) {
      _logActivity(
        type: 'expense_deleted',
        title: 'Expense deleted: ${expense.title}',
        amount: expense.amount,
        memberId: expense.payerId,
        detail: expense.category,
      );
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
    } on LocalDataException catch (e) {
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
  /// owner/admin can do this — the repository enforces it and a
  /// rejection surfaces as the plain local message.
  /// Writes an activity entry on success.
  Future<bool> verifyPayment(String paymentId) async {
    final ok = await _runMutation(
      () => _repository.verifyPayment(
        groupId: _groupOrUnavailable,
        paymentId: paymentId,
        actorUid: currentUid,
      ),
    );
    if (ok) {
      final p =
          payments.where((v) => v.id == paymentId).firstOrNull;
      _logActivity(
        type: 'payment_verified',
        title: 'Payment verified',
        amount: p?.amount ?? '0.00',
        memberId: p?.senderId ?? '',
        detail: p == null
            ? ''
            : '${p.senderId} → ${p.recipientId}',
      );
    }
    return ok;
  }

  /// Rejects a recorded payment (recorded → rejected). Only an
  /// owner/admin can do this. A rejected payment counts nowhere in
  /// any balance; the sender records a new payment to correct it.
  /// Writes an activity entry on success.
  Future<bool> rejectPayment(String paymentId) async {
    final ok = await _runMutation(
      () => _repository.rejectPayment(
        groupId: _groupOrUnavailable,
        paymentId: paymentId,
        actorUid: currentUid,
      ),
    );
    if (ok) {
      final p =
          payments.where((v) => v.id == paymentId).firstOrNull;
      _logActivity(
        type: 'payment_rejected',
        title: 'Payment rejected',
        amount: p?.amount ?? '0.00',
        memberId: p?.senderId ?? '',
        detail: p == null
            ? ''
            : '${p.senderId} → ${p.recipientId}',
      );
    }
    return ok;
  }

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
    final email = localSession?.email;
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
        actorEmail: localSession?.email,
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
      logger.info('invitations', 'Invitation sent');
      return invite;
    } on LocalDataException catch (e) {
      errorMessage = e.message;
      logger.warn(
        'invitations',
        'Invitation failed',
        data: {'error': e.message},
      );
      return null;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      logger.warn('invitations', 'Invitation failed');
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
    } on LocalDataException catch (e) {
      errorMessage = e.message;
      logger.warn(
        'invitations',
        'Invitation revoke failed',
        data: {'error': e.message},
      );
      return false;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      logger.warn('invitations', 'Invitation revoke failed');
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
    final email = localSession?.email;
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
      logger.info('invitations', 'Invitation accepted');
      return accepted;
    } on LocalDataException catch (e) {
      errorMessage = e.message;
      logger.warn(
        'invitations',
        'Invitation accept failed',
        data: {'error': e.message},
      );
      return null;
    } catch (_) {
      errorMessage = 'Something went wrong. Please try again.';
      logger.warn('invitations', 'Invitation accept failed');
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
    } on LocalDataException catch (e) {
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

  /// Shows a message on the login page. The login screen's error
  /// banner displays it.
  void showError(String message) {
    errorMessage = message;
    notifyListeners();
  }

  // ---- AI chatbot (Phase 7) ----

  /// The household summary handed to the AI with every message:
  /// live totals, per-member balances, budget usage and recent
  /// expenses (see features/chatbot/data/chat_context.dart). The
  /// bot answers from this only and never invents figures.
  String householdSummaryForChat() => buildHouseholdContext(
        memberName: loggedInMember?.name ?? 'Member',
        balances: balances,
        recentExpenses: recentExpenses,
      );

  /// The persisted chat history for the signed-in user, oldest
  /// first. A failure returns an empty list — the chat still
  /// opens, it just starts fresh for this session.
  Future<List<ChatMessage>> loadChatHistory() async {
    try {
      return await _repository.getChatMessages(currentUid);
    } catch (e) {
      logger.error(
        'chatbot',
        'Chat history load failed',
        data: {'error': AppLogger.redact(e.toString())},
      );
      return [];
    }
  }

  /// Persists one chat message (user question or assistant reply)
  /// to the signed-in user's history in lock.json.
  Future<void> saveChatMessage(ChatMessage message) async {
    await _repository.addChatMessage(uid: currentUid, message: message);
  }

  /// Deletes the signed-in user's chat history from lock.json.
  Future<void> clearChatHistory() async {
    await _repository.clearChatMessages(currentUid);
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }
}
