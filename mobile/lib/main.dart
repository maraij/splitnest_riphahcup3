import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'features/expenses/expenses_screen.dart';
import 'features/home/home_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/settle/settle_screen.dart';
import 'features/shopping/shopping_screen.dart';
import 'features/splash/splash_screen.dart';
import 'state/app_state.dart';
import 'core/theme.dart';
import 'core/widgets/entrance.dart';

/// SplitNest — practice-only shared-living expense app.
/// PRACTICE ONLY — NOT FOR SUBMISSION.
/// Flow: Splash (logo, ~1.8s) → Member login (pick Ali / Ayesha /
/// Bilal, no password) → Home as that member. Log out returns to
/// the login page; Home is unreachable without picking a member.
/// The login is client-side member selection only — not verified
/// identity, no backend auth.
/// Tabs: Home, Shopping, Expenses, Settle Up.
void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..refresh(),
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

  static const titles = ['SplitNest', 'Shopping', 'Expenses', 'Settle Up'];

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SplitNest',
      // Light theme only (user decision 2026-11-05): no darkTheme and
      // ThemeMode.light, so the app always renders light even on
      // devices set to dark mode. Primary is teal #0F766E; navy #1D2D44 is text only.
      theme: SplitNestTheme.light(),
      themeMode: ThemeMode.light,
      home: Consumer<AppState>(
        builder: (context, state, _) {
          // Smooth fade/slide between splash, login and home.
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
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: fadeSlideTransition,
            child: child,
          );
        },
      ),
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
      HomeScreen(onGoToShopping: () => widget.onIndexChanged(1)),
      const ShoppingScreen(),
      const ExpensesScreen(),
      const SettleScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_SplitNestAppState.titles[widget.index]),
        actions: [
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
