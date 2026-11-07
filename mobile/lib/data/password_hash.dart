/// Salted password hashing for the local-only auth (Phase 6).
///
/// Every account in lock.json stores a per-user random salt plus a
/// SHA-256 hash — NEVER a plaintext password. The hash is
/// `SHA-256(utf8(salt) + utf8(password))`, both halves hex-encoded.
///
/// Honest limit, stated plainly: a single round of SHA-256 is a
/// salted hash, not a slow key-derivation function (no bcrypt /
/// Argon2 without a native dependency). It stops a casual reader of
/// lock.json from seeing passwords, and it stops two accounts with
/// the same password from sharing a hash — but it is NOT production
/// password storage. This is a single-device practice app: anyone
/// holding the device can read lock.json anyway, so the hash is a
/// hygiene measure, not a security boundary. See docs/LOCK_JSON.md.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A fresh per-user salt: 16 cryptographically random bytes,
/// hex-encoded (32 characters).
String generateSalt({Random? random}) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// `SHA-256(salt + password)`, hex-encoded. [salt] is the stored
/// hex salt; the password is used exactly as typed (no trimming —
/// the UI trims the email, never the password).
String hashPassword(String password, String salt) {
  final bytes = utf8.encode(salt) + utf8.encode(password);
  return sha256.convert(bytes).toString();
}

/// True when [password] hashes to [storedHash] under [salt].
bool verifyPassword({
  required String password,
  required String salt,
  required String storedHash,
}) =>
    hashPassword(password, salt) == storedHash;
