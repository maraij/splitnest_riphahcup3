import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'firebase_auth_service.dart';

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
/// [email] in the member picker. [firebaseUid] is set when the same
/// sign-in also completed Firebase Auth (the real implementation);
/// fakes leave it null.
class GoogleSignedIn extends GoogleSignInResult {
  const GoogleSignedIn({
    required this.idToken,
    required this.email,
    this.displayName,
    this.firebaseUid,
  });
  final String idToken;
  final String email;
  final String? displayName;
  final String? firebaseUid;
}

/// The user backed out of the Google account chooser.
class GoogleSignInCancelled extends GoogleSignInResult {
  const GoogleSignInCancelled();
}

/// Anything else (no network, misconfigured client, no ID token
/// issued, Firebase sign-in rejected). [message] is safe to show on
/// the login page.
class GoogleSignInFailed extends GoogleSignInResult {
  const GoogleSignInFailed(this.message);
  final String message;
}

/// Google sign-in, behind an interface so tests can inject a fake.
/// The production implementation is [RealGoogleAuthService].
abstract class GoogleAuthService {
  Future<GoogleSignInResult> signIn();

  /// Signs out of Google (used by the app logout). Best-effort: a
  /// failure here must never block logout.
  Future<void> signOut();
}

/// Real Google sign-in via the google_sign_in plugin (v7 API,
/// verified against google_sign_in 7.2.0 in the pub cache):
/// initialize once with the Web client id, then authenticate() shows
/// the account chooser / Gmail + password flow and returns the
/// account. Its ID token is used TWICE:
///
/// 1. Firebase Auth: signInWithCredential(
///      GoogleAuthProvider.credential(idToken: idToken))
///    — this is the real Firebase Google sign-in. A Google user
///    arrives email-verified, so the verification gate does not
///    apply. (v7's authentication object carries only an ID token,
///    no access token — the credential call takes idToken alone.)
/// 2. The Node backend: POST /api/auth/google verifies the same ID
///    token against Google before issuing the household session
///    (that step lives in AppState.loginWithGoogle, unchanged).
///
/// A cancelled chooser is reported as [GoogleSignInCancelled], never
/// as an error and never as a session. A Firebase rejection is a
/// [GoogleSignInFailed] with a plain mapped message.
class RealGoogleAuthService implements GoogleAuthService {
  RealGoogleAuthService({GoogleSignIn? signIn, FirebaseAuth? firebaseAuth})
      : _signIn = signIn ?? GoogleSignIn.instance {
    // Stored, not resolved, here: FirebaseAuth.instance is only
    // touched inside signIn(), so merely constructing this service
    // (e.g. in widget tests that never tap Google) is safe when
    // Firebase was never initialised.
    _firebaseAuth = firebaseAuth;
  }

  final GoogleSignIn _signIn;

  FirebaseAuth? _firebaseAuth;
  FirebaseAuth get _auth => _firebaseAuth ??= FirebaseAuth.instance;

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
      // Real Firebase sign-in with the Google credential. If Firebase
      // is not initialised (or the Google provider is off), this
      // throws and the Google login fails with a plain message
      // instead of silently falling back to a backend-only session.
      try {
        final credential = await _auth.signInWithCredential(
          GoogleAuthProvider.credential(idToken: idToken),
        );
        return GoogleSignedIn(
          idToken: idToken,
          email: account.email,
          displayName: account.displayName,
          firebaseUid: credential.user?.uid,
        );
      } on FirebaseAuthException catch (e) {
        return GoogleSignInFailed(firebaseAuthErrorMessage(e));
      }
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

  @override
  Future<void> signOut() async {
    try {
      await _signIn.signOut();
    } catch (_) {
      // Best-effort: logout continues regardless (AppState also
      // swallows sign-out failures — logout must never fail).
    }
  }
}
