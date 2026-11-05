import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:splitnest/data/api_client.dart';
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
  Future<List<ShoppingItem>> getShopping() async => [
        ShoppingItem(id: 'S01', title: 'Milk', unit: 'bottle', requestedQty: 2, status: 'Pending'),
        ShoppingItem(id: 'S02', title: 'Rice', unit: 'pack', requestedQty: 1, status: 'Pending'),
      ];
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

/// API that always fails, for the network-error test.
class ThrowingApi extends ApiClient {
  ThrowingApi() : super(baseUrl: 'http://fake');
  @override
  Future<List<Member>> getMembers() async =>
      throw ApiException('Could not reach the backend.');
}

Future<void> pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AppState(repository: FakeRepository())..refresh(),
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
/// demo password. Dismisses the once-per-login welcome popup.
Future<void> loginAs(WidgetTester tester, String name) async {
  await pumpApp(tester);
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
  expect(find.text('Choose who you are to continue.'), findsOneWidget);
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
  }
}

/// Adds an expense through the real Add New Expense sheet UI.
/// [payer] changes the sheet's payer dropdown; otherwise the payer
/// defaults to the logged-in member.
Future<void> _addExpenseViaSheet(
  WidgetTester tester, {
  required String title,
  required String amount,
  required String category,
  String? payer,
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
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(payer));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.text('Add expense'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Add expense'));
  await tester.pumpAndSettle();
}

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
    expect(find.text('Choose who you are to continue.'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Choose who you are to continue.'), findsOneWidget);
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
    expect(find.text('Choose who you are to continue.'), findsOneWidget);
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
    expect(find.text('Choose who you are to continue.'), findsOneWidget);
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
    // Tab switch + back: the popup must NOT reappear in this session.
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('You are using SplitNest as Ayesha (M02)'),
        findsNothing);
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
    expect(find.text('Choose who you are to continue.'), findsOneWidget);
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
    expect(find.textContaining('PKR 1500.00 ·'), findsOneWidget);
    expect(find.text('Cleaning'), findsOneWidget);
    expect(find.textContaining('PKR 900.00 ·'), findsOneWidget);
    // Monthly summary from the same history: biggest + top payer.
    expect(find.text('Internet — PKR 1500.00'), findsOneWidget);
    expect(find.text('Ali — PKR 2400.00'), findsOneWidget);
    // Recurring bill: Internet recorded this month shows paid.
    expect(find.textContaining('Paid — PKR 1500.00'), findsOneWidget);
  });

  testWidgets('search and filter narrow the expenses list',
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

  testWidgets('quick-add posts a real expense', (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    expect(find.text('Quick add'), findsNothing);
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    expect(find.text('Quick add'), findsOneWidget);
    expect(find.text('Internet — PKR 1500.00'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Internet'), findsOneWidget);
    await tester.tap(find.text('Internet — PKR 1500.00'));
    await tester.pumpAndSettle();
    // A second, real expense was posted and recorded.
    expect(find.widgetWithText(ListTile, 'Internet'), findsNWidgets(2));
  });

  // TEMPORARY DIAGNOSTIC — remove before finishing.
  testWidgets('diag quickadd', (tester) async {
    await loginAs(tester, 'Ali');
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
    debugPrint('DIAG after sheet add: tiles=${find.widgetWithText(ListTile, 'Internet').evaluate().length} quickadd=${find.text('Internet — PKR 1500.00').evaluate().length}');
    await tester.tap(find.text('Internet — PKR 1500.00'));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.byType(Scaffold).first);
    final st = Provider.of<AppState>(ctx, listen: false);
    debugPrint('DIAG after quick-add tap: tiles=${find.widgetWithText(ListTile, 'Internet').evaluate().length} history=${st.recentExpenses.length} err=${st.errorMessage} busy=${st.isBusy}');
  });

}
