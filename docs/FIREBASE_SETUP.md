# SplitNest — Firebase Setup (manual console steps)

**PRACTICE ONLY — NOT FOR SUBMISSION.**

Project: **SplitNest**, project ID `splitnest-b8071`, Spark (free) plan.
Console: <https://console.firebase.google.com/project/splitnest-b8071>

Status as of Phase 1 (2026-11-07):

- ✅ Firebase project exists; Google sign-in provider enabled.
- ✅ Android app registered: package `com.practice.splitnest.splitnest`.
- ✅ Debug SHA-1 registered:
  `B0:D0:9E:DA:6E:50:24:FB:0A:F4:83:C5:18:FF:80:55:9E:95:0D:47`
  (from `mobile/android/app/debug.keystore`, `androiddebugkey`).
- ✅ `mobile/android/app/google-services.json` is in place locally
  AND committed in the repo (deliberately not gitignored — see the
  note in `.gitignore`). The Flutter app reads Firebase config from
  it on Android; no further download is needed.
- ✅ `firebase_core` is wired in `mobile/lib/main.dart` with
  graceful failure: if init fails the app still launches on the Node
  backend and shows a banner.
- ⏳ **PENDING — Firestore database does NOT exist yet.**
- ⏳ **PENDING — `firestore.rules` / `storage.rules` NOT deployed.**
- ⏳ **PENDING — Storage NOT enabled; FCM not yet used.**

The steps below are the exact pending work for a browser task (or a
human with console access). Nothing here needs a code change.

## (a) Create the Firestore database

1. Open the Firebase console → project **SplitNest**
   (`splitnest-b8071`).
2. Left nav → **Build → Firestore Database**.
3. Click **Create database**.
4. **Location:** choose `asia-south1 (Mumbai)` — closest region to
   Pakistan. This cannot be changed later, so do not pick the
   default (`nam5`) by accident.
5. **Security rules:** choose **Start in production mode** (rules
   deny all reads/writes by default). Do NOT choose test mode — the
   production rules in `firestore.rules` are deployed in the next
   step.
6. Click **Create**. Wait for provisioning to finish (a minute or
   two). The database is empty — no collections yet; collections are
   created by the first write (see `docs/FIRESTORE_STRUCTURE.md`).

## (b) Deploy the Firestore + Storage rules

Two methods — use either; the console paste method needs no CLI.

### Method 1 — Console Rules tab (no CLI)

1. **Firestore rules:** console → **Build → Firestore Database →
   Rules** tab. Delete the default rules text, paste the entire
   contents of `firestore.rules` (repo root), click **Publish**.
2. **Storage rules:** console → **Build → Storage → Rules** tab
   (after Storage is enabled in step (c)). Paste the entire contents
   of `storage.rules`, click **Publish**.
3. Confirm the Rules tab shows a green "Published" state and no
   syntax errors. (Both files were reviewed for syntax in Phase 1
   but have never been published — if the console reports an error,
   stop and report it; do not hand-edit rules in the console.)

### Method 2 — Firebase CLI

```bash
npm install -g firebase-tools
firebase login
cd ~/workspace/splitnest-practice
firebase use splitnest-b8071
firebase deploy --only firestore:rules   # firestore.rules
firebase deploy --only storage           # storage.rules
firebase deploy --only firestore:indexes # firestore.indexes.json (composite indexes)
```

`firebase.json` at the repo root already points at `firestore.rules`,
`storage.rules`, `firestore.indexes.json` and `functions/`.

## (c) Enable Storage

1. Console → **Build → Storage** → **Get started**.
2. **Location:** `asia-south1 (Mumbai)` — same as Firestore.
3. Start in production mode, then immediately replace the default
   rules with `storage.rules` as in (b) (default Storage rules are
   deny-all after the first 30 days in test mode; the repo rules are
   the real ones).
4. No buckets to create manually — the default bucket
   (`splitnest-b8071.firebasestorage.app`) is created automatically.

## (d) FCM (Cloud Messaging) setup notes

- There is **no console switch to "enable" FCM** for Android: once
  `google-services.json` is in the app and the `firebase_messaging`
  package is added (done in Phase 1), the device can obtain a token.
  Nothing to enable in the console for basic delivery.
- The app does **not** request notification permission or register
  tokens yet — that is a later phase (permission prompt + token
  upload to `users/{uid}/fcmTokens`). Until then, no push will arrive
  even though the package is present.
