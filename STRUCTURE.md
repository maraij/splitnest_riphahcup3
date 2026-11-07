# SplitNest — Structure

**PRACTICE ONLY — NOT FOR SUBMISSION.** Shared-living expense app
(Flutter + Provider front end, **local `lock.json` data store since
Phase 6** — Firebase dropped entirely 2026-11-07, see
[docs/LOCK_JSON.md](docs/LOCK_JSON.md); the Node backend is retired,
see `backend/LEGACY.md`).
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
- `theme.dart` — light/dark themes with a toggle (AppBar + drawer);
  navy `#1D2D44`, gold `#EEC558` accent sparingly.
- `money.dart` — paisa parsing/formatting, equal-split maths.
- `format.dart` — date/amount display helpers.
- `constants.dart` — categories, cap categories, units.
- `services/app_logger.dart` (Phase 7) — `AppLogger`: structured
  JSON log entries `{timestamp, level, tag, message, data?}` to
  `logs.json` next to lock.json (atomic writes, same pattern as
  lock.json); levels debug/info/warn/error; secret redaction
  (Gemini keys, `api_key`/`password`/`token` pairs, Bearer
  headers, `?key=` params → `[REDACTED]`); bounded — max 500
  entries / 256 KB, oldest trimmed first; memory-only on web and
  when no file access is supplied (tests). See `docs/LOGGING.md`.
- `widgets/` — `budget_ring.dart` (animated ring), `entrance.dart`
  (fade+slide-in), `error_banner.dart` (error + retry),
  `illustrations.dart` (Flutter-drawn nest/empty-state art),
  `member_avatar.dart` (initials, or the member's picked photo),
  `money_text.dart`, `status_pill.dart`.

### `domain/` — pure functions, no widgets, no HTTP
- `models.dart` — Member, ShoppingItem, Expense, BalanceRow,
  Balances, FixedExpense, ActivityEntry, PaymentRecord.
- `chat_message.dart` (Phase 7) — `ChatMessage` (id, userId, role
  `user`/`assistant`, text, timestamp) + JSON mapping; history is
  per account uid, stored in lock.json `chatMessages`.
- `balances.dart` — `computeBalances` (Paid/Share/Sent/Received,
  monthly total, used %, status) + `settlementError` validation.
  Pure; the local repository hands it lock.json-shaped data.
- `settle_plan.dart` — Smart Settle: greedy largest-debtor →
  largest-creditor from live balances.
- `insights.dart` — category breakdown, monthly summary, recurring
  bills, quick-add favourites, weekly spending, per-member
  summaries, cap spend, receipt parsing (`parseReceipt`).
- `invitations.dart` — invite code/link format + parse, expiry
  rules (local-only since Phase 6, see `docs/INVITATIONS.md`).

### `data/` — the only place that touches storage (all local now)
- `repository.dart` — `SplitNestRepository` interface (the seam
  tests substitute fakes through), `LocalDataException`,
  `UnavailableSplitNestRepository`, shared validators. (The old
  `CloudDataException` / `cloudUnavailableMessage` are gone.)
  Phase 7 added the chatbot-history methods (`getChatMessages` /
  `addChatMessage` / `clearChatMessages`, per account uid).
- `local_json_repository.dart` — `LocalJsonRepository` +
  `LockJsonStore`: the whole household in one `lock.json`
  document (version, users, groups, expenses, payments, shopping,
  fixedExpenses, invitations, activity, **chatMessages** since
  Phase 7, settings); atomic writes (`lock.json.tmp` → rename,
  `lock.json.bak` of the last good state), corrupt-file recovery
  with a plain notice, first-run seed (`buildSeedLockJson`),
  receipts/profile photos as local files under the documents
  directory. A pre-Phase-7 file without `chatMessages` still
  loads (the collection defaults to empty). Repository failures
  are logged via the injected `AppLogger` (plain message only).
  No UID translation: expenses/payments/splits are keyed by
  member id directly.
- `lock_file_access.dart` — abstract `LockFileAccess`
  (`isPersistent`, `notice`, `readText`, `writeAtomic`,
  `writeBytes`) + `InMemoryLockFileAccess` (web + tests).
- `lock_file_io.dart` — native file access via `dart:io` +
  `path_provider` (documents directory); imported only through
  the conditional import in `local_json_repository.dart`, so web
  never compiles `dart:io`.
- `lock_file_io_stub.dart` — web access: always in-memory, with
  the plain notice that web preview data does not persist.
- `local_auth_service.dart` — `LocalAuthService` /
  `RealLocalAuthService`: local accounts in `lock.json` users,
  session = account uid in SharedPreferences
  (`local_session_uid`), demo sign-in, device-local 6-digit-code
  password reset (code displayed on-device, 15 min, single-use,
  in-memory only). `restoreSession()` is a read — it does NOT
  emit on the auth-state stream (a stale restore must never
  overwrite a newer login).
- `password_hash.dart` — `generateSalt()` (16 random bytes),
  `hashPassword` = SHA-256(salt + password), `verifyPassword`.
  Salted hash only, never plaintext. Single-round SHA-256 is not
  a slow KDF — accepted limit for a device-local practice app.
- `demo_accounts.dart` — the three demo accounts (Ali/Ayesha/
  Bilal, `ali.demo@splitnest.app` etc., member ids M01–M03).
- `demo_benchmark.dart` — the benchmark data (Milk+Rice 780,
  Cleaning 900, Internet 1500, Electricity 1020) as pure data;
  never auto-seeded, demo-only.
- (Deleted in Phase 6: `firestore_repository.dart`,
  `firebase_auth_service.dart`, `google_auth_service.dart`,
  `api_client.dart`. No `http` package, no Firebase packages.)

### `state/` — single source of truth
- `app_state.dart` — `AppState`: members, budget/balances, shopping,
  expenses (full persisted history, not session-only), payments,
  fixed templates, activity log, caps, profile photos, **local
  session**, logged-in member, welcome/celebration flags,
  `dataNotice` (store recovery / web notice, shown as a banner by
  `main.dart`). Its ONLY data source is the injected
  `SplitNestRepository` (local JSON in the app, fakes in tests).
  No backend token, no `API_BASE_URL`. Widgets read from it and
  call its methods only; every mutation refreshes it once. No
  `setState` for app data in widgets. Phase 7: holds the injected
  `AppLogger` (`logger`) and logs auth, refresh failures and
  invitation actions; exposes the chatbot seam —
  `householdSummaryForChat()` (live totals/balances/recent
  expenses for the AI), `loadChatHistory()` /
  `saveChatMessage()` / `clearChatHistory()` (per-user history
  through the repository).

### `features/` — one folder per screen (screen + its own widgets)
- `splash/` — `splash_screen.dart`: logo fade+scale, coin drop-ins,
  pulse; auto-advances after ~2.5s, no tap.
- `auth/` — `login_screen.dart`: demo popup + "Sign in with email
  instead" (local email/password, no Google button, no fake);
  `signup_screen.dart`: creates a local account directly (no
  verification email — none is ever sent);
  `forgot_password_screen.dart`: two-step local reset (email →
  on-device 6-digit code → new password) with plain honesty
  notes. (The old `verification_screen.dart` was deleted in
  Phase 6.)
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
  picker, stored as a local file under `profile-photos/`, path in
  `lock.json`).
