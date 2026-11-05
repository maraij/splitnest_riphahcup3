import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models.dart';

/// Base URL: pass `--dart-define=API_BASE_URL=http://<host>:3000` when
/// building/running, or it defaults to the Android emulator host loopback.
/// - Android emulator: `http://10.0.2.2:3000`
/// - Physical device / web: `http://<laptop LAN IP>:3000`
/// - Web on the same machine: `http://127.0.0.1:3000`
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:3000',
);

/// Thrown when the backend rejects a request or is unreachable.
class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? apiBaseUrl;

  final http.Client _client;
  final String baseUrl;

  /// Session token from POST /api/auth/login. In-memory only (this is a
  /// practice build). Every call except login sends it as a Bearer token;
  /// logout clears it.
  String? _token;
  String? get token => _token;
  void setToken(String? token) => _token = token;
  void clearToken() => _token = null;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Future<dynamic> _call(
    String method,
    String path,
    Map<String, dynamic>? body, {
    bool isLogin = false,
    // Message for a 401 on a login call. Login calls report their own
    // friendly text instead of the generic session-expired one.
    String? unauthorizedMessage,
  }) async {
    late http.Response res;
    try {
      final uri = Uri.parse('$baseUrl$path');
      if (method == 'GET') {
        res = await _client
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 10));
      } else if (method == 'PATCH') {
        res = await _client
            .patch(uri, headers: _headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 10));
      } else if (method == 'DELETE') {
        res = await _client
            .delete(uri, headers: _headers)
            .timeout(const Duration(seconds: 10));
      } else {
        res = await _client
            .post(uri, headers: _headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 10));
      }
    } on TimeoutException {
      throw ApiException('Request timed out. Is the backend running at $baseUrl?');
    } catch (e) {
      throw ApiException('Could not reach the backend at $baseUrl. ($e)');
    }
    dynamic data;
    try {
      data = jsonDecode(res.body);
    } catch (_) {
      data = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    if (res.statusCode == 401) {
      // A 401 on login means wrong credentials; anywhere else it means
      // the session is gone — the user must log in again.
      throw ApiException(isLogin
          ? (unauthorizedMessage ?? 'Wrong password, try again')
          : 'Session expired. Log in again.');
    }
    final msg = data is Map && data['error'] is Map
        ? (data['error']['message'] as String? ?? 'Request failed.')
        : 'Request failed (${res.statusCode}).';
    throw ApiException(msg);
  }

  /// POST /api/auth/login — returns the session token and the member.
  /// On a 401 the message is the friendly wrong-password text.
  Future<({String token, Member member})> login({
    required String memberId,
    required String password,
  }) async {
    final data = await _call(
      'POST',
      '/api/auth/login',
      {'member_id': memberId, 'password': password},
      isLogin: true,
    );
    final map = data as Map<String, dynamic>;
    final token = map['token'] as String;
    _token = token;
    return (
      token: token,
      member: Member.fromJson(map['member'] as Map<String, dynamic>),
    );
  }

  /// POST /api/auth/google — exchanges a verified Google ID token for
  /// the same session token as the password login. The backend
  /// verifies the token against Google before issuing anything, so a
  /// 401 here means the Google token was rejected.
  Future<({String token, Member member})> loginWithGoogle({
    required String idToken,
    required String memberId,
  }) async {
    final data = await _call(
      'POST',
      '/api/auth/google',
      {'idToken': idToken, 'memberId': memberId},
      isLogin: true,
      unauthorizedMessage: 'Google sign-in could not be verified. '
          'Please try again or use member login.',
    );
    final map = data as Map<String, dynamic>;
    final token = map['token'] as String;
    _token = token;
    return (
      token: token,
      member: Member.fromJson(map['member'] as Map<String, dynamic>),
    );
  }

  Future<List<Member>> getMembers() async {
    final data = await _call('GET', '/api/members', null);
    return (data as List).map((e) => Member.fromJson(e)).toList();
  }

  Future<List<ShoppingItem>> getShopping() async {
    final data = await _call('GET', '/api/shopping', null);
    return (data as List).map((e) => ShoppingItem.fromJson(e)).toList();
  }

  Future<ShoppingItem> addShopping(
      {required String title, required String unit, required int qty}) async {
    final data = await _call('POST', '/api/shopping', {
      'title': title,
      'unit': unit,
      'requested_qty': qty,
    });
    return ShoppingItem.fromJson(data as Map<String, dynamic>);
  }

  Future<ExpenseRecord> checkout({
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
  }) async {
    final data = await _call('POST', '/api/shopping/checkout', {
      'item_ids': itemIds,
      'total_paid': totalPaid,
      'payer_id': payerId,
      'split_members': splitMembers,
    });
    return ExpenseRecord.fromJson(data as Map<String, dynamic>);
  }

  Future<ExpenseRecord> addExpense({
    required String title,
    required String category,
    required String date,
    required String amount,
    required String payerId,
    required String splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
  }) async {
    final data = await _call('POST', '/api/expenses', {
      'title': title,
      'category': category,
      'date': date,
      'amount': amount,
      'payer_id': payerId,
      'split_type': splitType,
      ...?splits == null ? null : {'splits': splits},
      ...?splitMembers == null ? null : {'split_members': splitMembers},
    });
    return ExpenseRecord.fromJson(data as Map<String, dynamic>);
  }

  Future<Balances> getBalances() async {
    final data = await _call('GET', '/api/balances', null);
    return Balances.fromJson(data as Map<String, dynamic>);
  }

  Future<void> settle({
    required String senderId,
    required String recipientId,
    required String amount,
  }) async {
    await _call('POST', '/api/settle', {
      'sender_id': senderId,
      'recipient_id': recipientId,
      'amount': amount,
    });
  }
  // ---- Fixed monthly expenses (templates) ----
  Future<List<FixedExpense>> getFixedExpenses() async {
    final data = await _call('GET', '/api/fixed-expenses', null);
    final list = (data as Map<String, dynamic>)['fixed_expenses'] as List;
    return list
        .map((e) => FixedExpense.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<FixedExpense> createFixedExpense({
    required String title,
    required String category,
    required String amount,
    required String payerId,
    List<String>? splitMemberIds,
  }) async {
    final data = await _call('POST', '/api/fixed-expenses', {
      'title': title,
      'category': category,
      'amount': amount,
      'payer_id': payerId,
      ...?splitMemberIds == null ? null : {'split_members': splitMemberIds},
    });
    return FixedExpense.fromJson(data as Map<String, dynamic>);
  }

  Future<FixedExpense> updateFixedExpense({
    required String id,
    String? title,
    String? category,
    String? amount,
    String? payerId,
    List<String>? splitMemberIds,
  }) async {
    final data = await _call('PATCH', '/api/fixed-expenses/$id', {
      ...?title == null ? null : {'title': title},
      ...?category == null ? null : {'category': category},
      ...?amount == null ? null : {'amount': amount},
      ...?payerId == null ? null : {'payer_id': payerId},
      ...?splitMemberIds == null ? null : {'split_members': splitMemberIds},
    });
    return FixedExpense.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteFixedExpense(String id) async {
    await _call('DELETE', '/api/fixed-expenses/$id', null);
  }

  /// Applies one template for the current month. Returns whether an
  /// expense was actually posted (false = already applied this month).
  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense(
      String id) async {
    final data =
        await _call('POST', '/api/fixed-expenses/$id/apply', {});
    final map = data as Map<String, dynamic>;
    final applied = map['applied'] as bool;
    final expenseJson = map['expense'] as Map<String, dynamic>?;
    return (
      applied: applied,
      expense: expenseJson == null
          ? null
          : ExpenseRecord.fromJson(expenseJson),
    );
  }

}
