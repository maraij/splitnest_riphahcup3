import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/data/api_client.dart';
import 'package:splitnest/data/google_auth_service.dart';
import 'package:splitnest/core/money.dart';
import 'package:splitnest/data/repository.dart';
import 'package:splitnest/domain/models.dart';
import 'package:splitnest/main.dart';
import 'package:splitnest/state/app_state.dart';

// A fake API that returns the seeded household, so widget tests never
// touch a real backend.
class FakeApi extends ApiClient {
  FakeApi() : super(baseUrl: 'http://fake');
  @override
  Future<List<Member>> getMembers() async => [
        Member(id: 'M01', name: 'Ali'),
        Member(id: 'M02', name: 'Ayesha'),
        Member(id: 'M03', name: 'Bilal'),
      ];
  @override
  Future<List<ShoppingItem>> getShopping() async => List.of(_shopping);

  /// Stateful shopping list, so add/checkout tests see real changes.
  final List<ShoppingItem> _shopping = [
    ShoppingItem(id: 'S01', title: 'Milk', unit: 'bottle', requestedQty: 2, status: 'Pending'),
    ShoppingItem(id: 'S02', title: 'Rice', unit: 'pack', requestedQty: 1, status: 'Pending'),
  ];
  int _shoppingSeq = 2;

  @override
  Future<ShoppingItem> addShopping({
    required String title,
    required String unit,
    required int qty,
  }) async {
    final item = ShoppingItem(
      id: 'S-fake-${++_shoppingSeq}',
      title: title,
      unit: unit,
      requestedQty: qty,
      status: 'Pending',
    );
    _shopping.add(item);
    return item;
  }

  @override
  Future<ExpenseRecord> checkout({
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
  }) async {
    for (var i = 0; i < _shopping.length; i++) {
      if (itemIds.contains(_shopping[i].id)) {
        final old = _shopping[i];
        _shopping[i] = ShoppingItem(
          id: old.id,
          title: old.title,
          unit: old.unit,
          requestedQty: old.requestedQty,
          status: 'Bought',
        );
      }
    }
    final shares = equalSplit(parsePaisa(totalPaid) ?? 0, splitMembers)
        .map((s) => ExpenseShare(
            memberId: s.memberId, amount: formatPaisa(s.amountPaisa)))
        .toList();
    final now = DateTime.now();
    return ExpenseRecord(
      id: 'E-checkout-${++_expenseSeq}',
      title: 'Shopping checkout',
      category: 'Groceries',
      amount: totalPaid,
      payerId: payerId,
      date:
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      splitType: 'equal',
      shares: shares,
    );
  }

  @override
  Future<void> settle({
    required String senderId,
    required String recipientId,
    required String amount,
  }) async {
    // Fake: accepts the settlement (balances stay benchmark — the
    // widget tests assert the log entry and the snackbar, not a
    // recomputed balance; the backend tests cover the maths).
  }

  /// Stateful fixed templates, seeded like the backend (Internet
  /// 1500 Bilal, Electricity 1020 Ali, both equal among all three).
  final List<FixedExpense> _fixed = [
    FixedExpense(
      id: 'F01',
      title: 'Internet',
      category: 'Utilities',
      amount: '1500.00',
      payerId: 'M03',
      splitMemberIds: ['M01', 'M02', 'M03'],
    ),
    FixedExpense(
      id: 'F02',
      title: 'Electricity',
      category: 'Utilities',
      amount: '1020.00',
      payerId: 'M01',
      splitMemberIds: ['M01', 'M02', 'M03'],
    ),
  ];
  int _fixedSeq = 2;
  final Set<String> _appliedFixed = {};

  @override
  Future<List<FixedExpense>> getFixedExpenses() async => List.of(_fixed);

  @override
  Future<FixedExpense> createFixedExpense({
    required String title,
    required String category,
    required String amount,
    required String payerId,
    List<String>? splitMemberIds,
  }) async {
    final f = FixedExpense(
      id: 'F-fake-${++_fixedSeq}',
      title: title,
      category: category,
      amount: amount,
      payerId: payerId,
      splitMemberIds: splitMemberIds ?? ['M01', 'M02', 'M03'],
    );
    _fixed.add(f);
    return f;
  }

  @override
  Future<FixedExpense> updateFixedExpense({
    required String id,
    String? title,
    String? category,
    String? amount,
    String? payerId,
    List<String>? splitMemberIds,
  }) async {
    final i = _fixed.indexWhere((f) => f.id == id);
    if (i < 0) throw ApiException('Fixed expense not found.');
    final old = _fixed[i];
    final updated = FixedExpense(
      id: old.id,
      title: title ?? old.title,
      category: category ?? old.category,
      amount: amount ?? old.amount,
      payerId: payerId ?? old.payerId,
      splitMemberIds: splitMemberIds ?? old.splitMemberIds,
    );
    _fixed[i] = updated;
    return updated;
  }

  @override
  Future<void> deleteFixedExpense(String id) async {
    _fixed.removeWhere((f) => f.id == id);
  }

