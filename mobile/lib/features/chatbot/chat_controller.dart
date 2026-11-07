/// Chat state for the AI assistant screen (Phase 7).
///
/// [ChatController] owns the message list, the sending state and
/// the error state; the screen only renders it. History is
/// persisted per user in lock.json through [AppState] (so it
/// survives restarts) and loads when the screen opens.
///
/// Sending is blocked in three cases, each with a plain message:
/// an empty message, the provider not being configured (no Gemini
/// key — the real state of this build), and a failed provider call
/// (the user message stays, the error shows with a retry).
library;

import 'package:flutter/foundation.dart';

import '../../core/services/app_logger.dart';
import '../../domain/chat_message.dart';
import '../../state/app_state.dart';
import 'data/ai_provider.dart';

/// Plain text shown when the AI has no key configured. The screen
/// shows the same explanation in its not-configured card.
const String aiNotConfiguredMessage =
    'AI is not configured: no Gemini API key was supplied. '
    'Run the app with --dart-define=GEMINI_API_KEY=YOUR_KEY.';

class ChatController extends ChangeNotifier {
  ChatController({
    required AppState appState,
    required this._provider,
    AppLogger? logger,
  })  :
        // `_appState` cannot use an initializing formal: the
        // parameter name is public (`appState`) and the field is
        // private.
        // ignore: prefer_initializing_formals
        _appState = appState,
        _providedLogger = logger;

  final AppState _appState;
  final AiChatProvider _provider;
  final AppLogger? _providedLogger;

  /// The logger for chatbot calls: the injected one, or the
  /// AppState's logger when none was given.
  AppLogger get _logger => _providedLogger ?? _appState.logger;

  /// Messages oldest first, as stored in lock.json.
  List<ChatMessage> messages = [];

  /// True while a reply is being awaited (typing indicator).
  bool isSending = false;

  /// The last send error, or null. Shown with a retry action.
  String? errorMessage;

  /// True only when the provider can actually answer (a Gemini
  /// key is present). False in this build — no key was supplied.
  bool get isConfigured => _provider.isConfigured;

  /// True while the first history load is in flight.
  bool isLoadingHistory = false;

  String get _uid => _appState.currentUid;

  /// Loads the persisted history for the signed-in user. A
  /// failure leaves the list empty — the chat still opens, it
  /// just starts fresh for this session.
  Future<void> loadHistory() async {
    if (isLoadingHistory) return;
    isLoadingHistory = true;
    notifyListeners();
    try {
      messages = await _appState.loadChatHistory();
    } catch (_) {
      messages = [];
    } finally {
      isLoadingHistory = false;
      notifyListeners();
    }
  }

  /// Sends [rawText] as the user, then asks the provider for a
  /// reply grounded in the live household summary. Returns false
  /// (with [errorMessage] set) when the message is empty, the AI
  /// is not configured, or the call fails. The user message is
  /// stored before the call, so a failed call keeps it visible
  /// and [retry] can re-send it without duplicating it.
  Future<bool> send(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      errorMessage = 'Type a message first.';
      notifyListeners();
      return false;
    }
    if (!_provider.isConfigured) {
      errorMessage = aiNotConfiguredMessage;
      notifyListeners();
      return false;
    }
    if (isSending) return false;
    final userMessage = ChatMessage.user(userId: _uid, text: text);
    messages = [...messages, userMessage];
    errorMessage = null;
    isSending = true;
    notifyListeners();
    try {
      await _appState.saveChatMessage(userMessage);
    } catch (_) {
      // History persistence is best-effort; the chat continues.
    }
    final ok = await _sendToProvider(userMessage);
    isSending = false;
    notifyListeners();
    return ok;
  }

  /// Re-sends the last user message after a failed call. Returns
  /// false when there is nothing to retry.
  Future<bool> retry() async {
    if (isSending) return false;
    final lastUser =
        messages.where((m) => m.isUser).lastOrNull;
    if (lastUser == null) return false;
    errorMessage = null;
    isSending = true;
    notifyListeners();
    final ok = await _sendToProvider(lastUser);
    isSending = false;
    notifyListeners();
    return ok;
  }

  Future<bool> _sendToProvider(ChatMessage userMessage) async {
    try {
      final reply = await _provider.sendMessage(
        userMessage: userMessage.text,
        householdContext: _appState.householdSummaryForChat(),
      );
      final assistantMessage =
          ChatMessage.assistant(userId: _uid, text: reply);
      messages = [...messages, assistantMessage];
      try {
        await _appState.saveChatMessage(assistantMessage);
      } catch (_) {
        // History persistence is best-effort; the reply still shows.
      }
      _logger.info('chatbot', 'Chat reply shown');
      return true;
    } on AiChatException catch (e) {
      errorMessage = e.message;
      _logger.error(
        'chatbot',
        'Chat call failed',
        data: {'status': e.statusCode},
      );
      return false;
    } catch (e) {
      errorMessage = 'Could not reach the AI. Try again.';
      _logger.error(
        'chatbot',
        'Chat call failed',
        data: {'error': AppLogger.redact(e.toString())},
      );
      return false;
    }
  }

  /// Clears the persisted history for the signed-in user (after
  /// the screen's confirmation dialog) and empties the list.
  Future<void> clearHistory() async {
    try {
      await _appState.clearChatHistory();
    } catch (_) {
      // Best-effort; the in-memory list is cleared regardless.
    }
    messages = [];
    errorMessage = null;
    notifyListeners();
    _logger.info('chatbot', 'Chat history cleared');
  }
}
