import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../core/widgets/error_banner.dart';
import '../../state/app_state.dart';

/// Email-verification gate screen. Shown by the AuthGate (see
/// main.dart) whenever a Firebase user is signed in but their email
/// is not verified yet — demo accounts never land here (they bypass
/// the gate) and Google users never land here (Google arrives
/// verified).
///
/// The user verifies by clicking the link in their email, then taps
/// "I've verified — check again", which reloads the Firebase user:
/// verified → the saved member link is applied and Home opens.
/// "Resend" sends another verification email. "Use a different
/// account" signs out back to the login screen.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  String? _notice;
  bool _checking = false;
  bool _resending = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final email = state.firebaseSession?.email;
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
                  const Icon(Icons.mark_email_unread_outlined, size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'Verify your email',
                    style: SplitNestTheme.titleStyle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    email == null
                        ? 'We sent a verification link to your email. '
                            'Click it, then check again below.'
                        : 'We sent a verification link to $email. '
                            'Click it, then check again below.',
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
                  if (_notice != null) ...[
                    ErrorBanner(
                      message: _notice!,
                      onDismiss: () => setState(() => _notice = null),
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _checking
                          ? null
                          : () => _checkVerified(state),
                      icon: _checking
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: Text(_checking
                          ? 'Checking…'
                          : 'I’ve verified — check again'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _resending
                          ? null
                          : () => _resend(state),
                      icon: const Icon(Icons.mail_outline),
                      label: Text(
                          _resending ? 'Sending…' : 'Resend verification email'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => state.logout(),
                    child: const Text('Use a different account'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _checkVerified(AppState state) async {
    setState(() {
      _checking = true;
      _notice = null;
    });
    final verified = await state.refreshVerificationStatus();
    if (!mounted) return;
    setState(() {
      _checking = false;
      // Verified + member linked: the AuthGate already moved on to
      // Home, so this text only shows when the email is still
      // unverified (or no member link yet, in which case the login
      // screen's member pick is next).
      if (!verified) {
        _notice = 'Not verified yet. Click the link in your email, '
            'then check again — also check your spam folder.';
      }
    });
  }

  Future<void> _resend(AppState state) async {
    setState(() {
      _resending = true;
      _notice = null;
    });
    final sent = await state.resendVerificationEmail();
    if (!mounted) return;
    setState(() {
      _resending = false;
      if (sent) _notice = 'Verification email sent. Check your inbox.';
    });
  }
}
