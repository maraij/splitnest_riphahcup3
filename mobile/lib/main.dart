import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/firebase_auth_service.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/verification_screen.dart';
import 'features/expenses/expenses_screen.dart';
import 'features/home/home_screen.dart';
import 'features/monthly/monthly_view_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/settle/settle_screen.dart';
import 'features/shopping/shopping_screen.dart';
import 'features/splash/splash_screen.dart';
import 'features/timeline/timeline_screen.dart';
import 'state/app_state.dart';
import 'core/theme.dart';
import 'core/widgets/entrance.dart';

/// SplitNest — practice-only shared-living expense app.
/// PRACTICE ONLY — NOT FOR SUBMISSION.
/// Flow: Splash (logo, auto-advances after ~2.5s, no tap) →
/// AuthGate: Firebase auth state decides — signed-out → login,
/// signed-in but email-unverified → verification screen,
/// signed-in + verified (or demo) → Home as the linked member.
/// Member + password login (POST /api/auth/login, Bearer token) and
/// the Demo button still work; email sign-up/sign-in and Google
/// sign-in go through Firebase Auth (Phase 2). Log out returns to
/// the login page; Home is unreachable without logging in. Tabs:
/// Home, Shopping, Expenses, Settle Up. Drawer: the same four tabs
/// plus Monthly view, Timeline and Profile.
/// Theme: light (Hisaab Kitaab teal) or dark (Coolors plum palette),
/// one shared AppState flag; toggled from the AppBar or the drawer,
/// persisted in SharedPreferences and applied before first paint.
/// Phase 1 (Foundation): Firebase is initialised here, but the app does
/// NOT depend on it yet — every screen still talks to the Node backend
/// exactly as before. If initialisation fails (no Firestore database
/// yet, no network, no native config for this platform — e.g. web has
/// no FirebaseOptions until a web app is registered), the app still
/// launches and shows a clear, dismissible error banner instead of
/// crashing. Nothing else reads Firebase in this phase.
/// Phase 2 (Auth): when Firebase initialised, AppState gets a
/// RealFirebaseAuthService and the AuthGate above is live. When it
/// did not initialise, AppState runs backend-only (member login,
/// demo, Google via the backend) exactly as in Phase 1.
Future<({bool ready, String? error})> _initFirebase() async {
  try {
    // No options: Android/iOS read google-services.json /
    // GoogleService-Info.plist. Web has no options yet, so this throws
    // there until a web app is registered (see docs/FIREBASE_SETUP.md).
    await Firebase.initializeApp();
    return (ready: true, error: null);
  } catch (e) {
    return (ready: false, error: e.toString());
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var initialDark = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    initialDark = prefs.getString('theme_mode') == 'dark';
  } catch (_) {
    // Storage unavailable: start light; the toggle still works.
  }
  final firebase = await _initFirebase();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(
        initialDarkMode: initialDark,
        // Only wire real Firebase Auth when initialisation
        // succeeded; otherwise the app runs backend-only and the
        // login screen hides the email mode.
        firebaseAuth:
            firebase.ready ? RealFirebaseAuthService() : null,
      )..refresh(),
      child: SplitNestApp(
        firebaseReady: firebase.ready,
        firebaseError: firebase.error,
      ),
    ),
  );
}

class SplitNestApp extends StatefulWidget {
  const SplitNestApp({
    super.key,
    this.firebaseReady = true,
    this.firebaseError,
  });

  /// True when Firebase.initializeApp() succeeded. False means the app
  /// is running on the Node backend only (see the banner in build).
  final bool firebaseReady;

  /// Human-readable init failure, null when [firebaseReady] is true.
  final String? firebaseError;

  @override
  State<SplitNestApp> createState() => _SplitNestAppState();
}

class _SplitNestAppState extends State<SplitNestApp> {
  int _index = 0;
  bool _showSplash = true;
  late bool _firebaseReady;
  late String? _firebaseError;
  bool _bannerDismissed = false;

  static const titles = ['SplitNest', 'Shopping', 'Expenses', 'Settle Up'];

