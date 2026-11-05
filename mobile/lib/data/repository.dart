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
}
