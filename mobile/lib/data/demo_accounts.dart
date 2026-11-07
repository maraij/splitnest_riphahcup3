/// Demo accounts — the three seeded household members.
///
/// These are the demo identities the app has always used (Phase 2).
/// They live ONLY on this device, inside lock.json (see
/// docs/LOCK_JSON.md): there is no cloud account behind them, no
/// email verification, and no password reset email — the passwords
/// below are the demo passwords shown in the app's own demo picker.
/// They are public demo credentials for a practice app, never real
/// user credentials. Real accounts are created by sign-up and stored
/// the same way (salted hash, see data/password_hash.dart).
library;

/// One demo account: a fixed household member with a local identity
/// on the clearly demo domain `splitnest.app`.
class DemoAccount {
  const DemoAccount({
    required this.memberId,
    required this.name,
    required this.email,
    required this.password,
  });

  final String memberId;
  final String name;
  final String email;
  final String password;
}

const List<DemoAccount> demoAccounts = [
  DemoAccount(
    memberId: 'M01',
    name: 'Ali',
    email: 'ali.demo@splitnest.app',
    password: 'ali123',
  ),
  DemoAccount(
    memberId: 'M02',
    name: 'Ayesha',
    email: 'ayesha.demo@splitnest.app',
    password: 'ayesha123',
  ),
  DemoAccount(
    memberId: 'M03',
    name: 'Bilal',
    email: 'bilal.demo@splitnest.app',
    password: 'bilal123',
  ),
];

DemoAccount? demoForMember(String memberId) {
  for (final demo in demoAccounts) {
    if (demo.memberId == memberId) return demo;
  }
  return null;
}

/// A user counts as a demo identity when their email is on the demo
/// domain. Real users can never have such an address — the domain is
/// not a real mail domain.
bool isDemoEmail(String? email) =>
    email != null && email.toLowerCase().endsWith('@splitnest.app');

/// The deterministic local uid for a demo account. Stable across
/// reinstalls of the same lock.json seed, so demo households keep
/// the same group id (`household-<uid>`).
String demoUidForMember(String memberId) => 'demo-$memberId';
