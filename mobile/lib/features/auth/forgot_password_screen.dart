import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../core/widgets/error_banner.dart';
import '../../state/app_state.dart';
import 'auth_validation.dart';

/// Forgot-password screen — device-local reset, in two steps.
///
/// There is NO email backend, so NO email is ever sent. Instead:
/// 1. Enter the email → the app shows a 6-digit reset code ON THIS
///    DEVICE (valid 15 minutes, single-use).
/// 2. Enter that code + a new password → the password is replaced
///    (new salt + hash) and the user is signed in.
///
/// The honesty note is shown in the UI, not buried in docs:
/// anyone holding this device can reset the password, because the
/// code is displayed on the device itself. That is the limit of a
/// single-device practice app with no mail backend — it is stated
/// plainly rather than pretending an email went out.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscureNewPassword = true;
  bool _obscureConfirm = true;
  String? _formError;
  String? _issuedCode;
  bool _requesting = false;
  bool _resetting = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _newPassword.dispose();
    _confirm.dispose();
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
                    'No email is sent — there is no mail backend. '
                    'Enter your email and the app will show a reset '
                    'code on this device instead.',
                    style: SplitNestTheme.supportingStyle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Anyone holding this device can reset the password '
                    'this way. This is a practice app with local-only '
                    'accounts — keep the device to yourself.',
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
                  if (_issuedCode == null) ...[
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      onSubmitted: (_) => _requestCode(state),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: (_requesting || state.isBusy)
                            ? null
                            : () => _requestCode(state),
                        icon: _requesting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.key_outlined),
                        label: Text(
                            _requesting ? 'Getting code…' : 'Show reset code'),
                      ),
                    ),
                  ] else ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Text(
                              'Your reset code (on this device only):',
                              style: SplitNestTheme.supportingStyle,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              _issuedCode!,
                              style: SplitNestTheme.titleStyle,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Valid for 15 minutes, single-use. '
                              'Enter it below with a new password.',
                              style: SplitNestTheme.supportingStyle,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Reset code',
                        prefixIcon: Icon(Icons.pin_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _newPassword,
                      obscureText: _obscureNewPassword,
                      enableSuggestions: false,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'New password',
                        helperText: passwordRuleText,
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureNewPassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          tooltip: _obscureNewPassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () => setState(() =>
                              _obscureNewPassword = !_obscureNewPassword),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: _obscureConfirm,
                      enableSuggestions: false,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: 'Confirm new password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureConfirm
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          tooltip: _obscureConfirm
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () => setState(() =>
                              _obscureConfirm = !_obscureConfirm),
                        ),
                      ),
                      onSubmitted: (_) => _resetPassword(state),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: (_resetting || state.isBusy)
                            ? null
                            : () => _resetPassword(state),
                        icon: _resetting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.lock_reset_outlined),
                        label: Text(_resetting
                            ? 'Resetting…'
                            : 'Reset password'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() {
                        _issuedCode = null;
                        _code.clear();
                        _formError = null;
                        state.clearError();
                      }),
                      child: const Text('Start over with another email'),
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

  Future<void> _requestCode(AppState state) async {
    final error = validateEmail(_email.text);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    setState(() {
      _formError = null;
      _requesting = true;
    });
    final code =
        await state.requestPasswordReset(_email.text.trim());
    if (!mounted) return;
    setState(() {
      _requesting = false;
      _issuedCode = code;
    });
  }

  Future<void> _resetPassword(AppState state) async {
    final error = _code.text.trim().isEmpty
        ? 'Enter the reset code shown above.'
        : validatePassword(_newPassword.text) ??
            validateConfirmPassword(_newPassword.text, _confirm.text);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    setState(() {
      _formError = null;
      _resetting = true;
    });
    final ok = await state.resetPasswordWithCode(
      email: _email.text.trim(),
      code: _code.text.trim(),
      newPassword: _newPassword.text,
    );
    if (!mounted) return;
    setState(() => _resetting = false);
    // On success the user is signed in with the new password and
    // the AuthGate shows Home; this pushed route pops away.
    if (ok) Navigator.of(context).pop();
  }
}