  @override
  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense(
      String id) async {
    final now = DateTime.now();
    final key =
        '$id|${now.year}-${now.month.toString().padLeft(2, '0')}';
    if (_appliedFixed.contains(key)) {
      return (applied: false, expense: null);
    }
    FixedExpense? found;
    for (final f in _fixed) {
      if (f.id == id) found = f;
    }
    if (found == null) throw ApiException('Fixed expense not found.');
    _appliedFixed.add(key);
    final shares = equalSplit(parsePaisa(found.amount) ?? 0, found.splitMemberIds)
        .map((s) => ExpenseShare(
            memberId: s.memberId, amount: formatPaisa(s.amountPaisa)))
        .toList();
    final expense = ExpenseRecord(
      id: 'E-fixed-${++_expenseSeq}',
      title: found.title,
      category: found.category,
      amount: found.amount,
      payerId: found.payerId,
      date:
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      splitType: 'equal',
      shares: shares,
    );
    return (applied: true, expense: expense);
  }
  static const _demoPasswords = {
    'M01': 'ali123',
    'M02': 'ayesha123',
    'M03': 'bilal123',
  };

  /// Fake login: checks the demo passwords like the real backend.
  @override
  Future<({String token, Member member})> login({
    required String memberId,
    required String password,
  }) async {
    final members = await getMembers();
    Member? member;
    for (final m in members) {
      if (m.id == memberId) member = m;
    }
    if (member == null || _demoPasswords[memberId] != password) {
      throw ApiException('Wrong password, try again');
    }
    final token = 'fake-token-$memberId';
    setToken(token);
    return (token: token, member: member);
  }

  /// Fake Google login: the token is already verified (that is the
  /// backend's job, tested in test/api.test.js) — here it just issues
  /// the same session shape for the picked member.
  @override
  Future<({String token, Member member})> loginWithGoogle({
    required String idToken,
    required String memberId,
  }) async {
    final members = await getMembers();
    Member? member;
    for (final m in members) {
      if (m.id == memberId) member = m;
    }
    if (member == null) {
      throw ApiException('Member $memberId does not exist.');
    }
    const token = 'fake-google-token';
    setToken(token);
    return (token: token, member: member);
  }

  int _expenseSeq = 0;

  /// Fake add-expense: echoes the inputs back as a recorded expense,
  /// with shares exactly as the real backend computes them.
  @override
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
    final shares = splits != null
        ? splits
            .map((s) => ExpenseShare(
                memberId: s['member_id']!, amount: s['amount']!))
            .toList()
        : splitMembers != null
            ? equalSplit(parsePaisa(amount) ?? 0, splitMembers)
                .map((s) => ExpenseShare(
                    memberId: s.memberId,
                    amount: formatPaisa(s.amountPaisa)))
                .toList()
            : const <ExpenseShare>[];
    return ExpenseRecord(
      id: 'E-fake-${++_expenseSeq}',
      title: title,
      category: category,
      amount: amount,
      payerId: payerId,
      date: date,
      splitType: splitType,
      shares: shares,
    );
  }

  @override
  Future<Balances> getBalances() async => Balances(
        rows: [
          BalanceRow(memberId: 'M01', name: 'Ali', net: '250.00', paid: '1800.00', share: '1550.00'),
          BalanceRow(memberId: 'M02', name: 'Ayesha', net: '-450.00', paid: '900.00', share: '1350.00'),
          BalanceRow(memberId: 'M03', name: 'Bilal', net: '200.00', paid: '1500.00', share: '1300.00'),
        ],
        totalSpending: '4200.00',
        budget: '5000.00',
        remaining: '800.00',
        usedPercent: 84,
        status: 'Near Limit',
      );
}

/// Test repository wrapping the fake API, so AppState talks to the
/// repository (as in production) rather than to HTTP directly.
class FakeRepository extends SplitNestRepository {
  FakeRepository({ApiClient? api}) : super(api: api ?? FakeApi());
}

/// Fake Google sign-in returning a scripted result, so the login
/// screen's Google flow can be tested without a device or Google.
class FakeGoogleAuthService implements GoogleAuthService {
  FakeGoogleAuthService(this.result);
  final GoogleSignInResult result;
  bool signOutCalled = false;
  @override
  Future<GoogleSignInResult> signIn() async => result;
  @override
  Future<void> signOut() async {
    signOutCalled = true;
  }
}

/// API that always fails, for the network-error test.
class ThrowingApi extends ApiClient {
  ThrowingApi() : super(baseUrl: 'http://fake');
  @override
  Future<List<Member>> getMembers() async =>
      throw ApiException('Could not reach the backend.');
}

Future<void> pumpApp(WidgetTester tester,
    {SplitNestRepository? repository, GoogleAuthService? googleAuth}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AppState(
        repository: repository ?? FakeRepository(),
        googleAuth: googleAuth,
      )..refresh(),
      child: const SplitNestApp(),
    ),
  );
  // pumpAndSettle advances the fake clock past the ~1.8s splash.
  await tester.pumpAndSettle();
}

/// Demo passwords used by the widget tests (same as the backend seeds).
const _testPasswords = {
  'Ali': 'ali123',
  'Ayesha': 'ayesha123',
  'Bilal': 'bilal123',
};

/// Pumps the app, waits out the splash, and logs in with the member's
/// demo password. Dismisses the once-per-login welcome popup (and the
/// savings celebration that follows it on the benchmark balances).
Future<void> loginAs(WidgetTester tester, String name,
    {SplitNestRepository? repository}) async {
  await pumpApp(tester, repository: repository);
  await loginOnCurrentPage(tester, name);
}

