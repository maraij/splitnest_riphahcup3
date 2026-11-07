/// Chat messages for the SplitNest AI assistant (Phase 7).
///
/// Pure data, no storage, no Flutter. lock.json mapping lives in
/// data/local_json_repository.dart (`chatMessages` collection, one
/// entry per message, keyed by the owning account uid).
library;

import 'dart:math';

/// One chat message: a user question or an assistant reply.
///
/// `role` is `user` or `assistant`. `userId` is the local account
/// uid that owns the message — history is per user, so two accounts
/// on the same device never see each other's chats.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.userId,
    required this.role,
    required this.text,
    required this.timestamp,
  });

  final String id;
  final String userId;
  final String role;
  final String text;
  final DateTime timestamp;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'role': role,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String? ?? '',
        userId: json['userId'] as String? ?? '',
        role: json['role'] as String? ?? 'user',
        text: json['text'] as String? ?? '',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );

  /// A new user message with a fresh id and the current time.
  factory ChatMessage.user({required String userId, required String text}) =>
      ChatMessage(
        id: _newId(),
        userId: userId,
        role: 'user',
        text: text,
        timestamp: DateTime.now(),
      );

  /// A new assistant reply with a fresh id and the current time.
  factory ChatMessage.assistant({
    required String userId,
    required String text,
  }) =>
      ChatMessage(
        id: _newId(),
        userId: userId,
        role: 'assistant',
        text: text,
        timestamp: DateTime.now(),
      );

  static String _newId() {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    final suffix =
        List.generate(6, (_) => alphabet[r.nextInt(alphabet.length)]).join();
    return 'chat-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }
}
