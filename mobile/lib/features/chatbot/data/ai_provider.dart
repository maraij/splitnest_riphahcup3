/// AI chat provider abstraction + the Gemini implementation
/// (Phase 7).
///
/// The app talks to the [AiChatProvider] interface only, so the
/// live call can be swapped or faked in tests without touching the
/// UI. [GeminiChatProvider] implements it against the Google
/// Gemini REST API (`v1beta generateContent`) with the `http`
/// package.
///
/// API KEY: supplied ONLY via `--dart-define=GEMINI_API_KEY=...`
/// (read with `String.fromEnvironment`). The key is NEVER
/// hardcoded, NEVER written to a file, NEVER stored in lock.json,
/// and NEVER logged — failures are logged with the HTTP status
/// only. With no key the provider reports [isConfigured] == false
/// and every send throws [AiChatException]; the chat screen shows
/// the not-configured state instead (see chatbot_screen.dart).
///
/// The LIVE Gemini call is NOT tested against Google's servers —
/// no key was supplied for this build. The provider logic (request
/// shape, reply parsing, error handling, key never in logs) IS
/// tested with a fake HTTP client in mobile/test/chatbot_test.dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/services/app_logger.dart';
import 'chat_context.dart';

/// Thrown when a chat call cannot produce a reply. [message] is
/// safe to show on screen verbatim; it never contains the API key.
class AiChatException implements Exception {
  AiChatException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// The AI chat seam: one call, one reply, plus the household
/// context the reply must be grounded in.
abstract class AiChatProvider {
  /// True only when the provider can actually answer — for Gemini,
  /// when an API key is present.
  bool get isConfigured;

  /// Sends [userMessage] with the household summary in
  /// [householdContext] and returns the assistant's reply text.
  /// Throws [AiChatException] when no reply can be produced.
  Future<String> sendMessage({
    required String userMessage,
    required String householdContext,
  });
}

/// Gemini implementation of [AiChatProvider] (REST, v1beta).
class GeminiChatProvider implements AiChatProvider {
  GeminiChatProvider({
    http.Client? client,
    String? apiKey,
    this._logger,
  })  : _client = client ?? http.Client(),
        _apiKey = apiKey ?? const String.fromEnvironment('GEMINI_API_KEY');

  /// The Gemini model used for chat. `gemini-2.5-flash` is the
  /// current fast text model on the v1beta API.
  static const String model = 'gemini-2.5-flash';

  static const Duration _timeout = Duration(seconds: 30);

  final http.Client _client;

  /// The API key, from `--dart-define=GEMINI_API_KEY=...` (or the
  /// [apiKey] constructor override, used by tests). It is held in
  /// memory only — never written anywhere, never logged.
  final String _apiKey;
  final AppLogger? _logger;

  @override
  bool get isConfigured => _apiKey.isNotEmpty;

  @override
  Future<String> sendMessage({
    required String userMessage,
    required String householdContext,
  }) async {
    if (!isConfigured) {
      throw AiChatException(
        'AI is not configured: no Gemini API key was supplied. '
        'Run the app with --dart-define=GEMINI_API_KEY=YOUR_KEY.',
      );
    }
    // The key travels as a `key` query parameter, which is how the
    // Gemini REST API authenticates API keys. It is never put in
    // the request body and never logged.
    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:generateContent',
      {'key': _apiKey},
    );
    final body = {
      'system_instruction': {
        'parts': [
          {'text': chatbotSystemPrompt},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {
              'text': '$householdContext\n\n'
                  'User question: $userMessage',
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0.3},
    };
    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on TimeoutException {
      _logger?.error(
        'chatbot',
        'Gemini request timed out',
        data: {'timeoutSeconds': _timeout.inSeconds},
      );
      throw AiChatException(
        'The AI took too long to reply. Check your connection and '
        'try again.',
      );
    } catch (e) {
      // Network failure, never the key: the message is redacted by
      // the logger, and the user-facing text carries no detail.
      _logger?.error(
        'chatbot',
        'Gemini request failed',
        data: {'error': AppLogger.redact(e.toString())},
      );
      throw AiChatException(
        'Could not reach the AI. Check your connection and try again.',
      );
    }
    if (response.statusCode != 200) {
      final detail = _errorDetail(response.body);
      _logger?.error(
        'chatbot',
        'Gemini request failed',
        data: {'status': response.statusCode, 'detail': detail},
      );
      throw AiChatException(
        'The AI request failed (HTTP ${response.statusCode}). '
        '${detail.isEmpty ? 'Try again in a moment.' : detail}',
        statusCode: response.statusCode,
      );
    }
    final reply = _replyText(response.body);
    if (reply == null || reply.trim().isEmpty) {
      _logger?.warn('chatbot', 'Gemini returned an empty reply');
      throw AiChatException(
        'The AI returned an empty reply. Try asking again.',
      );
    }
    _logger?.info(
      'chatbot',
      'Gemini reply received',
      data: {'replyChars': reply.length},
    );
    return reply;
  }

  /// Extracts the reply text from a generateContent response:
  /// `candidates[0].content.parts[].text` joined. Returns null
  /// when the shape is not what was expected.
  static String? _replyText(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final candidates = decoded['candidates'];
      if (candidates is! List || candidates.isEmpty) return null;
      final first = candidates.first;
      if (first is! Map<String, dynamic>) return null;
      final content = first['content'];
      if (content is! Map<String, dynamic>) return null;
      final parts = content['parts'];
      if (parts is! List) return null;
      final texts = parts
          .whereType<Map<String, dynamic>>()
          .map((p) => p['text'])
          .whereType<String>()
          .toList();
      if (texts.isEmpty) return null;
      return texts.join('\n');
    } catch (_) {
      return null;
    }
  }

  /// Extracts the human-readable `error.message` from a Gemini
  /// error body, redacted. Empty when the body carries no message.
  static String _errorDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return '';
      final error = decoded['error'];
      if (error is! Map<String, dynamic>) return '';
      final message = error['message'];
      if (message is! String) return '';
      return AppLogger.redact(message);
    } catch (_) {
      return '';
    }
  }
}
