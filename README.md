# SplitNest 

> **This app must never be submitted as an RC³ competition**

SplitNest is a shared-living expense tracker for three roommates in Lahore:
Ali (M01), Ayesha (M02) and Bilal (M03). Shopping list, multi-item checkout
that posts exactly one shared expense, manual expenses with equal/custom
splits, exact paisa accounting, settlements, and a monthly budget.

## Production rebuild — status (2026-11-07)

A full production rebuild is underway (Firebase backend, real auth,
invitations, redesign, light/dark themes). Work lands incrementally;
this section tracks what is done so far.

**Phase 1 — Firebase foundation (done, 2026-11-07):** Firebase packages
added (`firebase_core`, `firebase_auth`, `cloud_firestore`,
`firebase_storage`, `firebase_messaging`, `fl_chart`, `pdf`, `csv`,
`share_plus`, `url_launcher`, `google_mlkit_text_recognition`);
`Firebase.initializeApp()` wired with a graceful fallback banner if cloud
init fails; Firestore data model documented in
[docs/FIRESTORE_STRUCTURE.md](docs/FIRESTORE_STRUCTURE.md); production
security rules in `firestore.rules` / `storage.rules`; Cloud Functions
skeleton in `functions/` (not deployed); setup steps in
[docs/FIREBASE_SETUP.md](docs/FIREBASE_SETUP.md). Gates green:
`flutter analyze` no issues, `flutter test` 65/65, `flutter build web`
succeeds. The app still runs on the Node backend in this phase; no
screen behaviour changed.

**Phase 2 — Firebase Authentication (done, 2026-11-07):** real Firebase
Auth email/password sign-up + sign-in, email verification gate
(verification screen with resend/reload), forgot/reset password, real
Google Sign-In through Firebase Auth (google_sign_in v7 API), AuthGate
session handling via `authStateChanges()`, secure logout. Demo accounts
(ali/ayesha/bilal.demo@splitnest.app) now create-or-sign-in via Firebase
Auth on first use and bypass the verification gate as seeded demo
identities. Gates green: `flutter analyze` no issues, `flutter test`
89/89 (65 baseline + 24 new auth tests), `flutter build web` succeeds.
**Known limit:** an email-only Firebase user has identity but no Node
backend token, so data calls 401 until Phase 3 moves data to Firestore;
the app shows a plain notice instead of failing silently. Demo and
Google users are unaffected.

**Still pending (needs a console step, not code):** create the Firestore
database (production mode, `asia-south1`), deploy `firestore.rules` /
`storage.rules`, enable Storage. See
[docs/FIREBASE_SETUP.md](docs/FIREBASE_SETUP.md) for exact steps.
Cloud Functions are written but **not deployed** (scheduled function
needs the Blaze plan). **Also pending:** enable the Email/Password
sign-in provider in the console (only Google is confirmed enabled) —
until then email/demo sign-in fails with `operation-not-allowed` and
the app says so plainly; see `docs/FIREBASE_SETUP.md` §(g). No live
sign-up/sign-in has been attempted yet — the real auth code paths need
one live pass on a device/emulator after the console steps.

## Stack

- **Backend:** Node.js 24 + Express 4, SQLite file-based via Node's built-in
  `node:sqlite` (no native modules). Money is integer paisa internally;
  JSON carries amounts as two-decimal strings (`"780.00"`).
- **Mobile:** Flutter 3.47.9 (Dart 3.13.7) + Provider, bottom navigation
  Home / Shopping / Expenses & Settle.
- **Database file:** `backend/splitnest.db` — created and seeded on first
  backend start (members M01/M02/M03, budget PKR 5,000.00, pending items
  Milk bottle ×2 and Rice pack ×1). Benchmark expenses are **not** preloaded.

## Run the backend

```sh
cd backend
npm install
npm start          # listens on http://0.0.0.0:3000
# PORT=3000 DB_PATH=./splitnest.db node src/server.js
```

