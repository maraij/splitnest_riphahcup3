import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../data/firebase_auth_service.dart';
import '../../data/google_auth_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/member_avatar.dart';
import 'auth_validation.dart';
import 'forgot_password_screen.dart';
import 'signup_screen.dart';

/// Login page — three ways in, one household (all Firebase Auth;
/// there is no member-password login and no backend session any
/// more — Phase 3 retired the Node backend):
///
/// 1. Email + password (Firebase Auth, "Sign in with email instead"):
///    verified users enter Home; unverified users go to the
///    verification screen; new users sign up from here. Hidden when
///    Firebase auth is not wired in.
/// 2. Google: the account chooser runs on the device, Firebase signs
///    in with the Google credential, then the user picks which member
///    that Google account is, and the store links the member and
///    loads the Firestore household.
/// 3. Demo: the Demo button opens a popup (names + IDs only, no
///    passwords) and signs the demo user in through Firebase Auth
///    (create on first use) — or a local demo identity when Firebase
///    is not wired in (tests / init failed).
///
/// A Firebase user who is signed in but has no member linked yet
/// picks a member from the card at the top of this page.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _googleBusy = false;

  /// Email mode (Firebase Auth): email + password sign-in, with
  /// links to sign-up and forgot-password. Off by default, and hidden
  /// entirely when Firebase auth is not wired in (Firebase init
  /// failed / tests).
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
                  // A Firebase user signed in (verified) but with no
                  // household member linked yet — e.g. they signed in
                  // on this device before picking, or cancelled the
                  // pick. They choose a member here instead of
                  // signing in again.
                  if (state.firebaseAuthEnabled &&
                      state.firebaseSession != null &&
                      state.firebaseStatus ==
                          FirebaseAuthStatus.signedIn &&
                      !state.isLoggedIn) ...[
                    _FirebaseSessionCard(
                      email: state.firebaseSession!.email,
                      onPickMember: (memberId) =>
                          state.completeFirebaseMemberPick(memberId),
                      onSignOut: () => state.logout(),
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
                  ] else ...[
                    // No member-password form any more (Phase 3
                    // retired the backend login): sign in with email,
                    // Google, or Demo below.
                    if (!state.firebaseAuthEnabled)
                      const Text(
                        'Sign in with Google or try the Demo account '
                        'below. Email sign-in needs Firebase, which is '
                        'not available right now.',
                        style: SplitNestTheme.supportingStyle,
                        textAlign: TextAlign.center,
                      ),
                  ],
                  if (state.firebaseAuthEnabled) ...[
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
                  ],
                  const SizedBox(height: 20),
                  // "Continue with Google" sits BELOW the sign-in
                  // options (user request, 2026-11-05): a full-width
                  // dark pill, like the reference screenshot — black
                  // background, thin light border, fully rounded ends,
                  // Google "G" logo, white text. It runs the REAL
                  // Google sign-in (account chooser / Gmail + password
                  // on the device), then asks which member this Google
                  // account is, then links that member and loads the
                  // Firestore household.
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
                    onPressed: (state.isBusy || _googleBusy)
                        ? null
                        : () => _signInWithGoogle(state),
                  ),
                  const SizedBox(height: 20),
                  // ONE Demo button: it opens a popup with the three demo
                  // accounts inside. Each account signs in through
                  // Firebase Auth (create on first use) — not a bypass
                  // around auth.
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

  /// Email sign-in via Firebase Auth. Validation errors are local;
  /// Firebase errors arrive via AppState.errorMessage. On success
  /// the AuthGate routes automatically (verification screen, member
  /// pick, or Home) — there is nothing to navigate to here.
  Future<void> _submitEmail(AppState state) async {
    final error = validateEmail(_email.text) ??
        validatePassword(_emailPassword.text);
    if (error != null) {
      setState(() => _emailFormError = error);
      return;
    }
    setState(() => _emailFormError = null);
    final ok = await state.signInWithFirebaseEmail(
      email: _email.text.trim(),
      password: _emailPassword.text,
    );
    if (ok && mounted) _emailPassword.clear();
  }

  /// REAL Google sign-in: the account chooser / Gmail + password flow
  /// runs on the device, Firebase signs in with the Google credential
  /// (inside RealGoogleAuthService), then this screen asks which
  /// SplitNest member that Google account belongs to — then the store
  /// links that member and loads the Firestore household. A cancelled
  /// chooser or any failure stays on this page with a clear message.
  /// There is no fake session anywhere in this flow.
  Future<void> _signInWithGoogle(AppState state) async {
    if (_googleBusy || state.isBusy) return;
    setState(() => _googleBusy = true);
    try {
      final result = await state.googleAuth.signIn();
      if (!mounted) return;
      switch (result) {
        case GoogleSignedIn(:final idToken, :final email):
          // Pick up the Firebase user the Google service just signed
          // in, then reuse a saved member link when one exists.
          if (state.firebaseAuthEnabled) state.syncFirebaseSession();
          final savedMemberId = await state.firebaseMemberId();
          final memberId =
              savedMemberId ?? await _pickGoogleMember(email);
          if (memberId == null || !mounted) return;
          final ok = await state.loginWithGoogle(
            idToken: idToken,
            memberId: memberId,
          );
          if (ok) {
            await state.saveFirebaseMember(memberId);
          }
        case GoogleSignInCancelled():
          state.showError('Google sign-in was cancelled.');
        case GoogleSignInFailed(:final message):
          state.showError(message);
      }
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  /// After Google signs in, the user picks which SplitNest member
  /// this Google account is. Returns the member id, or null when the
  /// user backs out (then nothing is logged in).
  Future<String?> _pickGoogleMember(String googleEmail) {
    // memberOptions falls back to the three seeded household members
    // when the roster has not loaded yet.
    final members = context.read<AppState>().memberOptions;
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(SplitNestTheme.cardRadius),
        ),
        title: const Text('Choose your account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Signed in with Google as $googleEmail. '
              'Which SplitNest member is this?',
              style: SplitNestTheme.supportingStyle,
            ),
            const SizedBox(height: 12),
            ...members.map((m) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(dialogCtx).pop(m.id),
                      icon: MemberAvatar(
                        memberId: m.id,
                        name: m.name,
                        radius: 13,
                      ),
                      label: Text('${m.name} • ${m.id}'),
                    ),
                  ),
                )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// Demo accounts popup: the three demo accounts live ONLY here
  /// (names + IDs only — no passwords are shown). Tapping one signs
  /// the demo user in through Firebase Auth (create on first use),
  /// via AppState.loginWithDemo. Without Firebase wired in, the same
  /// tap uses a local demo identity. There is no bypass around auth
  /// either way.
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

/// Card shown when a Firebase user is signed in (verified) but has
/// no household member linked yet: pick a member to enter the app,
/// or sign out to use a different account.
class _FirebaseSessionCard extends StatelessWidget {
  const _FirebaseSessionCard({
    required this.email,
    required this.onPickMember,
    required this.onSignOut,
  });

  final String? email;
  final ValueChanged<String> onPickMember;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              email == null
                  ? 'Signed in — which roommate are you?'
                  : 'Signed in as $email — which roommate are you?',
              style: SplitNestTheme.sectionStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ...state.memberOptions.map((m) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => onPickMember(m.id),
                      icon: MemberAvatar(
                        memberId: m.id,
                        name: m.name,
                        radius: 13,
                      ),
                      label: Text('${m.name} • ${m.id}'),
                    ),
                  ),
                )),
            TextButton(
              onPressed: onSignOut,
              child: const Text('Not you? Sign out'),
            ),
          ],
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

  final VoidCallback? onPressed;

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
