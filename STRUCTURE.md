# SplitNest — Structure

**PRACTICE ONLY — NOT FOR SUBMISSION.** Shared-living expense app
(Flutter + Provider front end, Cloud Firestore back end since Phase 3
— the Node backend is retired, see `backend/LEGACY.md`).
Money rules live in `lib/core/money.dart` and
`lib/domain/balances.dart`: integer paisa, equal split remainder 1-by-1
in member-ID order, Net = Paid − Share + Sent − Received, settlements
never change total spending.

## Layout pattern (every screen)

Same AppBar style, same card style, 8pt spacing rhythm, 16pt screen
padding, 12pt card radius, 48pt minimum touch targets, section
headings in `SplitNestTheme.sectionStyle`. One home screen per
feature — no duplicated sections. Bottom tabs and drawer go to the
SAME screens, in the SAME order: Home, Shopping, Expenses, Settle Up,
then drawer-only Monthly view, Timeline, Profile.

## Flutter — `mobile/lib/`

### `core/` — theme, formatting, shared widgets (no app logic)
- `theme.dart` — light-only theme: teal `#0F766E` primary, navy
  `#1D2D44` text/headings only, gold `#EEC558` accent sparingly.
- `money.dart` — paisa parsing/formatting, equal-split maths.
- `format.dart` — date/amount display helpers.
- `constants.dart` — categories, cap categories, units.
- `widgets/` — `budget_ring.dart` (animated ring), `entrance.dart`
  (fade+slide-in), `error_banner.dart` (error + retry),
  `illustrations.dart` (Flutter-drawn nest/empty-state art),
  `member_avatar.dart` (initials, or the member's picked photo),
  `money_text.dart`, `status_pill.dart`.

### `domain/` — pure functions, no widgets, no HTTP
- `models.dart` — Member, ShoppingItem, Expense, BalanceRow,
  Balances, FixedExpense, ActivityEntry, PaymentRecord.
- `balances.dart` — `computeBalances` (Paid/Share/Sent/Received,
  monthly total, used %, status) + `settlementError` validation.
  Pure; the Firestore repository hands it Firestore-shaped data.
- `settle_plan.dart` — Smart Settle: greedy largest-debtor →
  largest-creditor from live balances.
- `insights.dart` — category breakdown, monthly summary, recurring
  bills, quick-add favourites, weekly spending, per-member
  summaries, cap spend, receipt parsing (`parseReceipt`).

### `data/` — the only place that talks to the cloud
- `repository.dart` — `SplitNestRepository` interface (the seam
  tests substitute fakes through), `CloudDataException`,
  `UnavailableSplitNestRepository`, shared validators.
- `firestore_repository.dart` — `FirestoreSplitNestRepository`:
  typed Firestore CRUD over `groups/{gid}/…`, member-ID ↔ UID
  translation at the boundary, transactions for checkout and
  fixed-apply, `ensureGroup` seeding, `loadDemoBenchmark`,
  `configureFirestorePersistence()`.
- `demo_benchmark.dart` — the benchmark data (Milk+Rice 780,
  Cleaning 900, Internet 1500, Electricity 1020) as pure data;
  never auto-seeded, demo-only.
- `firebase_auth_service.dart` / `google_auth_service.dart` —
  Firebase Auth (Phase 2); the Firebase UID is the session.
  (`api_client.dart` and the Node HTTP client were deleted in
  Phase 3; the `http` package is gone from `pubspec.yaml`.)

### `state/` — single source of truth
- `app_state.dart` — `AppState`: members, budget/balances, shopping,
  expenses (full persisted history now, not session-only), payments,
  fixed templates, activity log, caps, profile photos, Firebase
  session, logged-in member, welcome/celebration flags. Its ONLY
  data source is the injected `SplitNestRepository` (Firestore in
  the app, fakes in tests). No backend token, no `API_BASE_URL`.
  Widgets read from it and call its methods only; every mutation
  refreshes it once. No `setState` for app data in widgets.

### `features/` — one folder per screen (screen + its own widgets)
- `splash/` — `splash_screen.dart`: logo fade+scale, coin drop-ins,
  pulse; auto-advances after ~2.5s, no tap.
- `auth/` — `login_screen.dart`: email sign-in/sign-up (+
  verification, forgot password), Continue with Google, one Demo
  button → popup with name+ID only (no passwords on buttons). No
  member-password form any more (the backend login is gone).
- `home/` — `home_screen.dart`: budget ring, Your Balance card,
  Active Members, Pending Shopping, Budget Alert banner, Danger Zone
  (cap) banner, **Load demo benchmark** card (demo users only, until
  loaded); `insights_cards.dart` (category breakdown, monthly
  summary, recurring bills, category caps); `welcome_dialog.dart`
  (once per login); `celebration_dialog.dart` (saved-money popup,
  once per login, after the welcome popup).
- `shopping/` — `shopping_screen.dart`: Current/History tabs,
  add-item form, checkout bottom sheet, "Others" quick-add.
- `expenses/` — `expenses_screen.dart`: search/filter, quick-add
  favourites, per-member view, fixed-monthly list, Add Expense
  sheet (title, amount, category chips, date, payer, Equal/Custom,
  Repeat monthly, Paste receipt).
- `settle/` — `settle_screen.dart`: Balances table (only place with
  full Paid/Share), Smart Settle suggestion (prefills only),
  Settle Debt dialog, Pending verification card (recorded payments
  with a Verify button).
- `monthly/` — `monthly_view_screen.dart`: the logged-in member's
  month — totals, per-category, per-expense, weekly trend bars.
- `timeline/` — `timeline_screen.dart`: read-only activity log
  (drawer only, never on Home).
- `profile/` — `profile_screen.dart`: name, member ID, month totals,
  net balance; photo edit (camera badge + "Change photo", image
  picker, stored per member in AppState — still local; Storage
  upload is Phase 5). No email/role — members have only name + ID.

### `main.dart`
App root: splash → login → logged-in shell. The shell holds the
4-tab `NavigationBar` and the `Drawer` (same 4 tabs + Monthly view,
Timeline, Profile, Log out). Drawer tabs set the tab index; Monthly
view / Timeline / Profile are pushed routes with a back button.
`Firebase.initializeApp()` runs in `main()` before `runApp`;
`configureFirestorePersistence()` enables offline persistence.
If init fails, the app still launches with an
`UnavailableSplitNestRepository` and a dismissible amber banner
with Retry ("Cloud services unavailable — sign-in and household
data need Firebase") — it never crashes and never shows fake data.
On a successful retry the repository is swapped in live via
`AppState.useRepository()`. No screen reads the Node backend;
all data comes from Firestore.

## Firebase — repo root + `docs/` + `functions/` (Phases 1–3)

- `firestore.rules` — production rules (NOT DEPLOYED; DB does not
  exist yet): authenticated-only, group membership via the `members`
  map, owner/admin-only invite / verify / delete, members record
  their own payments but cannot verify them, notifications +
  activity are Functions-only.
- `storage.rules` — receipts readable only by group members, profile
  photos owner-written (NOT DEPLOYED; Storage not enabled yet).
- `firebase.json` — points CLI deploys at the rules, indexes and
  `functions/`. `firestore.indexes.json` — the 10 composite indexes
  from `docs/FIRESTORE_STRUCTURE.md`.
- `docs/FIRESTORE_STRUCTURE.md` — the Firestore data model
  (`users`, `groups` + `members` map/subcollection, `expenses`,
  `payments`, `shopping`, `fixedExpenses`, `invitations`,
  `notifications`, `activity`); integer paisa everywhere, Net =
  Paid − Share + Sent − Received. Phase 3 section records the
  as-built divergences (member-ID split order, per-user groups
  until invite-accept lands, client timestamps, best-effort
  activity writes, demo-benchmark seeding).
- `docs/FIREBASE_SETUP.md` — exact pending console steps: create
  the Firestore DB (asia-south1, production mode), publish the
  rules, enable Storage, FCM notes, google-services.json + SHA-1
  already in place.
- `functions/` — Cloud Functions skeleton, NOT DEPLOYED
  (`index.js` + `package.json` + README with exact deploy steps):
  onCreate/onUpdate triggers for invitations, expenses, payments
  (notification + activity log) and a scheduled monthly-summary
  stub — the scheduled function needs the Blaze plan; triggers work
  on Spark.
- `mobile/pubspec.yaml` (Phase 3 deps): `firebase_core`,
  `firebase_auth`, `cloud_firestore`, `firebase_storage`,
  `firebase_messaging`, `fl_chart`, `pdf`, `csv`, `share_plus`,
  `url_launcher`, `google_mlkit_text_recognition` (OCR; resolves
  cleanly, unused until a later phase). Dev: `fake_cloud_firestore`
  4.4.0 (pinned: 4.5.0 needs `cloud_firestore` 7, the app pins 6).

## Backend — `backend/` (LEGACY since Phase 3)

Retired as the app's data source — see `backend/LEGACY.md`. Kept for
reference (money rules, atomic checkout, settle validation) and for
its benchmark tests (`test/api.test.js`, 11/11). Nothing in `mobile/`
connects to it any more.

- `src/app.js` — Express app, 13 endpoints (7 original + auth +
  5 fixed-expense), `requireAuth` (Bearer) on all but login.
- `src/db.js` — SQLite schema + migrations (members with bcrypt
  password hashes, shopping, expenses, settlements, fixed templates).
- `src/auth.js` — bcrypt hashing, session tokens (in-memory).
- `src/money.js` — paisa + equal-split helpers.
- `test/api.test.js` — backend tests (log in first, then call with
  the token).

## Tests — `mobile/test/`

- `money_test.dart`, `insights_test.dart`, `widget_test.dart` —
  money maths, insights, and widget flows (login, demo, welcome,
  tabs, shopping, expenses, settle, caps, receipt parser, timeline,
  monthly view, drawer, celebration, profile photo).
- `firestore_test.dart` (Phase 3) — `computeBalances` benchmark
  invariants + split/settlement validation, Firestore document
  mapping helpers, `FakeSplitNestRepository` contract (atomic
  checkout, demo-benchmark load/idempotency, payment verify flow,
  once-per-month fixed apply), the real
  `FirestoreSplitNestRepository` against `FakeFirebaseFirestore`,
  AppState email-only end-to-end + cloud-unavailable state, and
  widget tests for the demo-benchmark card and the pending-
  verification card.
- `fake_repository.dart` (Phase 3) — shared in-memory
  `FakeSplitNestRepository` used by the widget, auth, and Firestore
  tests (`.benchmark()`, `.empty()`, `.overBudget()` seeds).
