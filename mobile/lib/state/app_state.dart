import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/repository.dart';
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
  AppState({SplitNestRepository? repository})
      : _repository = repository ?? SplitNestRepository();

  final SplitNestRepository _repository;

  /// Base URL of the backend, for display only (Home footer).
  String get apiBaseUrl => _repository.baseUrl;

  List<Member> members = [];
  List<ShoppingItem> shopping = [];
  Balances? balances;
  List<ExpenseRecord> recentExpenses = [];

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
      ]);
      members = results[0] as List<Member>;
      shopping = results[1] as List<ShoppingItem>;
      balances = results[2] as Balances;
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
  }) =>
      _runMutation(() => _repository.checkout(
            itemIds: itemIds,
            totalPaid: totalPaid,
            payerId: payerId,
            splitMembers: splitMembers,
          ));

  Future<bool> addExpense({
    required String title,
    required String category,
    required String date,
    required String amount,
    required String payerId,
    required String splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
  }) =>
      _runMutation(() => _repository.addExpense(
            title: title,
            category: category,
            date: date,
            amount: amount,
            payerId: payerId,
            splitType: splitType,
            splits: splits,
            splitMembers: splitMembers,
          ));

  Future<bool> settle({
    required String senderId,
    required String recipientId,
    required String amount,
  }) =>
      _runMutation(() => _repository.settle(
            senderId: senderId,
            recipientId: recipientId,
            amount: amount,
          ));

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }
}