- To send a test message later: console → **Engage → Messaging →
  Create your first campaign → Firebase Notification messages**,
  target the app by package name, or send to a single device token
  from the Cloud Messaging tab. Server-side sending from Functions
  uses the Admin SDK (see `functions/`).
- iOS push is out of scope: no iOS app is registered in the project
  and no APNs key exists.

## (e) Confirming `google-services.json` is already in place

Already done — no action needed. Verify only if something fails:

```bash
ls -l mobile/android/app/google-services.json
# and in the console: Project settings → Your apps → Android app
# com.practice.splitnest.splitnest → google-services.json (Download)
```

If the file ever needs re-downloading, replace that one path and
commit it (the repo deliberately tracks it — see `.gitignore`).

## (f) SHA-1 already registered

Already done — no action needed. The debug SHA-1
`B0:D0:9E:DA:6E:50:24:FB:0A:F4:83:C5:18:FF:80:55:9E:95:0D:47`
is registered on the Android app in
**Project settings → Your apps → SHA certificate fingerprints**.
It belongs to the committed debug keystore
(`mobile/android/app/debug.keystore`); CI-built debug APKs sign
with it, so Google sign-in works in those builds.

A **release** build needs its own signing key + SHA-1 — not
registered, not needed in this phase (debug APKs only).

## (g) Phase 2 (Auth) — Email/Password provider check (PENDING)

Status as of Phase 2 (2026-11-07): the app now signs users in with
real Firebase Auth (email/password, Google credential, demo
create-or-sign-in), but this step was **not verifiable from the VM**
(no console access, and no real account was created from here).

**Check — do this in the console before testing email sign-up:**

1. Console → project **SplitNest** (`splitnest-b8071`) →
   **Build → Authentication → Sign-in method** tab.
2. Look at the **Email/Password** row:
   - If it shows **Enabled**, nothing to do — email sign-up,
     sign-in, demo accounts and password reset all work.
   - If it shows **Disabled**, click it, turn **Email/Password**
     ON, and click **Save**. (Email link sign-in stays OFF — the
     app uses password sign-in plus a verification email, not
     email-link sign-in.)
3. The **Google** row must stay **Enabled** (already confirmed in
   Phase 1) — the app signs into Firebase with the Google
   credential on every Google sign-in.

**What happens if Email/Password is OFF:** every email/password
call fails with Firebase code `operation-not-allowed`, and the app
shows: "Email sign-in is not enabled for this project yet. Enable
it in the Firebase console (Authentication → Sign-in method →
Email/Password), then try again." Demo accounts fail the same way
(they are Firebase email/password users). Member-password login
and Google sign-in are unaffected by this switch — except the
Firebase half of Google sign-in, which does not depend on the
Email/Password provider.

**Still pending from Phase 1:** the Firestore database does NOT
exist yet (step (a) above) and the rules are NOT deployed (step
(b)). Until then the app's `users/{uid}` profile write is skipped
and logged — login never blocks on it, and the write is retried
on the next sign-in.

## (h) Phase 2 — known honest limit: email accounts cannot load household data yet

The household data still lives on the Node backend, and the
backend issues sessions **only** for member passwords
(`POST /api/auth/login`) and verified Google ID tokens
(`POST /api/auth/google`). An email-only Firebase sign-in
therefore has Firebase identity but **no backend token**, so every
data call answers 401. The app says so on screen instead of
showing "Session expired": "Signed in as \<email\>. The household
data still lives on the Node backend, which does not accept email
sign-in yet — sign in with a member password or Google to load
it." Demo and Google users are unaffected (they take a backend
session as part of their login). Fixing this needs a backend
change (accept a Firebase ID token) — a later phase, not Phase 2.

## After these steps

- Firestore exists + rules published → the data model in
  `docs/FIRESTORE_STRUCTURE.md` can be used by a later phase.
- Storage enabled + rules published → receipt uploads can be wired.
- Functions are still NOT deployed (see `functions/README.md`;
  triggers deploy on Spark, the scheduled summary needs Blaze).
- Web: there is **no web app registered** in the Firebase project,
  so `Firebase.initializeApp()` on web currently fails gracefully
  (banner, app still works). Register a web app later with
  `flutterfire configure` if web Firebase is wanted; do not
  hand-write `firebase_options.dart`.
