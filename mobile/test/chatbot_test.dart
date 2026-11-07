// Phase 7 — AI chatbot (provider, household context, controller,
// history persistence).
//
// Covers:
//   1. buildHouseholdContext: real figures from live balances,
//      and the explicit "no data loaded" text when balances are null.
//   2. GeminiChatProvider with a fake HTTP client (package:http
//      MockClient): reply parsing, HTTP-error handling, and the key
//      never appearing in any log entry. The LIVE Gemini call is
//      NOT tested — no API key was supplied for this build, and no
//      test ever calls Google's servers.
//   3. ChatController with fake providers: send/receive, empty
//      message validation, not-configured state blocks sending,
//      failure + retry, and history persistence round-trip through
//      the real LocalJsonRepository (in-memory store).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:splitnest/core/services/app_logger.dart';
import 'package:splitnest/data/demo_benchmark.dart';
import 'package:splitnest/data/local_auth_service.dart';
import 'package:splitnest/data/local_json_repository.dart';
import 'package:splitnest/domain/balances.dart';
import 'package:splitnest/domain/models.dart';
import 'package:splitnest/features/chatbot/chat_controller.dart';
import 'package:splitnest/features/chatbot/data/ai_provider.dart';
import 'package:splitnest/features/chatbot/data/chat_context.dart';
import 'package:splitnest/state/app_state.dart';

import 'fake_repository.dart';

/// A fake key used ONLY to prove redaction — it is not a real key
/// and was never sent to any server (all provider tests below use a
/// MockClient, never the network).
const String _fakeKey = 'AIzaSyFakeKeyForTestOnly1234567890abcdef';

class _FakeAiChatProvider implements AiChatProvider {
  _FakeAiChatProvider({this.configured = true});

  bool configured;
  String? lastUserMessage;
  String? lastContext;
  String reply = 'You spent PKR 4,200.00 this month.';

  @override
  bool get isConfigured => configured;

  @override
  Future<String> sendMessage({
    required String userMessage,
    required String householdContext,
  }) async {
    lastUserMessage = userMessage;
    lastContext = householdContext;
    return reply;
  }
}

/// Fails the first call, succeeds after that — for the retry test.
class _FlakyAiChatProvider implements AiChatProvider {
  var _calls = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<String> sendMessage({
    required String userMessage,
    required String householdContext,
  }) async {
    _calls++;
    if (_calls == 1) {
      throw AiChatException(
        'The AI request failed (HTTP 503). Try again in a moment.',
        statusCode: 503,
      );
    }
    return 'Recovered reply.';
  }
}

Balances _benchmarkBalances() => computeBalances(
      expenses: benchmarkExpenseRecords(),
      payments: const [],
      members: [
        Member(id: 'M01', name: 'Ali'),
        Member(id: 'M02', name: 'Ayesha'),
        Member(id: 'M03', name: 'Bilal'),
      ],
      budgetPaisa: 500000,
    );

