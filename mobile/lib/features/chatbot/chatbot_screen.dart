/// AI Assistant screen (Phase 7).
///
/// A household expense assistant that answers from the LIVE
/// household data (totals, balances, budget usage, recent expenses
/// — see features/chatbot/data/chat_context.dart). It never invents
/// figures: the system prompt forbids it, and when data is missing
/// the bot says so.
///
/// NOT-CONFIGURED STATE (the real state of this build — no Gemini
/// API key has been supplied): the screen shows a plain
/// "AI not configured" card with the exact setup steps, and
/// sending is disabled. Nothing is sent anywhere in that state,
/// and the screen never claims the live AI call works.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../domain/chat_message.dart';
import '../../state/app_state.dart';
import 'chat_controller.dart';
import 'data/ai_provider.dart';

/// Formats a message timestamp as HH:mm (24-hour).
String formatChatTime(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

class ChatbotScreen extends StatefulWidget {
  const ChatbotScreen({super.key, this.provider, this.controller});

  /// Injectable for tests. Defaults to the real Gemini provider
  /// (key from `--dart-define=GEMINI_API_KEY=...`, empty in this
  /// build — see [GeminiChatProvider]).
  final AiChatProvider? provider;

  /// Injectable for tests. Defaults to a fresh [ChatController]
  /// bound to the [AppState] from the widget tree.
  final ChatController? controller;

  @override
  State<ChatbotScreen> createState() => _ChatbotScreenState();
}

class _ChatbotScreenState extends State<ChatbotScreen> {
  late final ChatController _controller;
  late final TextEditingController _input;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _input = TextEditingController();
    final appState = context.read<AppState>();
    _controller = widget.controller ??
        ChatController(
          appState: appState,
          provider: widget.provider ??
              GeminiChatProvider(logger: appState.logger),
        );
    _controller.addListener(_onControllerChanged);
    _controller.loadHistory();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // Keep the newest message visible after a send/reply.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (widget.controller == null) _controller.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await _controller.send(text);
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat history?'),
        content: const Text(
          'This deletes all saved chat messages for your account. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _controller.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final configured = controller.isConfigured;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Assistant'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear chat history',
            onPressed: controller.messages.isEmpty
                ? null
                : _confirmClearHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          if (!configured) _notConfiguredCard(context),
          Expanded(
            child: controller.isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : controller.messages.isEmpty
                    ? _emptyState(configured)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: controller.messages.length +
                            (controller.isSending ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == controller.messages.length) {
                            return const _TypingBubble();
                          }
                          return _MessageBubble(
                            message: controller.messages[index],
                          );
                        },
                      ),
          ),
          if (controller.errorMessage != null)
            _errorBanner(controller),
          _inputRow(configured, controller),
        ],
      ),
    );
  }

  Widget _emptyState(bool configured) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 48),
        Icon(
          Icons.chat_bubble_outline,
          size: 64,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          configured
              ? 'Ask about your household spending'
              : 'The assistant is ready when a key is added',
          textAlign: TextAlign.center,
          style: SplitNestTheme.sectionStyle,
        ),
        const SizedBox(height: 8),
        const Text(
          'Try "How much have we spent this month?", '
          '"Who owes whom?" or "What did we spend on groceries?" '
          'Answers come from your real household data — the '
          'assistant never invents figures.',
          textAlign: TextAlign.center,
          style: SplitNestTheme.supportingStyle,
        ),
      ],
    );
  }

  /// The not-configured card: the real state of this build. No key
  /// was supplied, so the chat is disabled and nothing is sent
  /// anywhere. The card gives the exact setup steps instead of
  /// pretending the AI works.
  Widget _notConfiguredCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'AI not configured',
                    style: SplitNestTheme.sectionStyle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'The SplitNest assistant needs a Google Gemini API key. '
              'No key is set in this build, so chatting is disabled '
              'and nothing is sent anywhere.',
              style: SplitNestTheme.supportingStyle,
            ),
            const SizedBox(height: 12),
            const Text(
              'To enable it:',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              '1. Get a free key at Google AI Studio '
              '(aistudio.google.com/apikey).\n'
              '2. Run or build with the key:\n'
              '   flutter run '
              '--dart-define=GEMINI_API_KEY=YOUR_KEY\n'
              '3. In CI, add GEMINI_API_KEY as a GitHub Actions '
              'secret and pass the same --dart-define flag in the '
              'build step.',
              style: SplitNestTheme.supportingStyle,
            ),
            const SizedBox(height: 8),
            const Text(
              'The key is never stored in the app, in lock.json, or '
              'in any file in this repo.',
              style: SplitNestTheme.supportingStyle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner(ChatController controller) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              controller.errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: controller.isSending ? null : controller.retry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _inputRow(bool configured, ChatController controller) {
    final sending = controller.isSending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                enabled: configured && !sending,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: configured
                      ? 'Ask about your spending…'
                      : 'AI not configured — add a Gemini key to chat',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.send),
              tooltip: 'Send',
              // Disabled when not configured, while sending, or
              // while the field is empty — empty messages are
              // rejected by the controller too.
              onPressed: !configured ||
                      sending ||
                      _input.text.trim().isEmpty
                  ? null
                  : _send,
            ),
          ],
        ),
      ),
    );
  }
}

/// One chat message bubble: user messages right-aligned on the
/// primary colour, assistant replies left-aligned on the card
/// colour, each with an HH:mm timestamp underneath.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final bubbleColor = isUser
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final textColor = isUser
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message.text, style: TextStyle(color: textColor)),
              const SizedBox(height: 4),
              Text(
                formatChatTime(message.timestamp),
                style: TextStyle(
                  fontSize: 11,
                  color: textColor.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown at the bottom of the list while a reply is awaited.
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('Thinking…'),
          ],
        ),
      ),
    );
  }
}
