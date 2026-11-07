/// Invitation codes, links and email handling (Phase 4) — pure
/// Dart, no Firestore, no Flutter, so unit tests cover it directly.
///
/// Code format (see docs/INVITATIONS.md):
/// - The code is 12 characters from an unambiguous alphabet (no
///   `0`/`O`, `1`/`I`/`l`), generated with a cryptographically secure
///   random source — never sequential, never derived from an email,
///   a timestamp or a counter.
/// - The invitation document's id IS the code, so "enter invite
///   code" is a direct document read and the security rules can
///   authorise a self-join by reading the invitation by id.
/// - Shown to humans grouped as `XXXX-XXXX-XXXX`; the link carries
///   the ungrouped code.
/// - The shareable link is plain text:
///   `https://splitnest.app/join?code=XXXXXXXXXXXX`
///   There is no App Links / deep-link wiring and no hosting behind
///   that domain — the link is a convenient way to carry the code;
///   the working mechanism is pasting/entering the code in the app.
library;

import 'dart:math';

/// Invite codes live for 7 days from creation.
const int invitationValidityDays = 7;

/// The host in the shareable link. Plain text only — no App Links,
/// no hosting, no auto-join (see docs/INVITATIONS.md).
const String inviteLinkHost = 'splitnest.app';

/// 32 unambiguous characters: no 0/O, 1/I/l. 12 characters ≈ 60
/// bits of entropy.
const String _inviteAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Generates one invite code. [random] is injectable for tests;
/// production uses [Random.secure].
String generateInviteCode({Random? random}) {
  final r = random ?? Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 12; i++) {
    buf.write(_inviteAlphabet[r.nextInt(_inviteAlphabet.length)]);
  }
  return buf.toString();
}

/// Normalises user input for lookup: upper-cased, dashes/spaces and
/// any other non-alphanumeric characters stripped.
String normalizeInviteCode(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Groups a code for display: `ABCD1234EFGH` → `ABCD-1234-EFGH`.
/// Anything that is not a 12-character code is returned normalised.
String formatInviteCode(String code) {
  final clean = normalizeInviteCode(code);
  if (clean.length != 12) return clean;
  return '${clean.substring(0, 4)}-${clean.substring(4, 8)}'
      '-${clean.substring(8, 12)}';
}

/// The shareable link for a code (ungrouped code in the query).
String inviteLinkFor(String code) =>
    'https://$inviteLinkHost/join?code=${normalizeInviteCode(code)}';

/// Extracts the invite code from whatever the user pastes: a bare
/// code (`ABCD-1234-EFGH`), a bare grouped code, or a full
/// `https://splitnest.app/join?code=...` link. Returns the
/// normalised code, or `''` when nothing usable is present.
String parseInviteCode(String input) {
  final trimmed = input.trim();
  final match =
      RegExp(r'[?&]code=([^&#\s]+)', caseSensitive: false).firstMatch(trimmed);
  final raw = match == null ? trimmed : match.group(1)!;
  return normalizeInviteCode(Uri.decodeComponent(raw));
}

/// Lower-cases and trims an invitee email, as stored.
String normalizeInviteEmail(String email) => email.trim().toLowerCase();

/// Minimal email shape check for the invite form. This is a
/// usability check only — deliverability is not verified.
bool isValidInviteEmail(String email) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim());

/// Expiry for an invitation created at [created]: 7 days later.
DateTime invitationExpiryFrom(DateTime created) =>
    created.add(const Duration(days: invitationValidityDays));