Future<AppState> _loggedInState({
  FakeSplitNestRepository? repository,
}) async {
  final state = AppState(
    repository: repository ?? FakeSplitNestRepository.benchmark(),
  );
  final ok = await state.loginWithDemo(memberId: 'M01');
  expect(ok, isTrue);
  return state;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('buildHouseholdContext', () {
    test('uses real figures from live balances', () {
      final context = buildHouseholdContext(
        memberName: 'Ali',
        balances: _benchmarkBalances(),
        recentExpenses: benchmarkExpenseRecords(),
      );
      expect(context, contains('Ali'));
      expect(context, contains('5000.00'));
      expect(context, contains('4200.00'));
      expect(context, contains('800.00'));
      expect(context, contains('250.00'));
      expect(context, contains('-450.00'));
      expect(context, contains('200.00'));
      // Recent expenses are listed by title.
      expect(context, contains('Internet Bill'));
      expect(context, contains('Electricity Bill'));
    });

    test('says plainly when no household data is loaded', () {
      final context = buildHouseholdContext(
        memberName: 'Ali',
        balances: null,
        recentExpenses: const [],
      );
      expect(context, contains('No household data is loaded'));
      expect(context, isNot(contains('4200.00')));
    });

    test('system prompt forbids inventing figures', () {
      expect(chatbotSystemPrompt, contains('NEVER invent'));
      // The no-data summary says the same thing in plain words.
      expect(
        buildHouseholdContext(
          memberName: 'Ali',
          balances: null,
          recentExpenses: const [],
        ),
        contains('Do not invent'),
      );
    });
  });

  group('GeminiChatProvider (fake HTTP client — no live call)', () {
    test('not configured without a key; configured with one', () {
      expect(GeminiChatProvider(apiKey: '').isConfigured, isFalse);
      expect(
        GeminiChatProvider(apiKey: 'some-key').isConfigured,
        isTrue,
      );
      // No --dart-define was passed to this test run, so the
      // default provider (which reads GEMINI_API_KEY from the
      // environment) is not configured either.
      expect(GeminiChatProvider().isConfigured, isFalse);
    });

    test('send without a key throws a plain not-configured error', () async {
      final provider = GeminiChatProvider();
      await expectLater(
        provider.sendMessage(
          userMessage: 'Hello',
          householdContext: 'No data.',
        ),
        throwsA(
          isA<AiChatException>().having(
            (e) => e.message,
            'message',
            contains('not configured'),
          ),
        ),
      );
    });

    test('parses a reply from a 200 response', () async {
      Uri? capturedUri;
      final client = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'You spent PKR 4,200.00 this month.'},
                  ],
                },
              },
            ],
          }),
          200,
        );
      });
      final logger = AppLogger.inMemory();
      final provider = GeminiChatProvider(
        client: client,
        apiKey: _fakeKey,
        logger: logger,
      );
      final reply = await provider.sendMessage(
        userMessage: 'How much did we spend?',
        householdContext: 'Total spent this month: PKR 4200.00.',
      );
      expect(reply, 'You spent PKR 4,200.00 this month.');
      // The key is sent as a query parameter — that is how the
      // Gemini REST API authenticates — but it must never appear
      // in any log entry.
      expect(capturedUri?.queryParameters['key'], _fakeKey);
      await logger.flush();
      expect(jsonEncode(logger.entries), isNot(contains(_fakeKey)));
      expect(jsonEncode(logger.entries), isNot(contains('AIzaSyFake')));
    });

    test('non-200 response throws with the status, key never logged',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {'message': 'Service unavailable.'},
          }),
          503,
        );
      });
      final logger = AppLogger.inMemory();
      final provider = GeminiChatProvider(
        client: client,
        apiKey: _fakeKey,
        logger: logger,
      );
      await expectLater(
        provider.sendMessage(
          userMessage: 'Hello',
          householdContext: 'No data.',
        ),
        throwsA(
          isA<AiChatException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', contains('503')),
        ),
      );
      await logger.flush();
      final logged = jsonEncode(logger.entries);
      expect(logged, contains('503'));
      expect(logged, isNot(contains(_fakeKey)));
      expect(logged, isNot(contains('AIzaSyFake')));
    });

    test('empty candidates throw a plain empty-reply error', () async {
      final client = MockClient((request) async {
        return http.Response(jsonEncode({'candidates': []}), 200);
      });
      final provider = GeminiChatProvider(
        client: client,
        apiKey: _fakeKey,
      );
      await expectLater(
        provider.sendMessage(
          userMessage: 'Hello',
          householdContext: 'No data.',
        ),
        throwsA(
          isA<AiChatException>().having(
            (e) => e.message,
            'message',
            contains('empty reply'),
          ),
        ),
      );
    });
  });

  group('ChatController (fake provider)', () {
    test('send stores the question and the grounded reply', () async {
      final state = await _loggedInState();
      final provider = _FakeAiChatProvider();
      final controller =
          ChatController(appState: state, provider: provider);
      await controller.loadHistory();
      expect(controller.messages, isEmpty);

      final ok = await controller.send('How much did we spend?');
      expect(ok, isTrue);
      expect(controller.errorMessage, isNull);
      expect(controller.messages.length, 2);
      expect(controller.messages[0].isUser, isTrue);
      expect(controller.messages[0].text, 'How much did we spend?');
      expect(controller.messages[1].isAssistant, isTrue);
      expect(controller.messages[1].text, contains('4,200.00'));
      // The provider received the question AND the real household
      // context (grounding), not a bare question.
      expect(provider.lastUserMessage, 'How much did we spend?');
      expect(provider.lastContext, contains('4200.00'));
      expect(provider.lastContext, contains('250.00'));
    });

    test('empty message is rejected and nothing is sent', () async {
      final state = await _loggedInState();
      final provider = _FakeAiChatProvider();
      final controller =
          ChatController(appState: state, provider: provider);
      final ok = await controller.send('   ');
      expect(ok, isFalse);
      expect(controller.errorMessage, 'Type a message first.');
      expect(controller.messages, isEmpty);
      expect(provider.lastUserMessage, isNull);
    });

    test('not-configured provider blocks sending entirely', () async {
      final state = await _loggedInState();
      final provider = _FakeAiChatProvider(configured: false);
      final controller =
          ChatController(appState: state, provider: provider);
      expect(controller.isConfigured, isFalse);
      final ok = await controller.send('How much did we spend?');
      expect(ok, isFalse);
      expect(controller.errorMessage, contains('not configured'));
      expect(controller.messages, isEmpty);
      expect(provider.lastUserMessage, isNull);
    });

    test('failed call keeps the question and retry succeeds', () async {
      final state = await _loggedInState();
      final provider = _FlakyAiChatProvider();
      final controller =
          ChatController(appState: state, provider: provider);
      final first = await controller.send('Who owes whom?');
      expect(first, isFalse);
      expect(controller.errorMessage, contains('503'));
      expect(controller.messages.length, 1);
      expect(controller.messages[0].isUser, isTrue);

      final retried = await controller.retry();
      expect(retried, isTrue);
      expect(controller.errorMessage, isNull);
      // Retry re-sends the same question — it is NOT duplicated.
      expect(controller.messages.length, 2);
      expect(controller.messages[1].text, 'Recovered reply.');
    });

    test('retry with no messages does nothing', () async {
      final state = await _loggedInState();
      final controller = ChatController(
        appState: state,
        provider: _FakeAiChatProvider(),
      );
      expect(await controller.retry(), isFalse);
    });

    test('clearHistory empties the list and the store', () async {
      final state = await _loggedInState();
      final controller = ChatController(
        appState: state,
        provider: _FakeAiChatProvider(),
      );
      await controller.send('Hello?');
      expect(controller.messages.length, 2);
      await controller.clearHistory();
      expect(controller.messages, isEmpty);
      expect(await state.loadChatHistory(), isEmpty);
    });
  });

  group('chat history persistence (real LocalJsonRepository)', () {
    test('round-trip through lock.json, per user', () async {
      final store = LockJsonStore.inMemory();
      final repository = LocalJsonRepository(store: store);
      final auth = RealLocalAuthService(store: store);
      final state = AppState(repository: repository, localAuth: auth);
      expect(await state.loginWithDemo(memberId: 'M01'), isTrue);

      final controller = ChatController(
        appState: state,
        provider: _FakeAiChatProvider(),
      );
      await controller.send('How much did we spend?');
      await controller.send('Who owes whom?');
      expect(controller.messages.length, 4);

      // A fresh controller loads the same history from lock.json.
      final reloaded = ChatController(
        appState: state,
        provider: _FakeAiChatProvider(),
      );
      await reloaded.loadHistory();
      expect(reloaded.messages.length, 4);
      expect(reloaded.messages[0].text, 'How much did we spend?');
      expect(reloaded.messages[1].text, contains('4,200.00'));
      expect(reloaded.messages[2].text, 'Who owes whom?');

      // The raw document holds the messages under the user's uid.
      final doc = await store.load();
      final stored = (doc['chatMessages'] as List)
          .cast<Map<String, dynamic>>();
      expect(stored.length, 4);
      expect(stored.every((m) => m['userId'] == 'demo-M01'), isTrue);

      // Another user's history is separate (empty here).
      expect(await repository.getChatMessages('demo-M02'), isEmpty);

      // Clearing removes only this user's messages.
      await controller.clearHistory();
      expect(await state.loadChatHistory(), isEmpty);
      expect(
        (await store.load())['chatMessages'],
        isEmpty,
      );
    });

    test('lock.json without chatMessages still loads (old files)',
        () async {
      final store = LockJsonStore.inMemory();
      final repository = LocalJsonRepository(store: store);
      // Simulate a pre-Phase-7 file: load the seed, drop the
      // collection, save it back through a second store over the
      // same in-memory access.
      final doc = await store.load();
      doc.remove('chatMessages');
      await store.save(doc);
      // A fresh repository over the same store reads it back.
      expect(await repository.getChatMessages('demo-M01'), isEmpty);
      // …and writing a message recreates the collection.
      final state = AppState(
        repository: repository,
        localAuth: RealLocalAuthService(store: store),
      );
      expect(await state.loginWithDemo(memberId: 'M01'), isTrue);
      final controller = ChatController(
        appState: state,
        provider: _FakeAiChatProvider(),
      );
      expect(await controller.send('Hello?'), isTrue);
      expect((await store.load())['chatMessages'], hasLength(2));
    });
  });
}