/// Logs in on the currently shown login page (also used after logout).
/// Selects the member card, enters the demo password, taps Log in.
/// Dismisses the welcome popup unless [dismissWelcome] is false.
Future<void> loginOnCurrentPage(
  WidgetTester tester,
  String name, {
  bool dismissWelcome = true,
}) async {
  expect(find.text('Log in'), findsOneWidget);
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Password'),
    _testPasswords[name]!,
  );
  await tester.ensureVisible(find.text('Log in'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Log in'));
  await tester.pumpAndSettle();
  if (dismissWelcome && find.text('Got it').evaluate().isNotEmpty) {
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    // The savings celebration follows the welcome popup once per
    // login (every member saves on the benchmark balances). Dismiss
    // it too, or it blocks later taps behind its modal barrier.
    if (find.text('Dismiss').evaluate().isNotEmpty) {
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
    }
  }
}

/// Adds an expense through the real Add New Expense sheet UI.
/// [payer] changes the sheet's payer dropdown; otherwise the payer
/// defaults to the logged-in member. [repeatMonthly] turns on the
/// "Repeat monthly" switch so the expense also becomes a fixed template.
Future<void> _addExpenseViaSheet(
  WidgetTester tester, {
  required String title,
  required String amount,
  required String category,
  String? payer,
  bool repeatMonthly = false,
}) async {
  await tester.tap(find.text('Add New Expense'));
  await tester.pumpAndSettle();
  await tester.enterText(
      find.widgetWithText(TextField, 'Title (e.g. Internet Bill)'), title);
  await tester.enterText(
      find.widgetWithText(TextField, 'Amount (PKR)'), amount);
  await tester.tap(find.widgetWithText(ChoiceChip, category));
  await tester.pumpAndSettle();
  if (payer != null) {
    // The payer dropdown sits below the fold inside the sheet —
    // scroll it into view first. (Focus is already off the text
    // fields after the chip tap above, so no caret scroll-back.)
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(payer).last);
    await tester.pumpAndSettle();
  }
  if (repeatMonthly) {
    await tester
        .ensureVisible(find.widgetWithText(SwitchListTile, 'Repeat monthly'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Repeat monthly'));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.text('Add expense'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Add expense'));
  await tester.pumpAndSettle();
}

/// Opens the navigation drawer from the AppBar hamburger.
/// (byIcon, not byTooltip: the Scaffold's drawer button carries no
/// Tooltip widget in this Flutter version.)
Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
}

/// Fake balances where the house already spent the whole budget, so
/// nobody saved anything and the celebration must NOT appear.
class OverBudgetApi extends FakeApi {
  @override
  Future<Balances> getBalances() async => Balances(
        rows: [
          BalanceRow(memberId: 'M01', name: 'Ali', net: '0.00', paid: '2000.00', share: '2000.00'),
          BalanceRow(memberId: 'M02', name: 'Ayesha', net: '0.00', paid: '1500.00', share: '1500.00'),
          BalanceRow(memberId: 'M03', name: 'Bilal', net: '0.00', paid: '1500.00', share: '1500.00'),
        ],
        totalSpending: '5000.00',
        budget: '5000.00',
        remaining: '0.00',
        usedPercent: 100,
        status: 'Over Budget',
      );
}

/// Fake image picker returning fixed bytes (a 1x1 PNG), so the
/// "Change photo" flow can be tested without a device gallery.
class _FakePicker extends ImagePickerPlatform {
  _FakePicker(this.bytes);
  final Uint8List bytes;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    return XFile.fromData(bytes, name: 'photo.png', mimeType: 'image/png');
  }
}

