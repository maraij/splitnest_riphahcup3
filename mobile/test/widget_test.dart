import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/data/repository.dart';
import 'package:splitnest/main.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';

/// Repository that always fails, for the local-unavailable test.
class ThrowingRepository extends FakeSplitNestRepository {
  ThrowingRepository() : super.empty();
  @override
  Future<GroupInfo> ensureGroup({
    required String uid,
    required String displayName,
    required String? email,
    required String legacyMemberId,
    required bool isDemo,
  }) async =>
      throw const LocalDataException(localDataUnavailableMessage);
}

Future<void> pumpApp(WidgetTester tester,
    {SplitNestRepository? repository}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AppState(
        repository: repository ?? FakeSplitNestRepository.benchmark(),
      )..refresh(),
      child: const SplitNestApp(),
    ),
  );
  // pumpAndSettle advances the fake clock past the ~1.8s splash.
  await tester.pumpAndSettle();
}

const _memberIds = {'Ali': 'M01', 'Ayesha': 'M02', 'Bilal': 'M03'};

/// Pumps the app, waits out the splash, and logs in with the Demo
/// button (the member-password login is gone — Phase 3 retired the
/// backend). Dismisses the once-per-login welcome popup (and the
/// savings celebration that follows it on the benchmark balances).
/// Pass [repository] to log into a differently seeded household
/// (e.g. [FakeSplitNestRepository.empty] for a fresh group).
Future<void> loginAs(WidgetTester tester, String name,
    {SplitNestRepository? repository}) async {
  await pumpApp(tester, repository: repository);
  await loginOnCurrentPage(tester, name);
}

/// Logs in on the currently shown login page (also used after logout).
/// Opens Demo, taps the member's account. Dismisses the welcome
/// popup unless [dismissWelcome] is false.
Future<void> loginOnCurrentPage(
  WidgetTester tester,
  String name, {
  bool dismissWelcome = true,
}) async {
  expect(find.text('Log in'), findsOneWidget);
  await tester.ensureVisible(find.text('Demo'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Demo'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('$name • ${_memberIds[name]}'));
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
        create: (_) =>
            AppState(repository: FakeSplitNestRepository.benchmark())
              ..refresh(),
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
    // Fresh group: the history is the persisted lock.json list, so
    // it starts empty here and fills as expenses are posted.
    await loginAs(tester, 'Ali',
        repository: FakeSplitNestRepository.empty());
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    expect(find.text('Add New Expense'), findsOneWidget);
    expect(find.text('No expenses recorded yet'), findsOneWidget);
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

  testWidgets('login shows error with retry when the store is down',
      (tester) async {
    await pumpApp(tester, repository: ThrowingRepository());
    await tester.pumpAndSettle();
    // Logged out, nothing has been asked of the store yet: no error.
    expect(find.textContaining('Local data unavailable'), findsNothing);
    // Demo login asks the store for the household and fails honestly.
    await tester.ensureVisible(find.text('Demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ali • M01'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Local data unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Local data unavailable'), findsOneWidget);
    // No fake data leaked in: no budget, no balances, no members.
    expect(find.text('Monthly Budget'), findsNothing);
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


  testWidgets('login page has no member-password form any more',
      (tester) async {
    // Phase 3 retired the member-password login with the backend;
    // Phase 6 dropped the cloud backend and third-party sign-in:
    // the only ways in are Demo and email.
    await pumpApp(tester);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Demo'), findsOneWidget);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('Sign in with email instead'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsNothing);
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

  testWidgets('wrong email password stays on login with a message',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Sign in with email instead'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'),
        'ali.demo@splitnest.app');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'not-the-password');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(
        find.text('That email or password is not correct. '
            'Try again or reset your password.'),
        findsOneWidget);
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets('email sign-in with a demo account enters Home',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Sign in with email instead'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'),
        'ayesha.demo@splitnest.app');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'ayesha123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('You are using SplitNest as Ayesha (M02)'),
        findsOneWidget);
  });


  testWidgets('category breakdown renders from recorded expenses',
      (tester) async {
    await loginAs(tester, 'Ali',
        repository: FakeSplitNestRepository.empty());
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
    await loginAs(tester, 'Ali',
        repository: FakeSplitNestRepository.empty());
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
    // Filter by member (payer). The member name also appears as a
    // per-member card title further down the list, so target the
    // filter chip specifically.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Bilal'));
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
    await loginAs(tester, 'Ali',
        repository: FakeSplitNestRepository.empty());
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
    await loginAs(tester, 'Ali',
        repository: FakeSplitNestRepository.empty());
    await _openDrawer(tester);
    await tester.tap(find.text('Monthly view'));
    await tester.pumpAndSettle();
    // No recorded history yet: honest empty state, no fake bars.
    expect(find.text('Weekly spending'), findsOneWidget);
    expect(find.text('No expenses recorded yet'), findsWidgets);
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
    // Settle FIRST, from the benchmark balances: Ayesha → Ali 250
    // is the Smart Settle max. (Adding the expense first would move
    // the balances and the 250.00 chip would not exist.)
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
    await tester.tap(find.text('Expenses'));
    await tester.pumpAndSettle();
    await _addExpenseViaSheet(tester,
        title: 'Internet', amount: '1500.00', category: 'Utilities');
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
    await loginAs(tester, 'Ali',
        repository: FakeSplitNestRepository.empty());
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
        repository: FakeSplitNestRepository.overBudget());
    expect(find.text('Great job, Ali!'), findsNothing);
    expect(find.text('Budget exceeded'), findsWidgets);
  });

  testWidgets('per-member view groups expenses by payer',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loginAs(tester, 'Ali',
        repository: FakeSplitNestRepository.empty());
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
    // (The persisted benchmark history makes the list longer than it
    // used to be, so scroll the fixed section back into view first.)
    await tester.scrollUntilVisible(
        find.byTooltip('Edit amount').first, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
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
    await tester.scrollUntilVisible(
        find.byTooltip('Delete fixed expense').at(1), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
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
    // The switch sits below the 600px test fold — scroll the drawer
    // list into view before asserting or tapping (harness, not an
    // app bug). It fell outside the ListView cache extent once the
    // Phase 7 AI Assistant tile was added above it.
    await tester.scrollUntilVisible(find.text('Dark theme'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    expect(find.text('Dark theme'), findsOneWidget);
    await tester.tap(find.text('Dark theme'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Monthly Budget'))).brightness,
        Brightness.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
  });


}
