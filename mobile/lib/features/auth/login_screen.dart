import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/demo_accounts.dart';
import '../../state/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/member_avatar.dart';
import 'auth_validation.dart';
import 'forgot_password_screen.dart';
import 'signup_screen.dart';

/// Login page — two ways in, one household (all local-only; there is
/// no member-password login, no third-party sign-in and no backend
/// session any more — Phase 6 dropped the cloud backend):
///
/// 1. Email + password (local accounts in lock.json, "Sign in with
///    email instead"): the account signs in directly — there is no
///    email verification, because there is no mail backend. New
///    users sign up from here.
/// 2. Demo: the Demo button opens a popup (names + IDs only, no
///    passwords) and signs the demo user in locally with the seeded
///    demo account — no network, no cloud account.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// Email mode (local auth): email + password sign-in, with links
  /// to sign-up and forgot-password. Off by default.
  bool _useEmail = false;
  final _email = TextEditingController();
  final _emailPassword = TextEditingController();
  bool _obscureEmailPassword = true;
  String? _emailFormError;

  @override
  void dispose() {
    _email.dispose();
    _emailPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(SplitNestTheme.screenPadding),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Animated shared-home illustration above the logo.
                  // Kept compact so the Log in button stays above the
                  // fold on short phone screens.
                  const Center(child: NestIllustration(size: 64)),
                  const SizedBox(height: 8),
                  // Logo entrance: gentle fade + scale-in (whole logo —
                  // the v2 nest lines and coins are baked into the
                  // image, so they animate as one mark, honestly).
                  Center(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: animationsDisabled(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      builder: (context, t, child) => Opacity(
                        opacity: t,
                        child: Transform.scale(
                          scale: 0.94 + 0.06 * t,
                          child: child,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.asset(
                          'assets/splitnest-logo-v3.webp',
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Log in',
                    style: SplitNestTheme.titleStyle.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Welcome to SplitNest',
                    style: SplitNestTheme.supportingStyle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (state.errorMessage != null) ...[
                    ErrorBanner(
                      message: state.errorMessage!,
                      onDismiss: state.clearError,
                      onRetry: state.refresh,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_useEmail) ...[
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
                      controller: _emailPassword,
                      obscureText: _obscureEmailPassword,
                      enableSuggestions: false,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureEmailPassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          tooltip: _obscureEmailPassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () => setState(() =>
                              _obscureEmailPassword =
                                  !_obscureEmailPassword),
                        ),
                      ),
                      onSubmitted: (_) => _submitEmail(state),
                    ),
                    if (_emailFormError != null) ...[
                      const SizedBox(height: 12),
                      ErrorBanner(
                        message: _emailFormError!,
                        onDismiss: () =>
                            setState(() => _emailFormError = null),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: state.isBusy
                            ? null
                            : () => _submitEmail(state),
                        icon: state.isBusy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.login),
                        label: Text(
                            state.isBusy ? 'Signing in…' : 'Sign in'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Wrap, not Row: the two links overflow a narrow
                    // phone (and the wide Ahem test font) side by
                    // side, so they stack instead.
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SignUpScreen(),
                            ),
                          ),
                          child: const Text('Create an account'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ForgotPasswordScreen(),
                            ),
                          ),
                          child: const Text('Forgot password?'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() {
                      _useEmail = !_useEmail;
                      _emailFormError = null;
                      state.clearError();
                    }),
                    child: Text(_useEmail
                        ? 'Back to member sign-in'
                        : 'Sign in with email instead'),
                  ),
                  const SizedBox(height: 20),
                  // ONE Demo button: it opens a popup with the three demo
                  // accounts inside. Each account signs in locally with
                  // the seeded demo account — no network, no cloud
                  // account, no bypass around auth.
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: state.isBusy
                          ? null
                          : () => _showDemoAccounts(context, state),
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Demo'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Practice build · Data stays on this device',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Email sign-in against the local accounts in lock.json.
  /// Validation errors are local; auth errors arrive via
  /// AppState.errorMessage. On success the AuthGate routes
  /// automatically (Home) — there is nothing to navigate to here.
  Future<void> _submitEmail(AppState state) async {
    final error = validateEmail(_email.text) ??
        validatePassword(_emailPassword.text);
    if (error != null) {
      setState(() => _emailFormError = error);
      return;
    }
    setState(() => _emailFormError = null);
    final ok = await state.signInWithEmail(
      email: _email.text.trim(),
      password: _emailPassword.text,
    );
    if (ok && mounted) _emailPassword.clear();
  }

  /// Demo accounts popup: the three demo accounts live ONLY here
  /// (names + IDs only — no passwords are shown). Tapping one signs
  /// the demo user in locally via AppState.loginWithDemo. There is
  /// no bypass around auth.
  Future<void> _showDemoAccounts(
      BuildContext context, AppState state) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(SplitNestTheme.cardRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Demo accounts',
                style: SplitNestTheme.titleStyle,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ...demoAccounts.map((d) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: state.isBusy
                            ? null
                            : () {
                                Navigator.of(dialogCtx).pop();
                                state.loginWithDemo(memberId: d.memberId);
                              },
                        icon: MemberAvatar(
                          memberId: d.memberId,
                          name: d.name,
                          radius: 13,
                        ),
                        label: Text('${d.name} • ${d.memberId}'),
                      ),
                    ),
                  )),
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
