import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/member_avatar.dart';

/// Real login — member + password, checked by POST /api/auth/login.
/// Pick a member card to select it, enter the password, tap Log in.
/// On a wrong password the backend returns 401, the store surfaces
/// "Wrong password, try again", and the user stays on this page.
/// On success the store holds the session token and Home opens.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? _selectedId;
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final canSubmit = _selectedId != null &&
        _password.text.isNotEmpty &&
        !state.isBusy;
    return Scaffold(
      backgroundColor: Colors.white,
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
                          'assets/splitnest-logo-v2.webp',
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Welcome to SplitNest',
                    style: SplitNestTheme.titleStyle.copyWith(
                      color: SplitNestTheme.ink,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Choose who you are to continue.',
                    style: SplitNestTheme.supportingStyle.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
                  if (state.isLoading && state.members.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (state.members.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Could not load members. Check the backend is running, then pull to refresh.',
                          style: SplitNestTheme.supportingStyle,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    ...state.members.map((m) {
                      final selected = _selectedId == m.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
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
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            leading: MemberAvatar(
                              memberId: m.id,
                              name: m.name,
                              radius: 24,
                            ),
                            title: Text(
                              m.name,
                              style: SplitNestTheme.sectionStyle,
                            ),
                            subtitle: Text(
                              '${m.id} · Roommate',
                              style: SplitNestTheme.supportingStyle,
                            ),
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
                            onTap: () {
                              setState(() {
                                _selectedId = m.id;
                                state.clearError();
                              });
                            },
                          ),
                        ),
                      );
                    }),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      hintText: 'Enter your member password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        tooltip:
                            _obscure ? 'Show password' : 'Hide password',
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (canSubmit) _submit(state);
                    },
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: canSubmit ? () => _submit(state) : null,
                      icon: state.isBusy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label:
                          Text(state.isBusy ? 'Logging in…' : 'Log in'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ONE Demo button: it opens a popup with the three demo
                  // accounts inside. Each account logs in through the
                  // REAL POST /api/auth/login (bcrypt check) — not a
                  // bypass around auth.
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
                    'Practice build',
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

  Future<void> _submit(AppState state) async {
    final id = _selectedId;
    if (id == null) return;
    final ok = await state.loginWithPassword(
      memberId: id,
      password: _password.text,
    );
    if (ok && mounted) _password.clear();
  }

  /// Demo accounts popup: the three demo accounts live ONLY here.
  /// Tapping one logs in through the real password login; on success
  /// the popup closes and Home opens (with the welcome popup).
  Future<void> _showDemoAccounts(
      BuildContext context, AppState state) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => Dialog(
        backgroundColor: Colors.white,
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
              const SizedBox(height: 8),
              const Text(
                'Tap one to log in instantly with that member’s demo account.',
                style: SplitNestTheme.supportingStyle,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ..._demoAccounts.map((d) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: state.isBusy
                            ? null
                            : () async {
                                final ok =
                                    await state.loginWithPassword(
                                  memberId: d.id,
                                  password: d.password,
                                );
                                if (dialogCtx.mounted) {
                                  Navigator.of(dialogCtx).pop();
                                }
                                if (ok && mounted) _password.clear();
                              },
                        icon: MemberAvatar(
                          memberId: d.id,
                          name: d.name,
                          radius: 13,
                        ),
                        label: Text('${d.name} • ${d.id}'),
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

/// Demo accounts (practice build only). The passwords are the backend's
/// seeded demo passwords — see README.md. Change them before any real use.
const _demoAccounts = [
  (id: 'M01', name: 'Ali', password: 'ali123'),
  (id: 'M02', name: 'Ayesha', password: 'ayesha123'),
  (id: 'M03', name: 'Bilal', password: 'bilal123'),
];