Seven endpoints only:

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/members` | `[{id, name}]` |
| GET | `/api/shopping` | Shopping items |
| POST | `/api/shopping` | Add item (`title`, `unit` pack/dozen/bottle/bag, `requested_qty`) |
| POST | `/api/shopping/checkout` | Atomic checkout → exactly one expense |
| POST | `/api/expenses` | Manual expense (equal or custom split) |
| GET | `/api/balances` | Net balances (sum = 0.00) + budget summary |
| POST | `/api/settle` | Debtor → creditor payment |

## Run the mobile app

```sh
cd mobile
flutter pub get
flutter run
```

API base URL — pass it at build/run time, or the app defaults to the
Android emulator host loopback:

```sh
# Android emulator
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
# Physical Android/iOS device on the same Wi-Fi (use your laptop's LAN IP)
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:3000
# Web on the same machine
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:3000
```

A web build already exists at `mobile/build/web/` (built with
`API_BASE_URL=http://127.0.0.1:3000`); serve it with any static server,
e.g. `python3 -m http.server 8123` inside `mobile/build/web/`, while the
backend runs on port 3000.

## Benchmark (reproduce exactly)

From a fresh database (delete `backend/splitnest.db` first, then start
the backend), or run `npm test` in `backend/` — the benchmark test does
this automatically against a temporary database:

1. Checkout Milk + Rice: total `780.00`, payer Ali, equal split → 260.00 each.
2. Cleaning Supplies: `900.00`, payer Ayesha, equal Ali + Ayesha → 450.00 each.
3. Internet Bill: `1500.00`, payer Bilal, custom Ali 500 / Ayesha 300 / Bilal 700.
4. Electricity Bill: `1020.00`, payer Ali, equal → 340.00 each.

Expected: total spending **4200.00**, budget 5000.00, remaining **800.00**,
**84%** used, status **Near Limit**, balances Ali **+250.00**, Ayesha
**-450.00**, Bilal **+200.00** (sum 0.00). Then settle Ayesha → Ali 250.00
(balances 0.00 / -200.00 / +200.00) and Ayesha → Bilal 200.00 (all 0.00);
spending stays **4200.00**.

## Money rules (the important ones)

- Equal split: base share floored, remainder paisa handed out 1-by-1 in
  ascending member-ID order. `1000.00 / 3 = 333.34 / 333.33 / 333.33`;
  `0.01 / 3 = 0.01 / 0.00 / 0.00`.
- Custom splits must sum exactly to the amount, with unique known members.
- Balance formula used (TESTING.md worked example): **Net = Paid − Share
  + Sent − Received**. The task document prints the opposite sign for
  settlements (`+ Received − Sent`), which would make Ali's balance +500
  after receiving 250 instead of the official 0.00 — the worked example
  governs here, and the discrepancy is flagged in the code comments.
- Settlements never change total spending. Rejected: self-settlement,
  zero/negative amounts, unknown members, non-debtor sender, non-creditor
  recipient, over-settlement.
- Checkout is atomic (one transaction): items become Bought and exactly
  one expense is posted, or nothing changes. A second checkout of the
  same items fails with 409.

## Verified results (2026-11-05, professional upgrade)

- Backend: `npm test` — **11/11 tests pass** (4 money unit tests, 7 API
  tests incl. persistence after restart, atomic checkout, and the exact
  benchmark above). Live server + live benchmark re-run verified by curl.
- Flutter: `flutter analyze` — **no issues found**; `flutter test` —
  **17/17 pass** (6 money unit tests incl. Smart Settle plan, 11 widget
  tests incl. splash → login → Home, login as Ayesha showing her
  balance, logout returning to login, 4-tab navigation, Current/History
  shopping tabs, Add Expense sheet with live preview, Smart Settle plan,
  checkout bottom sheet with live split preview, settle suggestions);
  `flutter build web` — **succeeded** (see note below).

## Professional UI (2026-11-05)

- **Theme: light only, white + navy #1D2D44** (user decision; supersedes
  the old teal #155E75 — no teal remains in the app). Gold #EEC558 from
  the logo coins is a sparing accent. No dark theme, no toggle; the app
  always renders light (`ThemeMode.light`), including on devices set to
  dark mode. Full design system in `mobile/lib/src/theme.dart` (DESIGN.md
  type scale 24/18/16/14, 16pt padding, 12pt radius, 48pt touch targets).
- **Logo:** `assets/media-generation-splitnest-logo-0-…webp` (navy rounded
  square, white nest, three gold coins). Copied to
  `mobile/assets/splitnest-logo.webp` and declared in `pubspec.yaml`;
  converted to PNG for Android launcher icons (all `mipmap-*`, plus
  adaptive-icon foreground/background), web icons, and favicon.