- `chatbot/` (Phase 7) — `chatbot_screen.dart`: the AI Assistant
  screen (drawer entry; bubbles, timestamps, typing indicator,
  error banner with retry, clear-history action, and the
  **not-configured card** — the real state of this build, since no
  Gemini key was supplied: it explains the setup and disables
  sending); `chat_controller.dart`: `ChatController` (message
  list, sending/error state, history load/save/clear through
  AppState, empty-message and not-configured guards);
  `data/ai_provider.dart`: `AiChatProvider` interface +
  `GeminiChatProvider` (Gemini REST v1beta `generateContent`
  via the `http` package; key only from
  `--dart-define=GEMINI_API_KEY=...`, never stored or logged);
  `data/chat_context.dart`: `chatbotSystemPrompt` (answers only
  from the supplied summary, never invents figures) +
  `buildHouseholdContext` (live totals, balances, budget usage,
  recent expenses, or an explicit "no data loaded" text).

### `main.dart`
App root: splash → login → logged-in shell. One shared
`LockJsonStore` is wired into both `LocalJsonRepository` and
`RealLocalAuthService`, then into `AppState`; the same store's
file access backs the `AppLogger` (logs.json), which is also
wired into the repository and AppState, and logs "SplitNest
started" on launch. The shell holds the
4-tab `NavigationBar` and the `Drawer` (same 4 tabs + Monthly view,
Timeline, Profile, **AI Assistant**, Log out). Drawer tabs set the tab index; Monthly
view / Timeline / Profile / AI Assistant are pushed routes with a back button.
No `Firebase.initializeApp()`, no cloud init. If the store reports
a notice (web in-memory mode, or a corrupt-file recovery),
`main.dart` shows a dismissible amber banner with the plain
message — the app never crashes and never shows fake data.
If the store itself is down, the app shows a plain "Local data
unavailable" state with Retry, via `UnavailableSplitNestRepository`
and `AppState.useRepository()`. No screen reads any backend; all
data comes from `lock.json`.

