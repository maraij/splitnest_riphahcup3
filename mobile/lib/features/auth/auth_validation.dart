// Pure validation for the local email/password forms (sign-up,
// sign-in, password reset). No auth calls here, so these are
// unit-tested directly. Each validator returns the message to show,
// or null when the value is valid.

/// Local accounts require passwords of at least 6 characters. The
/// rule is shown next to the password field so the user sees it
/// before typing.
const int minPasswordLength = 6;

/// The password rule, shown as a hint under the password field.
const String passwordRuleText = 'At least 6 characters.';

/// Roughly RFC-5322-shaped, good enough for a sign-up form: something,
/// an @, something, a dot, something. The local auth service
/// re-validates and rejects anything it does not accept.
final RegExp _emailPattern =
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? validateEmail(String value) {
  final email = value.trim();
  if (email.isEmpty) return 'Enter your email address.';
  if (!_emailPattern.hasMatch(email)) {
    return 'Enter a valid email address, like name@example.com.';
  }
  return null;
}

String? validatePassword(String value) {
  if (value.isEmpty) return 'Enter a password.';
  if (value.length < minPasswordLength) {
    return 'Password must be at least $minPasswordLength characters.';
  }
  return null;
}

String? validateDisplayName(String value) {
  if (value.trim().isEmpty) return 'Enter your name.';
  return null;
}

String? validateConfirmPassword(String password, String confirm) {
  if (confirm.isEmpty) return 'Repeat your password.';
  if (password != confirm) return 'Passwords do not match.';
  return null;
}
