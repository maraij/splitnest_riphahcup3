import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../core/widgets/error_banner.dart';
import '../../state/app_state.dart';
import 'auth_validation.dart';

/// Forgot-password screen: one email field, one send. The success
/// text deliberately does not reveal whether the address has an
/// account — Firebase may not either (email-enumeration protection).
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _email = TextEditingController();
  String? _formError;
  bool _sent = false;
  bool _sending = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(SplitNestTheme.screenPadding),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Reset your password',
                    style: SplitNestTheme.titleStyle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Enter the email you signed up with and we will send '
                    'a password-reset link.',
                    style: SplitNestTheme.supportingStyle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (state.errorMessage != null) ...[
                    ErrorBanner(
                      message: state.errorMessage!,
                      onDismiss: state.clearError,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_formError != null) ...[
                    ErrorBanner(
                      message: _formError!,
                      onDismiss: () => setState(() => _formError = null),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_sent)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'If an account exists for that email, a '
                          'password-reset link has been sent. Check your '
                          'inbox (and spam folder).',
                          style: SplitNestTheme.supportingStyle,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else ...[
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      onSubmitted: (_) => _submit(state),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: (_sending || state.isBusy)
                            ? null
                            : () => _submit(state),
                        icon: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.mail_outline),
                        label: Text(
                            _sending ? 'Sending…' : 'Send reset link'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back to sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit(AppState state) async {
    final error = validateEmail(_email.text);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    setState(() {
      _formError = null;
      _sending = true;
    });
    final ok =
        await state.sendFirebasePasswordReset(_email.text.trim());
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sent = ok;
    });
  }
}