## Docs — `docs/`

- `LOCK_JSON.md` — the local store: schema (every collection +
  fields + types), atomicity, backup/restore, where the file lives
  on Android, web fallback, seeding, auth storage. The reference
  seed snapshot is `mobile/assets/lock-seed.json` (fixed salts;
  a real first run generates fresh random salts).
- `LOGGING.md` (Phase 7) — the structured log: `logs.json`
  format, levels, what is logged, the redaction rules, and the
  500-entry / 256 KB bounds. The empty structure for the ZIP is
  `docs/logs-template.json` (no real entries).
- `INVITATIONS.md` — invitations & shared households, local-only
  since Phase 6 (code = invitation id, same-device accept, group
  switching).

Deleted in Phase 6: `docs/FIREBASE_SETUP.md`,
`docs/FIRESTORE_STRUCTURE.md`, `firestore.rules`,
`storage.rules`, `firebase.json`, `firestore.indexes.json`,
`functions/` (whole directory), `mobile/android/app/google-services.json`.

## Backend — `backend/` (LEGACY since Phase 3)

Retired as the app's data source — see `backend/LEGACY.md`. Kept for
reference (money rules, atomic checkout, settle validation) and for
its benchmark tests (`test/api.test.js`, 11/11). Nothing in `mobile/`
connects to it any more. (Its doc still describes the Firebase
migration historically; the backend itself is untouched by Phase 6.)

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
- `lock_json_test.dart` (Phase 6) — the real `LocalJsonRepository`
  against a real temp-directory store and the in-memory store:
  persistence round-trip, atomic write + corrupt-file recovery
  (backup restore, fresh seed), split math, balances, auth hashing
  (different salts → different hashes, wrong-password rejection),
  invitation codes local, demo benchmark load + idempotency,
  payment verify flow, once-per-month fixed apply, uploads.
- `auth_test.dart` (Phase 6 rewrite) — password hashing +
  `RealLocalAuthService` (demo sign-in, sign-up validation,
  duplicate rejection, reset flow, session restore across
  AppState instances) + AppState auth flows + login/forgot
  widget tests.
- `invitations_test.dart` — pure code/link helpers, the
  repository contract twice (in-memory fake + real local repo),
  AppState invite → accept → switch end-to-end (two AppStates,
  one shared store), Invite screen widget test.
- `phase5_test.dart` — Phase 5 behaviours (percentage splits,
  expense auth, payments, receipt OCR verify, QR, profile
  photos).
- `chatbot_test.dart` (Phase 7) — household-context grounding
  (real figures; explicit "no data loaded" text), the Gemini
  provider against a fake HTTP client (reply parsing, HTTP-error
  handling, key never in any log entry; the live call is NOT
  tested — no key was supplied), the controller (send/receive,
  empty-message validation, not-configured blocks sending,
  failure + retry, clear history), and history persistence
  round-trip through the real local repository (per user, plus
  old lock.json files without `chatMessages` still loading).
- `logger_test.dart` (Phase 7) — secret redaction (Gemini keys,
  key/value pairs, Bearer headers, `?key=` params, sensitive data
  keys), the 500-entry and 256 KB rotation bounds, JSON validity,
  round-trip reload, corrupt-file recovery.
- `chatbot_widget_test.dart` (Phase 7) — the app starts and the
  chatbot opens from the drawer in the not-configured state
  (card shown, sending disabled); configured fake provider
  send/reply bubbles; empty message does nothing; clear history.
- `fake_repository.dart` — shared in-memory
  `FakeSplitNestRepository` used by the widget, auth, and
  invitation tests (`.benchmark()`, `.empty()`, `.overBudget()`).
  Phase 7 added the in-memory chat history to the fake.
- (Deleted in Phase 6: `test/firestore_test.dart`, replaced by
  `lock_json_test.dart`; `fake_cloud_firestore` removed from
  dev dependencies.)