  @override
  void initState() {
    super.initState();
    _firebaseReady = widget.firebaseReady;
    _firebaseError = widget.firebaseError;
    // Splash auto-advances on its own after ~2.5s. There is no tap
    // handler and no "tap to continue" — it never waits for a tap.
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  /// Re-attempt Firebase init from the error banner (e.g. after the
  /// Firestore database is created or the network comes back).
  Future<void> _retryFirebase() async {
    final result = await _initFirebase();
    if (mounted) {
      setState(() {
        _firebaseReady = result.ready;
        _firebaseError = result.error;
        _bannerDismissed = false;
      });
    }
  }

  /// Shown only when Firebase init failed. The app keeps working on
  /// the Node backend; cloud features (Firestore/Auth/FCM) are simply
  /// unavailable until init succeeds.
  Widget _firebaseErrorBanner() {
    return Material(
      color: Colors.amber.shade100,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.cloud_off, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Cloud services unavailable — running on the local '
                  'backend only. (${_firebaseError ?? 'Firebase init failed'})',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: _retryFirebase,
                child: const Text('Retry'),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Dismiss',
                onPressed: () => setState(() => _bannerDismissed = true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // MaterialApp sits inside the Consumer so a theme toggle rebuilds
    // it with the new themeMode — the whole app (all screens, sheets,
    // dialogs) switches at once. Tab state survives: _HomeScaffold is
    // keyed, and its screens are created once in initState.
    return Consumer<AppState>(
      builder: (context, state, _) {
        // Smooth fade/slide between splash, login and home.
        // AuthGate: a signed-in but unverified Firebase user sees
        // the verification screen, never Home. A signed-in verified
        // (or demo) user without a linked member yet still sees the
        // login page, which shows the member pick for their session.
        final Widget child;
        if (_showSplash) {
          child = const SplashScreen(key: ValueKey('splash'));
        } else if (state.firebaseAuthEnabled &&
            state.firebaseStatus == FirebaseAuthStatus.needsVerification) {
          child = const VerificationScreen(key: ValueKey('verify'));
        } else if (!state.isLoggedIn) {
          child = const LoginScreen(key: ValueKey('login'));
        } else {
          child = _HomeScaffold(
            key: const ValueKey('home'),
            index: _index,
            onIndexChanged: (i) => setState(() => _index = i),
          );
        }
        return MaterialApp(
          title: 'SplitNest',
          theme: SplitNestTheme.light(),
          darkTheme: SplitNestTheme.dark(),
          themeMode: state.themeMode,
          home: _firebaseReady || _bannerDismissed
              ? AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: fadeSlideTransition,
                  child: child,
                )
              : Column(
                  children: [
                    _firebaseErrorBanner(),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: fadeSlideTransition,
                        child: child,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// Logged-in shell (tabs + AppBar). Split out so the AnimatedSwitcher
/// above can swap the whole home in and out as one keyed child.
/// Stateful so the four tab screens are created once and keep their
/// state (forms, selections, tab controllers) across tab switches.
class _HomeScaffold extends StatefulWidget {
  const _HomeScaffold({
    super.key,
    required this.index,
    required this.onIndexChanged,
  });

  final int index;
  final ValueChanged<int> onIndexChanged;

  @override
  State<_HomeScaffold> createState() => _HomeScaffoldState();
}

class _HomeScaffoldState extends State<_HomeScaffold> {
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      HomeScreen(
        onGoToShopping: () => widget.onIndexChanged(1),
        onGoToMonthly: () => _openScreen(context, const MonthlyViewScreen()),
      ),
      const ShoppingScreen(),
      const ExpensesScreen(),
      const SettleScreen(),
    ];
  }

  /// Drawer destinations Monthly view / Timeline / Profile are separate
  /// screens pushed on the same Navigator (with a working back
  /// button); drawer tabs set the same tab index as the bottom nav,
  /// so there is exactly one route/instance per screen, no copies.
  void _openScreen(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  void _goToTab(BuildContext context, int index) {
    Navigator.of(context).pop(); // Close the drawer first.
    widget.onIndexChanged(index);
  }

  void _logOut(BuildContext context) {
    Navigator.of(context).pop(); // Close the drawer first.
    widget.onIndexChanged(0);
    context.read<AppState>().logout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_SplitNestAppState.titles[widget.index]),
        actions: [
          Consumer<AppState>(
            builder: (context, state, _) => IconButton(
              icon: Icon(
                  state.isDarkMode ? Icons.light_mode : Icons.dark_mode),
              tooltip: state.isDarkMode
                  ? 'Switch to light theme'
                  : 'Switch to dark theme',
              onPressed: () => context.read<AppState>().toggleTheme(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => context.read<AppState>().refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () {
              widget.onIndexChanged(0);
              context.read<AppState>().logout();
            },
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/splitnest-logo-v3.webp',
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'SplitNest',
                    style: SplitNestTheme.titleStyle.copyWith(
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                  Consumer<AppState>(
                    builder: (context, state, _) => Text(
                      state.loggedInMember == null
                          ? 'Shared living'
                          : 'Logged in as ${state.loggedInMember!.name}',
                      style: SplitNestTheme.supportingStyle.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimary
                            .withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.home),
              title: const Text('Home'),
              selected: widget.index == 0,
              onTap: () => _goToTab(context, 0),
            ),
            ListTile(
              leading: const Icon(Icons.shopping_cart),
              title: const Text('Shopping'),
              selected: widget.index == 1,
              onTap: () => _goToTab(context, 1),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: const Text('Expenses'),
              selected: widget.index == 2,
              onTap: () => _goToTab(context, 2),
            ),
            ListTile(
              leading: const Icon(Icons.handshake),
              title: const Text('Settle Up'),
              selected: widget.index == 3,
              onTap: () => _goToTab(context, 3),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.calendar_month),
              title: const Text('Monthly view'),
              onTap: () {
                Navigator.of(context).pop();
                _openScreen(context, const MonthlyViewScreen());
              },
            ),
            ListTile(
              leading: const Icon(Icons.timeline),
              title: const Text('Timeline'),
              onTap: () {
                Navigator.of(context).pop();
                _openScreen(context, const TimelineScreen());
              },
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Profile'),
              onTap: () {
                Navigator.of(context).pop();
                _openScreen(context, const ProfileScreen());
              },
            ),
            const Divider(),
            Consumer<AppState>(
              builder: (context, state, _) => SwitchListTile(
                secondary: Icon(state.isDarkMode
                    ? Icons.dark_mode
                    : Icons.light_mode),
                title: const Text('Dark theme'),
                value: state.isDarkMode,
                onChanged: (_) =>
                    context.read<AppState>().toggleTheme(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Log out'),
              onTap: () => _logOut(context),
            ),
          ],
        ),
      ),
      // Animated tab transitions (fade + slight slide).
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: fadeSlideTransition,
        child: KeyedSubtree(
          key: ValueKey(widget.index),
          child: _screens[widget.index],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.index,
        onDestinationSelected: widget.onIndexChanged,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.shopping_cart), label: 'Shopping'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long), label: 'Expenses'),
          NavigationDestination(
              icon: Icon(Icons.handshake), label: 'Settle Up'),
        ],
      ),
    );
  }
}
