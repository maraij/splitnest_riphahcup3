import 'api_client.dart';
import '../domain/models.dart';

/// Repository — the ONLY place that talks to the backend.
/// The single store ([AppState]) talks to this repository, never to
/// HTTP directly. All seven endpoints, nothing else.
class SplitNestRepository {
  SplitNestRepository({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  String get baseUrl => _api.baseUrl;

  /// POST /api/auth/login — returns the session token and the member.
  Future<({String token, Member member})> login({
    required String memberId,
    required String password,
  }) =>
      _api.login(memberId: memberId, password: password);

  /// POST /api/auth/google — the same session as the password login,
  /// for a Google ID token the backend has verified.
  Future<({String token, Member member})> loginWithGoogle({
    required String idToken,
    required String memberId,
  }) =>
      _api.loginWithGoogle(idToken: idToken, memberId: memberId);

  /// Clears the session token (logout). After this, no endpoint call
  /// may succeed until login runs again.
  void clearToken() => _api.clearToken();

  Future<List<Member>> getMembers() => _api.getMembers();

  Future<List<ShoppingItem>> getShopping() => _api.getShopping();

  Future<Balances> getBalances() => _api.getBalances();

  Future<ShoppingItem> addShopping({
    required String title,
    required String unit,
    required int qty,
  }) =>
      _api.addShopping(title: title, unit: unit, qty: qty);

  Future<ExpenseRecord> checkout({
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
  }) =>
      _api.checkout(
        itemIds: itemIds,
        totalPaid: totalPaid,
        payerId: payerId,
        splitMembers: splitMembers,
      );

  Future<ExpenseRecord> addExpense({
    required String title,
    required String category,
    required String date,
    required String amount,
    required String payerId,
    required String splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
  }) =>
      _api.addExpense(
        title: title,
        category: category,
        date: date,
        amount: amount,
        payerId: payerId,
        splitType: splitType,
        splits: splits,
        splitMembers: splitMembers,
      );

  Future<void> settle({
    required String senderId,
    required String recipientId,
    required String amount,
  }) =>
      _api.settle(
        senderId: senderId,
        recipientId: recipientId,
        amount: amount,
      );

  Future<List<FixedExpense>> getFixedExpenses() =>
      _api.getFixedExpenses();

  Future<FixedExpense> createFixedExpense({
    required String title,
    required String category,
    required String amount,
    required String payerId,
    List<String>? splitMemberIds,
  }) =>
      _api.createFixedExpense(
        title: title,
        category: category,
        amount: amount,
        payerId: payerId,
        splitMemberIds: splitMemberIds,
      );

  Future<FixedExpense> updateFixedExpense({
    required String id,
    String? title,
    String? category,
    String? amount,
    String? payerId,
    List<String>? splitMemberIds,
  }) =>
      _api.updateFixedExpense(
        id: id,
        title: title,
        category: category,
        amount: amount,
        payerId: payerId,
        splitMemberIds: splitMemberIds,
      );

  Future<void> deleteFixedExpense(String id) =>
      _api.deleteFixedExpense(id);

  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense(
          String id) =>
      _api.applyFixedExpense(id);
}
