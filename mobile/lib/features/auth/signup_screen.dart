import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/member_avatar.dart';
import '../../state/app_state.dart';
import 'auth_validation.dart';

/// Email/password sign-up with Firebase Auth.
///
/// The user picks which household member they are, a name, an email
/// and a password (at least 6 characters, shown as a rule before
/// typing). On submit the account is created, a verification email
/// is sent, and the app routes to the verification screen — the
/// AuthGate blocks app access until the email is verified. All
/// validation errors are local; Firebase errors arrive via
/// AppState.errorMessage and are already plain text.
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  String? _selectedMemberId;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _formError;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final options = state.memberOptions;
    return Scaffold(
      appBar: AppBar(title: const Text('Create an account')),
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
                    'Create your SplitNest account',
                    style: SplitNestTheme.titleStyle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'We will send a verification email. '
                    'You can use the app once your email is verified.',
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
                  const Text(
                    'Which roommate are you?',
                    style: SplitNestTheme.sectionStyle,
                  ),
                  const SizedBox(height: 8),
                  ...options.map((m) {
                    final selected = _selectedMemberId == m.id;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        color: selected
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.08)
                            : null,
                        shape: selected
                            ? RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                    SplitNestTheme.cardRadius),
                                side: BorderSide(
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                  width: 2,
                                ),
                              )
                            : null,
                        child: ListTile(
                          leading: MemberAvatar(
                            memberId: m.id,
                            name: m.name,
                            radius: 24,
                          ),
                          title: Text(m.name),
                          subtitle: Text('${m.id} · Roommate'),
                          trailing: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                          onTap: () => setState(() {
                            _selectedMemberId = m.id;
                            _formError = null;
                          }),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Your name',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: _obscurePassword,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: passwordRuleText,
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        tooltip: _obscurePassword
                            ? 'Show password'
                            : 'Hide password',
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
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
                      labelText: 'Confirm password',
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
                        onPressed: () => setState(
                            () => _obscureConfirm = !_obscureConfirm),
                      ),
                    ),
                    onSubmitted: (_) => _submit(state),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed:
                          state.isBusy ? null : () => _submit(state),
                      icon: state.isBusy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.person_add_outlined),
                      label: Text(
                          state.isBusy ? 'Creating account…' : 'Create account'),
                    ),
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
    final error = _selectedMemberId == null
        ? 'Choose which roommate you are.'
        : validateDisplayName(_name.text) ??
            validateEmail(_email.text) ??
            validatePassword(_password.text) ??
            validateConfirmPassword(_password.text, _confirm.text);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    setState(() => _formError = null);
    final ok = await state.signUpWithFirebaseEmail(
      displayName: _name.text.trim(),
      email: _email.text.trim(),
      password: _password.text,
      memberId: _selectedMemberId!,
    );
    // On success the AuthGate shows the verification screen; this
    // pushed route just pops away. On failure the error banner
    // above already shows the plain Firebase message.
    if (ok && mounted) Navigator.of(context).pop();
  }
}
