import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api_client.dart';
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
  AppState({SplitNestRepository? repository, bool? initialDarkMode})
      : _repository = repository ?? SplitNestRepository() {
    _isDarkMode = initialDarkMode ?? false;
    // When the caller did not preload the saved theme (tests), load
    // it here; main() preloads it before first paint instead.
    if (initialDarkMode == null) _loadThemeMode();
    _loadCaps();
    _loadProfileImages();
  }

  final SplitNestRepository _repository;

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

  /// Logout: clears the token (no endpoint call may succeed after
  /// this), the logged-in member and the welcome state; returns to login.
  void logout() {
    _repository.clearToken();
    sessionToken = null;
    loggedInMemberId = null;
    _welcomeShownForMemberId = null;
    _welcomeDialogPending = false;
    _celebrationShownForMemberId = null;
    _celebrationDialogPending = false;
    activityLog = [];
    errorMessage = null;
    notifyListeners();
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

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }
}
