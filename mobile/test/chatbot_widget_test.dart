// Phase 7 — AI chatbot screen widget tests.
//
// Covers:
//   1. The app starts (splash → login) and the chatbot opens from
//      the drawer in the NOT-CONFIGURED state: the "AI not
//      configured" card shows, the input is disabled and sending
//      is impossible — nothing is sent anywhere.
//   2. With a configured fake provider: typing a question and
//      sending shows the user bubble and the assistant reply.
//   3. Empty-message send does nothing; the clear-history action
//      removes the messages.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/features/chatbot/chat_controller.dart';
import 'package:splitnest/features/chatbot/chatbot_screen.dart';
import 'package:splitnest/features/chatbot/data/ai_provider.dart';
import 'package:splitnest/main.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';

class _FakeAiChatProvider implements AiChatProvider {
  @override
  bool get isConfigured => true;

  @override
  Future<String> sendMessage({
    required String userMessage,
    required String householdContext,
  }) async =>
      'You spent PKR 4,200.00 this month.';
}

class _NotConfiguredProvider implements AiChatProvider {
  @override
  bool get isConfigured => false;

  @override
  Future<String> sendMessage({
    required String userMessage,
    required String householdContext,
  }) async =>
      throw AiChatException('AI is not configured.');
}

Future<AppState> _loggedInState() async {
  final state = AppState(
    repository: FakeSplitNestRepository.benchmark(),
  );
  expect(await state.loginWithDemo(memberId: 'M01'), isTrue);
  return state;
}

/// Pumps the real app, waits out the splash, and logs in as Ali
/// via the Demo popup (welcome + celebration dismissed).
Future<void> _pumpLoggedInApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AppState(
        repository: FakeSplitNestRepository.benchmark(),
      )..refresh(),
      child: const SplitNestApp(),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('Log in'), findsOneWidget);
  await tester.ensureVisible(find.text('Demo'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Demo'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Ali • M01'));
  await tester.pumpAndSettle();
  if (find.text('Got it').evaluate().isNotEmpty) {
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    if (find.text('Dismiss').evaluate().isNotEmpty) {
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
    }
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('chatbot screen', () {
    testWidgets('opens from the drawer in the not-configured state',
        (tester) async {
      await _pumpLoggedInApp(tester);
      expect(find.text('SplitNest'), findsWidgets);

      // Open the drawer and go to the AI Assistant.
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('AI Assistant'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('AI Assistant'), findsOneWidget);
      await tester.tap(find.text('AI Assistant'));
      await tester.pumpAndSettle();

      // The not-configured card is shown, with the setup steps.
      expect(find.text('AI not configured'), findsOneWidget);
      expect(find.textContaining('Google AI Studio'), findsOneWidget);
      expect(find.textContaining('GEMINI_API_KEY'), findsOneWidget);

      // Sending is disabled: the input is disabled and the send
      // button has no action.
      final field =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(field.enabled, isFalse);
      final send = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.send));
      expect(send.onPressed, isNull);
    });

    testWidgets('configured provider: send shows bubbles and reply',
        (tester) async {
      final state = await _loggedInState();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: ChatbotScreen(provider: _FakeAiChatProvider()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('AI not configured'), findsNothing);

      await tester.enterText(
        find.byType(TextField),
        'How much did we spend?',
      );
      await tester.pump();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
      await tester.pumpAndSettle();

      expect(find.text('How much did we spend?'), findsOneWidget);
      expect(
        find.text('You spent PKR 4,200.00 this month.'),
        findsOneWidget,
      );
      // Timestamps render under each bubble (HH:mm).
      expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsWidgets);
    });

    testWidgets('not-configured provider: send is blocked in the UI',
        (tester) async {
      final state = await _loggedInState();
      final controller = ChatController(
        appState: state,
        provider: _NotConfiguredProvider(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: ChatbotScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('AI not configured'), findsOneWidget);
      final send = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.send));
      expect(send.onPressed, isNull);
      // The controller refuses sends too, not just the button.
      expect(await controller.send('Hello?'), isFalse);
      expect(controller.messages, isEmpty);
    });

    testWidgets('empty message does nothing', (tester) async {
      final state = await _loggedInState();
      final controller = ChatController(
        appState: state,
        provider: _FakeAiChatProvider(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: ChatbotScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      final send = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.send));
      expect(send.onPressed, isNull);
      expect(controller.messages, isEmpty);
    });

    testWidgets('clear history removes the messages', (tester) async {
      final state = await _loggedInState();
      final controller = ChatController(
        appState: state,
        provider: _FakeAiChatProvider(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: ChatbotScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Hello?');
      await tester.pump();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('Hello?'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear chat history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Hello?'), findsNothing);
    });
  });
}
