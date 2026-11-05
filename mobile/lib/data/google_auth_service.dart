import 'package:google_sign_in/google_sign_in.dart';

/// Web OAuth client id (client_type 3) from google-services.json
/// (Firebase project SplitNest). A client id is a public identifier,
/// not a secret — the same value ships inside the built app through
/// the Firebase config. It is the serverClientId Google needs to
/// issue an ID token our backend can verify.
const String googleServerClientId =
    '780339874841-o9eaoan4imbo23gjge4s99cah5pqkgpo.apps.googleusercontent.com';

/// Outcome of one Google sign-in attempt. The UI switches on this —
/// it never sees the google_sign_in types, so widget tests can inject
/// a fake service instead of the real one.
sealed class GoogleSignInResult {
  const GoogleSignInResult();
}

/// Signed in: the backend can verify [idToken], and the UI can show
/// [email] in the member picker.
class GoogleSignedIn extends GoogleSignInResult {
  const GoogleSignedIn({required this.idToken, required this.email});
  final String idToken;
  final String email;
}

/// The user backed out of the Google account chooser.
class GoogleSignInCancelled extends GoogleSignInResult {
  const GoogleSignInCancelled();
}

/// Anything else (no network, misconfigured client, no ID token
/// issued). [message] is safe to show on the login page.
class GoogleSignInFailed extends GoogleSignInResult {
  const GoogleSignInFailed(this.message);
  final String message;
}

/// Google sign-in, behind an interface so tests can inject a fake.
/// The production implementation is [RealGoogleAuthService].
abstract class GoogleAuthService {
  Future<GoogleSignInResult> signIn();
}

/// Real Google sign-in via the google_sign_in plugin (v7 API):
/// initialize once with the Web client id, then authenticate() shows
/// the account chooser / Gmail + password flow and returns the
/// account; its ID token is what the backend verifies at
/// POST /api/auth/google. A cancelled chooser is reported as
/// [GoogleSignInCancelled], never as an error and never as a session.
class RealGoogleAuthService implements GoogleAuthService {
  RealGoogleAuthService({GoogleSignIn? signIn})
      : _signIn = signIn ?? GoogleSignIn.instance;

  final GoogleSignIn _signIn;
  bool _initialized = false;

  @override
  Future<GoogleSignInResult> signIn() async {
    try {
      if (!_initialized) {
        await _signIn.initialize(serverClientId: googleServerClientId);
        _initialized = true;
      }
      final account = await _signIn.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        return const GoogleSignInFailed(
          'Google did not return a sign-in token. '
          'Please try again or use member login.',
        );
      }
      return GoogleSignedIn(idToken: idToken, email: account.email);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const GoogleSignInCancelled();
      }
      final detail = e.description;
      return GoogleSignInFailed(
        detail != null && detail.isNotEmpty
            ? 'Google sign-in failed: $detail'
            : 'Google sign-in failed. '
                'Please try again or use member login.',
      );
    } catch (_) {
      return const GoogleSignInFailed(
        'Google sign-in failed. '
        'Please try again or use member login.',
      );
    }
  }
}
