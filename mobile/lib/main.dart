import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/local_auth_service.dart';
import 'data/local_json_repository.dart';
import 'core/services/app_logger.dart';
import 'features/auth/login_screen.dart';
import 'features/chatbot/chatbot_screen.dart';
import 'features/expenses/expenses_screen.dart';
import 'features/home/home_screen.dart';
import 'features/invite/invite_screen.dart';
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
/// AuthGate: the local auth session decides — signed-out → login,
/// signed-in → Home as the linked member. Sign-in is local-only
/// (email/password, demo); there is no member-password login, no
/// third-party sign-in, and no backend session any more. Household
/// data lives in one local file, lock.json (LocalJsonRepository);
/// the Node backend is retired (see backend/LEGACY.md) and the
/// cloud backend was dropped by user decision on 2026-11-07 (see
/// docs/LOCK_JSON.md). Log out returns to the login page; Home is
/// unreachable without logging in. Tabs:
/// Home, Shopping, Expenses, Settle Up. Drawer: the same four tabs
/// plus Monthly view, Timeline, Profile and the AI Assistant
/// (Phase 7 — not configured in this build: no Gemini key was
/// supplied, so the chat screen explains the setup instead of
/// sending anything).
/// Theme: light (Hisaab Kitaab teal) or dark (Coolors plum palette),
/// one shared AppState flag; toggled from the AppBar or the drawer,
/// persisted in SharedPreferences and applied before first paint.
/// Phase 6 (lock.json data): one LockJsonStore is shared between the
/// repository and the auth service, so accounts and household data
/// are the same document. On web the store is in-memory only and
/// AppState surfaces a plain banner saying so — the app still
/// launches and works for the session instead of crashing.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var initialDark = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    initialDark = prefs.getString('theme_mode') == 'dark';
  } catch (_) {
    // Storage unavailable: start light; the toggle still works.
  }
  final store = LockJsonStore();
  // Structured log (Phase 7): logs.json next to lock.json in the
  // app documents directory (in-memory only on web — see
  // core/services/app_logger.dart and docs/LOGGING.md). The same
  // logger is wired into the repository and AppState, so app start,
  // auth, repository errors, chatbot calls and invitation actions
  // are all logged. It never carries passwords, tokens or API keys.
  final logger = AppLogger(accessLoader: () => store.fileAccess);
  await logger.load();
  logger.info('app', 'SplitNest started');
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(
        initialDarkMode: initialDark,
        // lock.json is the only data source; the auth service shares
        // the same store, so accounts and household data stay in
        // one document.
        repository: LocalJsonRepository(store: store, logger: logger),
        localAuth: RealLocalAuthService(store: store),
        logger: logger,
      )
        ..refresh()
        ..loadStoreNotice(),
      child: const SplitNestApp(),
    ),
  );
}

class SplitNestApp extends StatefulWidget {
  const SplitNestApp({super.key});

  @override
  State<SplitNestApp> createState() => _SplitNestAppState();
}

class _SplitNestAppState extends State<SplitNestApp> {
  int _index = 0;
  bool _showSplash = true;
  bool _bannerDismissed = false;

  static const titles = ['SplitNest', 'Shopping', 'Expenses', 'Settle Up'];

  @override
  void initState() {
    super.initState();
    // Splash auto-advances on its own after ~2.5s. There is no tap
    // handler and no "tap to continue" — it never waits for a tap.
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  /// Shown only when the local store has something plain to say —
  /// the web in-memory warning, or a corrupt-file recovery note
  /// (see AppState.dataNotice). Dismissible; the app keeps working
  /// underneath it.
  Widget _storeNoticeBanner(String notice) {
    return Material(
      color: Colors.amber.shade100,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.storage_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  notice,
                  style: const TextStyle(fontSize: 12),
                ),
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
        // AuthGate: a signed-in local user sees Home; anyone else
        // sees the login page. There is no verification step any
        // more — local accounts sign in directly.
        final Widget child;
        if (_showSplash) {
          child = const SplashScreen(key: ValueKey('splash'));
        } else if (!state.isLoggedIn) {
          child = const LoginScreen(key: ValueKey('login'));
        } else {
          child = _HomeScaffold(
            key: const ValueKey('home'),
            index: _index,
            onIndexChanged: (i) => setState(() => _index = i),
          );
        }
        final notice = state.dataNotice;
        final showBanner = notice != null && !_bannerDismissed;
        return MaterialApp(
          title: 'SplitNest',
          theme: SplitNestTheme.light(),
          darkTheme: SplitNestTheme.dark(),
          themeMode: state.themeMode,
          home: showBanner
              ? Column(
                  children: [
                    _storeNoticeBanner(notice),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: fadeSlideTransition,
                        child: child,
                      ),
                    ),
                  ],
                )
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: fadeSlideTransition,
                  child: child,
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
        onGoToInvite: () => _openScreen(context, const InviteScreen()),
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
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('AI Assistant'),
              onTap: () {
                Navigator.of(context).pop();
                _openScreen(context, const ChatbotScreen());
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
            // Invite & households sits below the theme switch so the
            // switch keeps its position in the drawer list.
            ListTile(
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('Invite & households'),
              onTap: () {
                Navigator.of(context).pop();
                _openScreen(context, const InviteScreen());
              },
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