/// 1x1 transparent PNG, for the profile-photo test.
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('splash shows the logo, then advances to login',
      (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(repository: FakeRepository())..refresh(),
        child: const SplitNestApp(),
      ),
    );
    await tester.pump();
    expect(find.text('Shared living, settled simply.'), findsOneWidget);
    expect(find.text('Log in'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Demo'), findsOneWidget);
  });

  testWidgets('login as Ali shows home with budget and active balance',
      (tester) async {
    await loginAs(tester, 'Ali');
    expect(find.text('Logged in as'), findsOneWidget);
    expect(find.textContaining('4200.00'), findsWidgets);
    expect(find.text('84.0%'), findsOneWidget);
    // Balance + pending cards sit below the fold: drag down to build
    // them. (ListView discards off-screen children, so check the
    // top-of-screen items before scrolling.)
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.textContaining('You are owed PKR 250.00'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('2 pending shopping item'), 300);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 pending shopping item'), findsOneWidget);
    expect(find.text('Milk (bottle × 2)'), findsOneWidget);
  });

  testWidgets('login as Ayesha shows her balance', (tester) async {
    await loginAs(tester, 'Ayesha');
    expect(find.text('Logged in as'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('You owe PKR 450.00'), 200);
    await tester.pumpAndSettle();
    expect(find.textContaining('You owe PKR 450.00'), findsOneWidget);
  });

  testWidgets('logout returns to the login page', (tester) async {
    await loginAs(tester, 'Ali');
    expect(find.text('Logged in as'), findsOneWidget);
    await tester.tap(find.byTooltip('Log out'));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Demo'), findsOneWidget);
    expect(find.textContaining('You are owed PKR 250.00'), findsNothing);
  });

  testWidgets('four tabs are present', (tester) async {
    await loginAs(tester, 'Ali');
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Shopping'), findsOneWidget);
    expect(find.text('Expenses'), findsOneWidget);
    expect(find.text('Settle Up'), findsOneWidget);
  });

  testWidgets('shopping tab shows pending items and history',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    expect(find.text('Current List (2)'), findsOneWidget);
    expect(find.text('Milk (bottle × 2)'), findsOneWidget);
    expect(find.text('Rice (pack × 1)'), findsOneWidget);
    expect(find.text('Pending'), findsNWidgets(2));
    await tester.tap(find.text('History (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing bought yet'), findsOneWidget);
  });

  testWidgets('expenses tab shows add button and recent expenses',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    expect(find.text('Add New Expense'), findsOneWidget);
    expect(find.text('No expenses added yet in this session'),
        findsOneWidget);
  });

  testWidgets('add expense sheet shows categories and live preview',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Expense'));
    await tester.pumpAndSettle();
    expect(find.text('Add New Expense'), findsWidgets);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Utilities'), findsOneWidget);
    expect(find.text('Split Strategy'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Title (e.g. Internet Bill)'),
        'Internet Bill');
    await tester.enterText(
        find.widgetWithText(TextField, 'Amount (PKR)'), '1500.00');
    await tester.pumpAndSettle();
    expect(find.textContaining('Ali pays PKR 500.00'), findsOneWidget);
    expect(find.textContaining('Ayesha pays PKR 500.00'), findsOneWidget);
    expect(find.textContaining('Bilal pays PKR 500.00'), findsOneWidget);
  });

  testWidgets('settle tab shows balances and smart settle plan',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Settle Up'));
    await tester.pumpAndSettle();
    expect(find.text('Settle Debt'), findsOneWidget);
    expect(find.textContaining('PKR 250.00'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Smart Settle'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Ayesha pays Ali PKR 250.00'), findsOneWidget);
    expect(find.text('Ayesha pays Bilal PKR 200.00'), findsOneWidget);
  });

  testWidgets('settle dialog suggests debtor to creditor payments',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Settle Up'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Settle Debt'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settle Debt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ayesha → Ali · up to PKR 250.00'),
        findsOneWidget);
    expect(find.textContaining('Ayesha → Bilal · up to PKR 200.00'),
        findsOneWidget);
  });

  testWidgets('shopping checkout opens a bottom sheet with split preview',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Milk (bottle × 2)'));
    await tester.pumpAndSettle();
    expect(find.text('Checkout · 1 selected'), findsOneWidget);
    await tester.tap(find.text('Checkout · 1 selected'));
    await tester.pumpAndSettle();
    expect(find.text('Checkout'), findsWidgets);
    expect(find.text('Split between'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Total paid (PKR)'), '780.00');
    await tester.pumpAndSettle();
    expect(find.textContaining('Ali pays PKR 260.00'), findsOneWidget);
    expect(find.textContaining('Ayesha pays PKR 260.00'), findsOneWidget);
    expect(find.textContaining('Bilal pays PKR 260.00'), findsOneWidget);
  });

  testWidgets('member switching updates Home in the same session',
      (tester) async {
    await loginAs(tester, 'Bilal');
    await tester.scrollUntilVisible(
        find.textContaining('You are owed PKR 200.00'), 200);
    await tester.pumpAndSettle();
    expect(find.textContaining('You are owed PKR 200.00'), findsOneWidget);
    // Log out and log in as a different member: every screen must
    // immediately reflect the new member, with no stale balance.
    await tester.tap(find.byTooltip('Log out'));
    await tester.pumpAndSettle();
    await loginOnCurrentPage(tester, 'Ayesha');
    await tester.scrollUntilVisible(
        find.textContaining('You owe PKR 450.00'), 200);
    await tester.pumpAndSettle();
    expect(find.textContaining('You owe PKR 450.00'), findsOneWidget);
  });

  testWidgets('add expense sheet defaults payer to the logged-in member',
      (tester) async {
    await loginAs(tester, 'Bilal');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Expense'));
    await tester.pumpAndSettle();
    // The payer dropdown shows the logged-in member (Bilal). 'Bilal'
    // also appears on the Equal split's member picker chip, so target
    // the dropdown specifically rather than any 'Bilal' text.
    expect(
        find.widgetWithText(DropdownButtonFormField<String>, 'Bilal'),
        findsOneWidget);
  });

  testWidgets('login shows error with retry when backend is down',
      (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) =>
            AppState(repository: FakeRepository(api: ThrowingApi()))
              ..refresh(),
        child: const SplitNestApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not reach the backend.'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not reach the backend.'),
        findsOneWidget);
  });

  testWidgets('phone-size layout has no overflow on any tab',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loginAs(tester, 'Ali');
    for (final tab in ['Shopping', 'Expenses', 'Settle Up', 'Home']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Expense'));
    await tester.pumpAndSettle();
    expect(find.text('Add New Expense'), findsWidgets);
  });


  testWidgets('wrong password shows an error and stays on login',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Ayesha'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'not-the-password');
    await tester.ensureVisible(find.text('Log in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password, try again'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Monthly Budget'), findsNothing);
  });

  testWidgets(
      'welcome popup shows once per login with the right member and balance',
      (tester) async {
    await pumpApp(tester);
    await loginOnCurrentPage(tester, 'Ayesha', dismissWelcome: false);
    expect(find.text('You are using SplitNest as Ayesha (M02)'),
        findsOneWidget);
    expect(find.text('You owe PKR 450.00'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('You are using SplitNest as Ayesha (M02)'),
        findsNothing);
    // The savings celebration follows the welcome popup (Ayesha
    // saved PKR 316.67 on the benchmark) — dismiss it before
    // switching tabs, or the modal blocks the taps.
    expect(find.text('Great job, Ayesha!'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    // Tab switch + back: neither popup reappears in this session.
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('You are using SplitNest as Ayesha (M02)'),
        findsNothing);
    expect(find.text('Great job, Ayesha!'), findsNothing);
    // Log out and log in as a different member: popup again, new member.
    await tester.tap(find.byTooltip('Log out'));
    await tester.pumpAndSettle();
    await loginOnCurrentPage(tester, 'Bilal', dismissWelcome: false);
    expect(find.text('You are using SplitNest as Bilal (M03)'),
        findsOneWidget);
    expect(find.text('You are owed PKR 200.00'), findsOneWidget);
  });

  testWidgets('demo accounts log in with one tap for all three members',
      (tester) async {
    const cases = [
      ('Ali', 'M01', 'You are owed PKR 250.00'),
      ('Ayesha', 'M02', 'You owe PKR 450.00'),
      ('Bilal', 'M03', 'You are owed PKR 200.00'),
    ];
    for (final (name, id, balance) in cases) {
      await pumpApp(tester);
      await tester.ensureVisible(find.text('Demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('$name • $id'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$name • $id'));
      await tester.pumpAndSettle();
      // The welcome popup proves the login went through real auth.
      expect(find.text('You are using SplitNest as $name ($id)'),
          findsOneWidget);
      expect(find.text(balance), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text('Logged in as'), findsOneWidget);
      // Celebration follows the welcome popup for every member on
      // the benchmark balances — dismiss it before logging out.
      if (find.text('Dismiss').evaluate().isNotEmpty) {
        await tester.tap(find.text('Dismiss'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Log out'));
      await tester.pumpAndSettle();
    }
  });


  testWidgets('demo button opens a popup with all three demo accounts',
      (tester) async {
    await pumpApp(tester);
    // Exactly one Demo button on the login page; the accounts live
    // only inside the popup, not on the page itself.
    expect(find.text('Demo'), findsOneWidget);
    expect(find.text('Demo accounts'), findsNothing);
    expect(find.text('Ali • M01'), findsNothing);
    await tester.ensureVisible(find.text('Demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();
    expect(find.text('Demo accounts'), findsOneWidget);
    expect(find.text('Ali • M01'), findsOneWidget);
    expect(find.text('Ayesha • M02'), findsOneWidget);
    expect(find.text('Bilal • M03'), findsOneWidget);
    // Close without logging in: back on the login page.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Demo accounts'), findsNothing);
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets(
      'Continue with Google sits below the accounts and signs in',
      (tester) async {
    await pumpApp(tester,
        googleAuth: FakeGoogleAuthService(const GoogleSignedIn(
          idToken: 'fake-id-token',
          email: 'test.user@gmail.com',
        )));
    // One Google button, below the member accounts (not above them).
    expect(find.text('Continue with Google'), findsOneWidget);
    final googleY =
        tester.getCenter(find.text('Continue with Google')).dy;
    for (final name in ['Ali', 'Ayesha', 'Bilal']) {
      expect(tester.getCenter(find.text(name)).dy, lessThan(googleY));
    }
    // Tapping it runs the Google flow, then asks which member this
    // Google account is — no password, no fake session.
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(find.text('Choose your account'), findsOneWidget);
    expect(find.textContaining('test.user@gmail.com'), findsOneWidget);
    await tester.tap(find.text('Ali • M01'));
    await tester.pumpAndSettle();
    // Logged in as Ali: the welcome popup, then Home.
    if (find.text('Got it').evaluate().isNotEmpty) {
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      if (find.text('Dismiss').evaluate().isNotEmpty) {
        await tester.tap(find.text('Dismiss'));
        await tester.pumpAndSettle();
      }
    }
    expect(find.text('Log in'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('cancelling Google sign-in stays on login with a message',
      (tester) async {
    await pumpApp(tester,
        googleAuth: FakeGoogleAuthService(const GoogleSignInCancelled()));
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets('a failed Google sign-in stays on login with a message',
      (tester) async {
    await pumpApp(tester,
        googleAuth: FakeGoogleAuthService(const GoogleSignInFailed(
          'Google sign-in failed. Please try again or use member login.',
        )));
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Google sign-in failed. Please try again or use member login.'),
        findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
  });


  testWidgets('category breakdown renders from recorded expenses',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    await _addExpenseViaSheet(tester,
        title: 'Cleaning', amount: '900.00', category: 'Cleaning');
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Spending by category'), 300);
    await tester.pumpAndSettle();
    // Breakdown bars, computed from the two recorded expenses.
    expect(find.text('Utilities'), findsOneWidget);
    expect(find.text('PKR 1500.00 · 63%'), findsOneWidget);
    expect(find.text('Cleaning'), findsOneWidget);
    expect(find.text('PKR 900.00 · 38%'), findsOneWidget);
    // Monthly summary from the same history: biggest + top payer.
    expect(find.text('Internet — PKR 1500.00'), findsOneWidget);
    expect(find.text('Ali — PKR 2400.00'), findsOneWidget);
    // Recurring bill: Internet recorded this month shows paid.
    expect(find.textContaining('Paid — PKR 1500.00'), findsOneWidget);
  });

  testWidgets('search and filter narrow the expenses list',
      (tester) async {
    // Taller surface: both expense tiles must be built at once.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    await _addExpenseViaSheet(tester,
        title: 'Cleaning',
        amount: '900.00',
        category: 'Cleaning',
        payer: 'Bilal');
    // Search by title.
    await tester.enterText(
        find.widgetWithText(TextField, 'Search expenses by title'),
        'internet');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Internet'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Cleaning'), findsNothing);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Cleaning'), findsOneWidget);
    // Filter by category.
    await tester.tap(find.text('Utilities'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Internet'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Cleaning'), findsNothing);
    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();
    // Filter by member (payer).
    await tester.tap(find.text('Bilal'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Cleaning'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Internet'), findsNothing);
    await tester.tap(find.text('All members'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Internet'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Cleaning'), findsOneWidget);
  });

  testWidgets('budget banner shows at 84 percent used', (tester) async {
    await loginAs(tester, 'Ali');
    await tester.scrollUntilVisible(
        find.textContaining('have used 84.0% of the monthly budget'), 300);
    await tester.pumpAndSettle();
    expect(find.textContaining('have used 84.0% of the monthly budget'),
        findsOneWidget);
    expect(find.text('Near Limit'), findsWidgets);
  });

  testWidgets('receipt parser fills the form from a sample receipt',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Expense'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Paste receipt'),
        'Grocery Store\nMilk 2L - Rs 780.00\nBread - Rs 120.00\n'
        'Total: Rs 900.00\n05/11/2026');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Parse receipt'));
    await tester.pumpAndSettle();
    final title = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Title (e.g. Internet Bill)'));
    final amount = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Amount (PKR)'));
    expect(title.controller!.text, 'Milk 2L');
    expect(amount.controller!.text, '900.00');
    expect(find.text('Could not read a price/item from this receipt'),
        findsNothing);
  });

  testWidgets('receipt parser shows a clear message on unparseable text',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Expense'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Paste receipt'),
        'hello there, no prices here');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Parse receipt'));
    await tester.pumpAndSettle();
    expect(find.text('Could not read a price/item from this receipt'),
        findsOneWidget);
    // The form stays EMPTY — nothing was invented.
    final title = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Title (e.g. Internet Bill)'));
    final amount = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Amount (PKR)'));
    expect(title.controller!.text, isEmpty);
    expect(amount.controller!.text, isEmpty);
  });

  testWidgets('category cap banner appears at 80 percent of a cap',
      (tester) async {
    await loginAs(tester, 'Ali');
    // No cap set yet: no banner, no bar.
    expect(find.text('Near a category cap'), findsNothing);
    // Caps live ONLY in Monthly view > Budgets (no-overlap rule).
    await _openDrawer(tester);
    await tester.tap(find.text('Monthly view'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Category caps'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    // First "Set cap" button is Grocery (capCategories order).
    await tester.tap(find.text('Set cap').first);
    await tester.pumpAndSettle();
    expect(find.text('Cap for Grocery'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Monthly cap (PKR)'), '1000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PKR 0.00 of PKR 1000.00'), findsOneWidget);
    // Spend 850 of the 1000 cap (85%) on Groceries. Monthly view
    // is a pushed route with no bottom nav on it, so go back to
    // the tabs first — like a real user would.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Milk', amount: '850.00', category: 'Groceries');
    await _openDrawer(tester);
    await tester.tap(find.text('Monthly view'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Near a category cap'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Near a category cap'), findsOneWidget);
    expect(find.text('Grocery: PKR 850.00 of PKR 1000.00 (85%)'),
        findsOneWidget);
  });

  testWidgets('trend chart renders from recorded expenses', (tester) async {
    await loginAs(tester, 'Ali');
    await _openDrawer(tester);
    await tester.tap(find.text('Monthly view'));
    await tester.pumpAndSettle();
    // No recorded history yet: honest empty state, no fake bars.
    expect(find.text('Weekly spending'), findsOneWidget);
    expect(find.text('No expenses recorded yet in this session'),
        findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Record one expense dated today (day 5 → Week 1).
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    await _openDrawer(tester);
    await tester.tap(find.text('Monthly view'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Weekly spending'), 300);
    await tester.pumpAndSettle();
    expect(find.text('Week 1'), findsOneWidget);
    expect(find.text('1500'), findsOneWidget);
  });

  testWidgets('drawer navigates to Monthly view and Profile',
      (tester) async {
    await loginAs(tester, 'Ali');
    await _openDrawer(tester);
    await tester.tap(find.text('Monthly view'));
    await tester.pumpAndSettle();
    expect(find.text('Monthly view'), findsWidgets);
    expect(find.text('This month'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Monthly Budget'), findsOneWidget);
    await _openDrawer(tester);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(find.text('Ali'), findsWidgets);
    expect(find.text('M01'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Monthly Budget'), findsOneWidget);
  });

  testWidgets('Timeline lists a posted expense and settlement',
      (tester) async {
    await loginAs(tester, 'Ali');
    // Timeline is drawer-only: it must NOT appear on Home.
    expect(find.text('Timeline'), findsNothing);
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    // Record a settlement: Ayesha → Ali 250 (max from Smart Settle).
    await tester.tap(find.text('Settle Up'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Settle Debt'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settle Debt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ayesha → Ali · up to PKR 250.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record settlement'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm payment'));
    await tester.pumpAndSettle();
    expect(find.text('Settlement recorded.'), findsOneWidget);
    await _openDrawer(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsWidgets);
    expect(find.text('Expense: Internet'), findsOneWidget);
    expect(find.text('PKR 1500.00'), findsOneWidget);
    expect(find.text('Settlement'), findsOneWidget);
    expect(find.text('PKR 250.00'), findsOneWidget);
  });

  testWidgets('"Others" adds an item to the shopping list',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    expect(find.text('Current List (2)'), findsOneWidget);
    await tester.tap(find.text('Others'));
    await tester.pumpAndSettle();
    expect(find.text('Eggs'), findsOneWidget);
    await tester.tap(find.text('Eggs'));
    await tester.pumpAndSettle();
    expect(find.text('Eggs added to the shopping list.'), findsOneWidget);
    expect(find.text('Current List (3)'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Eggs (pack × 1)'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Eggs (pack × 1)'), findsOneWidget);
    // The list is scrollable: the last item is reachable too.
    await tester.tap(find.text('Others'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Gas refill'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    expect(find.text('Gas refill'), findsOneWidget);
    await tester.tap(find.text('Gas refill'));
    await tester.pumpAndSettle();
    expect(find.text('Current List (4)'), findsOneWidget);
  });

  testWidgets('Monthly view shows the logged-in member breakdown',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    await _addExpenseViaSheet(tester,
        title: 'Cleaning',
        amount: '900.00',
        category: 'Cleaning',
        payer: 'Bilal');
    await _openDrawer(tester);
    await tester.tap(find.text('Monthly view'));
    await tester.pumpAndSettle();
    // Ali paid Internet only; Bilal's Cleaning is not his.
    expect(find.text('Your spending by category'), findsOneWidget);
    expect(find.text('Utilities'), findsOneWidget);
    expect(find.text('PKR 1500.00 · 100%'), findsOneWidget);
    // The expenses list sits below the fold — a ListView builds
    // lazily, so scroll it into view before expecting it.
    await tester.scrollUntilVisible(find.text('Your expenses'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Your expenses'), findsOneWidget);
    expect(find.text('Internet'), findsWidgets);
    // "Cleaning" still appears on this screen in the Budgets
    // section (the caps card lists every category you can cap),
    // so scope this to Ali's own expenses list: Bilal's Cleaning
    // must not be in it.
    expect(find.widgetWithText(ListTile, 'Cleaning'), findsNothing);
  });

  testWidgets('add expense sheet animates in and its action works',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Expense'));
    // Mid-animation (100ms of the slide-up): the sheet is already
    // in the tree, animating — not an instant jump.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Add New Expense'), findsWidgets);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Title (e.g. Internet Bill)'),
        'Milk');
    await tester.enterText(
        find.widgetWithText(TextField, 'Amount (PKR)'), '780.00');
    // Tap a category chip first (as a real user would): it moves
    // focus off the Amount field, so the framework's caret
    // bring-into-view does not scroll the sheet back after the
    // ensureVisible below.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Groceries'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add expense'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add expense'));
    await tester.pumpAndSettle();
    // The new expense lands in the recent-expenses list below the
    // fold — scroll it into view (ListView builds lazily).
    await tester.scrollUntilVisible(find.widgetWithText(ListTile, 'Milk'),
        300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Milk'), findsOneWidget);
  });

  testWidgets(
      'celebration appears once per login with the right saved amount',
      (tester) async {
    await pumpApp(tester);
    await loginOnCurrentPage(tester, 'Ayesha', dismissWelcome: false);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    // Ayesha's share 1350 vs fair share 5000/3 = 1666.67 → saved 316.67.
    expect(find.text('Great job, Ayesha!'), findsOneWidget);
    expect(find.text('You saved PKR 316.67 this month'), findsOneWidget);
    await tester.tap(find.text('View monthly summary'));
    await tester.pumpAndSettle();
    expect(find.text('Monthly view'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Back on Home: the celebration must NOT show again this login.
    expect(find.text('Great job, Ayesha!'), findsNothing);
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Great job, Ayesha!'), findsNothing);
  });

  testWidgets('celebration does NOT appear when nobody saved',
      (tester) async {
    await loginAs(tester, 'Ali',
        repository: FakeRepository(api: OverBudgetApi()));
    expect(find.text('Great job, Ali!'), findsNothing);
    expect(find.text('Budget exceeded'), findsWidgets);
  });

  testWidgets('per-member view groups expenses by payer',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    await _addExpenseViaSheet(tester,
        title: 'Cleaning',
        amount: '900.00',
        category: 'Cleaning',
        payer: 'Bilal');
    await tester.scrollUntilVisible(find.text('Expenses by member'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    // Equal splits: Internet 500 each, Cleaning 300 each → every
    // member's share is 800. Paid differs per member.
    expect(find.text('Paid PKR 1500.00 · Share PKR 800.00'), findsOneWidget);
    expect(find.text('Paid PKR 900.00 · Share PKR 800.00'), findsOneWidget);
    expect(find.text('Paid PKR 0.00 · Share PKR 800.00'), findsOneWidget);
    // Per-member rows list each payer's expenses (exact row text —
    // the recent-expenses list shows the same titles with a
    // "· Paid by …" suffix, so a loose contains-match is ambiguous).
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    expect(find.text('Internet · $today'), findsOneWidget);
    expect(find.text('Cleaning · $today'), findsOneWidget);
  });

  testWidgets('fixed monthly expenses: list, apply once, edit, delete',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Fixed monthly expenses'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    // Seeded templates: Internet 1500 (Bilal) + Electricity 1020
    // (Ali), equal among all three → Ali's share 500 + 340 = 840.
    expect(find.text('Monthly total PKR 2520.00 · Your share PKR 840.00'),
        findsOneWidget);
    expect(find.text('Internet — PKR 1500.00 / month'), findsOneWidget);
    expect(find.text('Electricity — PKR 1020.00 / month'), findsOneWidget);
    expect(
        find.text('Utilities · Paid by Bilal · Your share PKR 500.00'),
        findsOneWidget);
    expect(find.text('Utilities · Paid by Ali · Your share PKR 340.00'),
        findsOneWidget);
    // Apply for this month: posts both, second tap applies nothing.
    // (The fixed section sits below the fold — scroll it into view.)
    await tester.scrollUntilVisible(
        find.text('Apply fixed for this month'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply fixed for this month'));
    await tester.pumpAndSettle();
    expect(find.text('Applied 2 fixed expense(s) for this month.'),
        findsOneWidget);
    // The first snackbar is still showing (4s timer); the second
    // apply's snackbar queues behind it. Let the first dismiss
    // before tapping again, or the second message never appears.
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Apply fixed for this month'));
    await tester.pumpAndSettle();
    expect(find.text('Already applied for this month.'), findsOneWidget);
    // Edit Internet 1500 → 1800: share 600, total 2820, my share 940.
    await tester.tap(find.byTooltip('Edit amount').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit Internet'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Amount (PKR)'), '1800');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Monthly total PKR 2820.00 · Your share PKR 940.00'),
        findsOneWidget);
    expect(find.text('Internet — PKR 1800.00 / month'), findsOneWidget);
    // Delete Electricity: total drops to the edited Internet only.
    await tester.tap(find.byTooltip('Delete fixed expense').at(1));
    await tester.pumpAndSettle();
    expect(find.text('Delete Electricity?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Monthly total PKR 1800.00 · Your share PKR 600.00'),
        findsOneWidget);
    expect(find.text('Electricity — PKR 1020.00 / month'), findsNothing);
  });

  testWidgets('marking an expense fixed adds it to the fixed list',
      (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Water',
        amount: '600.00',
        category: 'Utilities',
        repeatMonthly: true);
    await tester.scrollUntilVisible(
        find.text('Fixed monthly expenses'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Water — PKR 600.00 / month'), findsOneWidget);
    expect(find.text('Monthly total PKR 3120.00 · Your share PKR 1040.00'),
        findsOneWidget);
  });

  testWidgets('profile photo edit updates the avatar app-wide',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await loginAs(tester, 'Ali');
    await _openDrawer(tester);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    // Visible edit controls: camera badge on the avatar + button.
    expect(find.byIcon(Icons.photo_camera), findsOneWidget);
    expect(find.text('Change photo'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is Image && w.image is MemoryImage),
        findsNothing);
    final previous = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = _FakePicker(_tinyPng);
    addTearDown(() => ImagePickerPlatform.instance = previous);
    await tester.tap(find.text('Change photo'));
    await tester.pumpAndSettle();
    // The picked photo is now the avatar, and it persisted locally.
    expect(
        find.byWidgetPredicate(
            (w) => w is Image && w.image is MemoryImage),
        findsWidgets);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile_image_M01'), isNotNull);
    // Back on Home the same photo shows (single source of truth).
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate(
            (w) => w is Image && w.image is MemoryImage),
        findsWidgets);
  });

  testWidgets('AppBar theme toggle switches the whole app to dark',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await loginAs(tester, 'Ali');
    expect(Theme.of(tester.element(find.text('Monthly Budget'))).brightness,
        Brightness.light);
    await tester.tap(find.byTooltip('Switch to dark theme'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Monthly Budget'))).brightness,
        Brightness.dark);
    // Every tab renders in dark mode without overflow.
    for (final tab in ['Shopping', 'Expenses', 'Settle Up', 'Home']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }
    expect(Theme.of(tester.element(find.text('Monthly Budget'))).brightness,
        Brightness.dark);
    await tester.tap(find.byTooltip('Switch to light theme'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Monthly Budget'))).brightness,
        Brightness.light);
  });

  testWidgets('dark theme choice persists across restarts',
      (tester) async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await loginAs(tester, 'Ali');
    // Saved 'dark' was applied before first paint (via AppState load).
    expect(Theme.of(tester.element(find.text('Monthly Budget'))).brightness,
        Brightness.dark);
    // Toggling back to light persists 'light'.
    await tester.tap(find.byTooltip('Switch to light theme'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');
  });

  testWidgets('drawer theme switch controls the same theme state',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    await loginAs(tester, 'Ali');
    await _openDrawer(tester);
    expect(find.text('Dark theme'), findsOneWidget);
    // The switch sits below the 600px test fold — scroll the drawer
    // list into view before tapping (harness, not an app bug).
    await tester.scrollUntilVisible(find.text('Dark theme'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark theme'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Monthly Budget'))).brightness,
        Brightness.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
  });


}