- **Flow: Splash → Login → Home.** Splash shows the logo centred on
  white with the SplitNest wordmark, then auto-advances after ~1.8s.
  Login is three tappable member cards (Ali M01, Ayesha M02, Bilal M03,
  initials avatars) — **no password**, client-side member selection
  only, clearly labelled "not verified identity". Home shows a
  "Logged in as" card instead of the old free member switcher; the
  AppBar has a Log out button that returns to login, and Home is
  unreachable without picking a member again. No backend auth added;
  the 7 endpoints are unchanged.
- **Navigation: 4 tabs** — Home, Shopping, Expenses, Settle Up (the old
  combined "Expenses & Settle" tab was split in two).
- **Home:** branded navy header with the logo, centred Monthly Budget
  ring (animated to its value; PKR total, % used, PKR remaining, status
  pill), active-member balance card ("You are owed / You owe / Settled
  up" + Paid/Share breakdown), Active Members card with owed/owe labels
  + icons, Pending Shopping card (count + item names, tap opens
  Shopping), pull-to-refresh, loading/empty/error states.
- **Shopping:** Current List / History tabs (pending vs bought), item
  rows with checkboxes for multi-select, unit + quantity, status pills,
  quantity stepper in the add-item form, inline validation, a
  "Checkout · N selected" bar, checkout as a bottom sheet with live
  per-person split preview, double-tap protection, success snackbar.
- **Expenses:** expense list (session-only) + an Add New Expense bottom
  sheet with Title, Amount, category chips with Material icons
  (Groceries, Utilities, Cleaning, Entertainment, General), date
  picker, payer selector, and Split Strategy Equal / Exact / Custom —
  Equal splits evenly across all members, Exact takes exact PKR amounts
  per member that must sum to the total, Custom picks which members
  share and splits evenly among them. Live split preview before submit.
- **Settle Up:** balances table (Paid / Share / Net + owed/owe label),
  a Smart Settle card computed from LIVE balances (greedy
  largest-debtor → largest-creditor; on the benchmark it reads "Ayesha
  pays Ali PKR 250.00 and Bilal PKR 200.00"), and a Settle Debt dialog
  with debtor→creditor suggestions, max-settleable hint and explicit
  confirmation. Settlements never change total spending.
- **Animations (subtle):** splash logo fades + scales in, then one soft
  pulse swell; AnimatedSwitcher fade/slide between splash, login, Home
  and across bottom-nav tabs; cards fade + slide up on entrance with a
  light stagger; the budget ring animates to its value. All 200–400ms
  (ring 700ms), smooth easing, no flashing or bouncing. Reduced motion
  is respected via `MediaQuery.disableAnimations`. Press feedback is
  built-in Material ink ripple. The three gold coins are baked into the
  single logo WebP, so they cannot animate separately — the whole logo
  animates instead (no overlaid dots).

## Web build note (2026-11-05)

`flutter build web` compiles both the JS and WASM targets and takes
~60–90s on this VM. Two earlier attempts looked "aborted" but the
build was in fact still compiling; the failure in the log was the
dart2js worker being killed (exit -15) by a cleanup `pkill` that
matched it. The successful run was started detached (`nohup`) and left
alone until the log showed completion — do not `pkill` Dart/Flutter
processes while it runs.

## Known limitations

- **APK:** debug APKs are built by GitHub Actions
  (`.github/workflows/android-apk.yml`) — local Gradle builds fail on
  this VM. The Nov 5 phone-variant APK (real Google Sign-In) was
  delivered; see the rebuild status above for the current state.
- **Auth:** real Google Sign-In via Firebase Auth plus email/password
  login with 3 demo accounts were added Nov 5 (see `mobile/lib/data/
  google_auth_service.dart`). The old "no password" member selector is
  gone; the Nov 7 rebuild moves all auth to Firebase Auth.
- **Surprise features not implemented.** Annexure A lists four options, but
  none was released, so none was built (no `/api/balances/simplify`,
  no tax/discount, no category warnings, no recurring expenses).
- **Expense history:** only the 7 specified endpoints exist, so there is
  no `GET /api/expenses`. The mobile app shows expenses added in the
  current session; balances and budget always come live from the backend.
- **Month scope:** budget totals count the current month's expenses;
  balances are computed over all recorded expenses and settlements.
- Pushed to GitHub: https://github.com/maraij/splitnest_riphahcup3
  (main). The Nov 7 rebuild lands there incrementally, phase by phase.
