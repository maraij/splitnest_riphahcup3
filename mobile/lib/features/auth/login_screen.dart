import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/member_avatar.dart';

/// Real login — member + password, checked by POST /api/auth/login.
/// The form state (_selectedId + _password) is the ONLY input to the
/// login call: the Log in button and the Demo popup both fill this
/// form and run the same _submit. On a wrong password the backend
/// returns 401, the store surfaces "Wrong password, try again", and
/// the user stays on this page. On success the store holds the
/// session token and Home opens.
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
                    'Welcome to SplitNest',
                    style: SplitNestTheme.titleStyle.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
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
                          'Could not load members.',
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
                  // "Continue with Google" sits BELOW the member
                  // accounts (user request, 2026-11-05): a full-width
                  // dark pill, like the reference screenshot — black
                  // background, thin light border, fully rounded ends,
                  // Google "G" logo, white text. It does NOT sign in:
                  // Google sign-in needs Firebase Auth, which is not
                  // wired in this practice build, so the tap opens an
                  // honest popup and offers the member login instead.
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'or',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _GoogleSignInButton(
                    onPressed: () => _showGoogleInfo(context),
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

  /// Google sign-in is NOT wired in this practice build (it needs a
  /// Firebase project, google-services.json and an Android SHA-1), so
  /// the button never pretends to sign in: it opens this popup and
  /// offers the member login instead. No state changes, no fake
  /// session.
  Future<void> _showGoogleInfo(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(SplitNestTheme.cardRadius),
        ),
        title: const Text('Continue with Google'),
        content: const Text(
          'Google sign-in isn\'t connected in this practice build yet — '
          'it needs Firebase Auth set up first. Please sign in with '
          'your member account and password instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Use member login'),
          ),
        ],
      ),
    );
  }

  /// Demo accounts popup: the three demo accounts live ONLY here.
  /// Tapping one FILLS this login form (member + password) and runs
  /// the SAME submit as the Log in button — the same
  /// loginWithPassword -> POST /api/auth/login password check, the
  /// same 401 handling, the same token storage. There is no second
  /// login path: the demo button never logs in on its own.
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
              ..._demoAccounts.map((d) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: state.isBusy
                            ? null
                            : () {
                                // Fill the form, close the popup, then
                                // submit exactly like the Log in button.
                                Navigator.of(dialogCtx).pop();
                                setState(() {
                                  _selectedId = d.id;
                                  _password.text = d.password;
                                });
                                _submit(state);
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

/// "Continue with Google" — a full-width dark pill, exactly like the
/// reference screenshot: black background, thin light border, fully
/// rounded ends, the Google "G" logo on the left, white text, 56px
/// tall. The colours are FIXED (not theme-derived) so the button
/// looks the same in light and dark mode.
class _GoogleSignInButton extends StatelessWidget {
  const _GoogleSignInButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF000000),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF000000),
          elevation: 0,
          shadowColor: Colors.transparent,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: const BorderSide(color: Color(0xFF9E9E9E), width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        // scaleDown: on very narrow phones the label shrinks instead
        // of overflowing (widget tests measure text with the wide
        // Ahem test font, where the label is ~320px on its own).
        child: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _GoogleGIcon(size: 20),
              SizedBox(width: 12),
              Text(
                'Continue with Google',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Google "G" logo, drawn with the four brand colours: red
/// upper-right, green lower-right, blue bottom + left + top, yellow
/// lower-left, and the blue bar across the middle. Drawn, not an
/// asset, so no new dependency or image file is needed.
class _GoogleGIcon extends StatelessWidget {
  const _GoogleGIcon({this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  static const _red = Color(0xFFEA4335);
  static const _green = Color(0xFF34A853);
  static const _blue = Color(0xFF4285F4);
  static const _yellow = Color(0xFFFBBC05);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width / 5;
    final radius = size.width / 2 - stroke / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    // Angles in radians, 0 = east, clockwise positive. The five arcs
    // close the circle: red upper-right, green lower-right, blue
    // bottom, yellow lower-left, blue left + top.
    canvas.drawArc(rect, -1.05, 1.05, false, arc(_red));
    canvas.drawArc(rect, 0, 0.87, false, arc(_green));
    canvas.drawArc(rect, 0.87, 1.22, false, arc(_blue));
    canvas.drawArc(rect, 2.09, 0.87, false, arc(_yellow));
    canvas.drawArc(rect, 2.96, 2.27, false, arc(_blue));
    // The bar: blue, from the centre to the circle's right edge.
    canvas.drawRect(
      Rect.fromLTWH(
          center.dx, center.dy - stroke / 2, radius + stroke / 2, stroke),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Demo accounts (practice build only). The passwords are the backend's
/// seeded demo passwords — see README.md. Change them before any real use.
const _demoAccounts = [
  (id: 'M01', name: 'Ali', password: 'ali123'),
  (id: 'M02', name: 'Ayesha', password: 'ayesha123'),
  (id: 'M03', name: 'Bilal', password: 'bilal123'),
];
