# SplitNest

> **This app must never be submitted as an RC³ competition — PRACTICE ONLY.**

SplitNest is a shared-living expense tracker for three roommates:
Ali (M01), Ayesha (M02) and Bilal (M03). Shopping list, multi-item
checkout that posts exactly one shared expense, manual expenses
with equal/custom/percentage splits, exact paisa accounting,
settlements with owner/admin verification, a monthly budget, an
AI household assistant, and structured local logging. Everything
runs on the device — there is no server and no cloud service.

## Key features

- **Shopping & checkout** — shared shopping list; checkout posts
  exactly one equal-split expense and marks the items Bought,
  atomically.
- **Expenses** — equal, custom and percentage splits with exact
  integer-paisa accounting (splits always sum to the amount);
  edit/delete guarded to the payer/creator or an owner/admin.
- **Settle Up** — balances (Net = Paid − Share + Sent − Received),
  Smart Settle suggestions, settlements recorded then verified or
  rejected by an owner/admin.
- **Monthly view, Timeline, insights** — per-member month totals,
  category breakdowns, weekly trends, recurring bills, category
  caps, and an activity log.
- **Fixed monthly expenses** — templates that post at most once
  per month.
- **Receipts & QR** — receipt photos stored locally, on-device
  text recognition to pre-fill an expense, QR entry for pasting
  a receipt.
- **Profile photos** — stored as local files, referenced from
  lock.json.
- **Invitations & shared households** — local-only invite codes;
  join on the same device, switch between households.
- **AI Assistant** — a household expense chatbot (drawer entry)
  that answers from the live household data. See
  [AI integration](#ai-integration-gemini).
- **Structured logging** — bounded, redacted JSON log
  (`logs.json`). See [Logging](#logging).
- **Light/dark themes** — toggled from the AppBar or the drawer,
  persisted across restarts.
- **Demo benchmark** — demo users can load the labelled PKR 5,000
  benchmark (4 expenses, 2 fixed templates, 2 shopping items)
  from Home, exactly once.

## Tech stack

| Layer | Technology |
|---|---|
| App | Flutter 3.47.9, Dart 3.13.7, Provider (single `AppState`) |
| Data | Local `lock.json` (version 1) in the app documents directory via `path_provider`; `crypto` for SHA-256 password hashing; `shared_preferences` for session, theme and household choice |
| AI | Google Gemini REST API (v1beta `generateContent`, model `gemini-2.5-flash`) via the `http` package — key only via `--dart-define`, not configured in this build |
| On-device ML | `google_mlkit_text_recognition` (receipt OCR, no cloud), `mobile_scanner` (QR entry) |
| Charts / export | `fl_chart`, `pdf`, `csv`, `share_plus`, `url_launcher` |
| Backend | None. The Node.js + Express + SQLite backend is retired (see `backend/LEGACY.md`); nothing in `mobile/` connects to it |

## Architecture / folder structure

```
splitnest-practice/
├── README.md                  # this file
├── STRUCTURE.md               # detailed file-by-file map
├── .env.example               # placeholder variable names only
├── docs/
│   ├── LOCK_JSON.md           # lock.json schema, atomicity, backup/restore
│   ├── LOGGING.md             # logs.json format, redaction, bounds
│   ├── logs-template.json     # empty logs.json structure (no real entries)
│   └── INVITATIONS.md        # local-only invites & shared households
├── backend/                   # LEGACY — retired, reference only
├── mobile/
│   ├── pubspec.yaml
│   ├── assets/lock-seed.json  # reference first-run seed (fixed salts)
│   ├── lib/
│   │   ├── main.dart          # splash → login → logged-in shell
│   │   ├── core/              # theme, money, formatting, AppLogger, widgets
│   │   ├── domain/            # pure models & rules (balances, splits, invites)
│   │   ├── data/              # SplitNestRepository + LocalJsonRepository
│   │   ├── state/             # AppState — the single source of truth
│   │   └── features/          # one folder per screen
│   │       ├── auth/ home/ shopping/ expenses/ settle/
│   │       ├── monthly/ timeline/ profile/ invite/ splash/
│   │       └── chatbot/       # AI Assistant (provider, controller, screen)
│   └── test/                  # unit + widget tests (see below)
└── .github/workflows/android-apk.yml   # debug APK build
```

Design rules: one `AppState` holds all app data and every
mutation refreshes it once; screens read from it and never touch
storage directly. The repository interface
(`SplitNestRepository`) is the seam tests substitute fakes
through. Money is integer paisa everywhere; amounts cross
boundaries as two-decimal strings. Full detail:
[STRUCTURE.md](STRUCTURE.md).

## Installation + setup

Requirements: Flutter SDK 3.47.9 (Dart 3.13.7), Android SDK
(for the APK) or Chrome (for the web preview).

```sh
cd mobile
flutter pub get
```

No accounts, console steps, or external services are needed to
run the app. The first launch seeds the three demo accounts
(hashed passwords, fresh random salts) and creates the household
on first sign-in.

Demo sign-in (seeded on first run):

| Member | Email | Password |
|---|---|---|
| Ali (M01) | `ali.demo@splitnest.app` | `ali123` |
| Ayesha (M02) | `ayesha.demo@splitnest.app` | `ayesha123` |
| Bilal (M03) | `bilal.demo@splitnest.app` | `bilal123` |

Or sign up with any email — the account lives only on this
device. Forgot password shows a 6-digit code on the device
(valid 15 minutes, single-use); no email is sent, and the
screen says plainly that anyone holding the device can reset a
password that way.

## Environment variables

The app reads **one** variable, and only from a Dart define at
build/run time — it never reads a `.env` file:

| Variable | Purpose | Required? |
|---|---|---|
| `GEMINI_API_KEY` | Google Gemini API key for the AI Assistant | No — without it the chat shows the not-configured state |

```sh
flutter run --dart-define=GEMINI_API_KEY=YOUR_KEY
```

`.env.example` at the repo root lists the placeholder name only.
Never commit a real `.env` or a real key; `.env` is git-ignored.

## API / database setup (local lock.json)

There is no API and no database server. The whole household —
users, groups, expenses, payments, shopping, fixed templates,
invitations, activity, chat history, settings — lives in one
JSON file, `lock.json`, in the app documents directory:

- Android: `/data/data/com.practice.splitnest.splitnest/app_flutter/lock.json`
- Web preview: no file — the store is in-memory only and does
  not persist across reloads; the app shows a banner saying so.
- Tests: `LockJsonStore.inMemory()` or
  `LockJsonStore.inDirectory(<temp dir>)`.

Writes are atomic (`lock.json.tmp` → rename, with a
`lock.json.bak` of the last good state). A corrupt file falls
back to the backup, then to a fresh seed, always with a plain
in-app notice — never silent data loss.

- **Back up** by copying `lock.json` (plus `logs.json`,
  `receipts/` and `profile-photos/` if they matter) off the
  device before uninstalling — **uninstalling deletes the
  documents directory and lock.json with it**.
- **Restore** by putting a saved `lock.json` back before launch.
- **Seed reference:** `mobile/assets/lock-seed.json` is the
  first-run content with fixed salts, for reference only — a real
  first run generates fresh random salts.

Full schema, atomicity, backup/restore and auth storage:
[docs/LOCK_JSON.md](docs/LOCK_JSON.md).

## AI integration (Gemini)

The AI Assistant lives in the drawer. It answers questions
about the household — spending, balances, budget usage, recent
expenses — from a summary built from the **live** AppState data
and sent with every message. The system prompt forbids inventing
figures: when the data does not contain the answer, the bot says
so instead of guessing. Chat history is stored per user in
lock.json (`chatMessages`) and loads on open.

**Current state: NOT configured.** No Gemini API key was
supplied for this build, so the chat screen shows an "AI not
configured" card with the setup steps and sending is disabled.
Nothing is sent anywhere in that state, and the live Gemini call
has not been tested against Google's servers.

To enable it:

1. Get a free key at Google AI Studio
   (<https://aistudio.google.com/apikey>).
2. Run or build with the key:
   `flutter run --dart-define=GEMINI_API_KEY=YOUR_KEY`
3. In CI, add `GEMINI_API_KEY` as a GitHub Actions secret and
   pass the same `--dart-define` flag in the build step.

The key is never hardcoded, never stored in the app, in
lock.json, or in any file in this repo, and never logged —
provider failures are logged with the HTTP status code only.
Implementation: `mobile/lib/features/chatbot/` (provider,
context, controller, screen).

## Logging

Structured logs go to `logs.json`, next to `lock.json` in the
app documents directory (in-memory only on web). Each entry is
`{timestamp, level, tag, message, data?}`; levels are
`debug` / `info` / `warn` / `error`; tags are `app`, `auth`,
`repository`, `chatbot`, `invitations`. Logged flows: app start,
auth sign-in/sign-up/demo, repository errors, household refresh
failures, chatbot calls and failures, invitation actions.

- **Secrets are never logged.** The logger redacts Gemini keys
  (`AIza…`), `api_key` / `password` / `token` / `secret` pairs,
  `Authorization: Bearer` headers, and `?key=` URL parameters
  to `[REDACTED]` (tested).
- **Bounded.** Max 500 entries / 256 KB; oldest entries are
  trimmed first, so the file cannot grow without limit.
- **Template.** `docs/logs-template.json` is the empty structure
  (`{"version": 1, "entries": []}`) — no real entries.

Full detail: [docs/LOGGING.md](docs/LOGGING.md).

## How to run

```sh
cd mobile
flutter pub get
flutter run                 # device / emulator
flutter run -d chrome       # web preview (data does not persist)
flutter run --dart-define=GEMINI_API_KEY=YOUR_KEY   # with the AI Assistant enabled
```

## Build instructions

```sh
cd mobile
flutter analyze   # must report no issues
flutter test      # full suite, see below
flutter build web # web preview build
```

### Debug APK (GitHub Actions)

Debug APKs are built by `.github/workflows/android-apk.yml` on
every push to `main` (and on manual dispatch): it runs
`flutter pub get`, `flutter analyze`, `flutter test`, then
`flutter build apk --debug` and uploads `app-debug.apk` as the
`splitnest-debug-apk` artifact. Local Gradle builds fail on the
development VM, so Actions is the debug-APK route.

### Release APK (blocked — no signing config)

There is **no release signing configuration** in this repo: no
keystore, no key alias, no passwords. A release APK is blocked
until the user supplies or creates signing credentials. Do not
invent any credential. The steps, when credentials exist:

1. **Generate a keystore** (once, on a trusted machine):
   ```sh
   keytool -genkeypair -v -keystore splitnest-release.keystore \
     -alias splitnest -keyalg RSA -keysize 2048 -validity 10000
   ```
   Keep the keystore file and its passwords safe — losing the
   keystore means the app can never be updated under the same
   signing identity.
2. **Add the signing config** to
   `mobile/android/app/build.gradle.kts` (release block
   referencing `keyAlias`, `keyPassword`, `storeFile`,
   `storePassword` from a `key.properties` file that is never
   committed — `key.properties`, `*.jks` and `*.keystore` are
   git-ignored).
3. **Store the secrets in GitHub Actions**: upload the keystore
   as a secret file (or base64-encode it into a secret), and add
   `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD` as repository
   secrets.
4. **Extend the workflow** (`.github/workflows/android-apk.yml`)
   with a release job that restores the keystore and
   `key.properties` from the secrets, runs
   `flutter build apk --release`, and uploads the release APK
   artifact.
5. Verify the release APK installs, signs in, and keeps the
   household across a restart before distributing it.

## Money rules (the important ones)

- Equal split: base share floored, remainder paisa handed out
  1-by-1 in ascending member-ID order. `1000.00 / 3 = 333.34 /
  333.33 / 333.33`; `0.01 / 3 = 0.01 / 0.00 / 0.00`.
- Custom splits must sum exactly to the amount, with unique
  known members.
- Balance formula: **Net = Paid − Share + Sent − Received**.
- Settlements never change total spending. Rejected:
  self-settlement, zero/negative amounts, unknown members,
  non-debtor sender, non-creditor recipient, over-settlement.
- Checkout is atomic (one save): items become Bought and exactly
  one expense is posted, or nothing changes.

## Benchmark (reproduce exactly)

Sign in as a demo user and tap **Load demo benchmark** on Home
(or run `flutter test` in `mobile/` — the tests reproduce it
against the local repository):

1. Checkout Milk + Rice: total `780.00`, payer Ali, equal split
   → 260.00 each.
2. Cleaning Supplies: `900.00`, payer Ayesha, equal Ali + Ayesha
   → 450.00 each.
3. Internet Bill: `1500.00`, payer Bilal, custom Ali 500 /
   Ayesha 300 / Bilal 700.
4. Electricity Bill: `1020.00`, payer Ali, equal → 340.00 each.

Expected: total spending **4200.00**, budget 5000.00, remaining
**800.00**, **84%** used, status **Near Limit**, balances Ali
**+250.00**, Ayesha **-450.00**, Bilal **+200.00** (sum 0.00).
Then settle Ayesha → Ali 250.00 (balances 0.00 / -200.00 /
+200.00) and Ayesha → Bilal 200.00 (all 0.00); spending stays
**4200.00**.

## Tests

```sh
cd mobile
flutter test
```

Test files in `mobile/test/`:

- `money_test.dart`, `insights_test.dart` — money maths, insights.
- `widget_test.dart` — login, demo, welcome, tabs, shopping,
  expenses, settle, caps, receipt parser, timeline, monthly
  view, drawer, celebration, profile photo.
- `lock_json_test.dart` — the real local repository against a
  temp-directory store and the in-memory store (persistence,
  atomic write + corrupt-file recovery, split math, balances,
  auth hashing, invitation codes, demo benchmark, payment verify
  flow, fixed-expense apply, uploads).
- `auth_test.dart` — password hashing + local auth service
  (demo sign-in, sign-up validation, duplicate rejection, reset
  flow, session restore) + AppState auth flows + login/forgot
  widget tests.
- `invitations_test.dart` — invite codes/links, the repository
  contract, AppState invite → accept → switch end-to-end,
  Invite screen widget test.
- `phase5_test.dart` — percentage splits, expense auth,
  payments, receipt OCR verify, QR, profile photos.
- `chatbot_test.dart` — household-context grounding, the Gemini
  provider against a fake HTTP client (the live call is NOT
  tested — no key was supplied), the chat controller, and
  history persistence round-trip through the real repository.
- `logger_test.dart` — secret redaction, rotation bounds, JSON
  validity, round-trip, corrupt-file recovery.
- `chatbot_widget_test.dart` — the chatbot opens from the drawer
  in the not-configured state; configured send/reply bubbles;
  empty-message and clear-history behaviour.

Verified results (Phase 7, 2026-11-07): `flutter analyze` — no
issues; `flutter test` — **206/206 pass** (171 baseline + 35
new: 16 chatbot + 14 logger + 5 chatbot widget);
`flutter build web` — succeeds.

## Honest lists

### (a) Fully implemented and tested

- Local `lock.json` store: seed, atomic writes, backup, corrupt
  recovery, web in-memory fallback — `mobile/test/lock_json_test.dart`.
- Local-only auth: sign-up, sign-in, demo sign-in (all three),
  sign-out, session restore across restarts, device-local
  6-digit-code password reset — `mobile/test/auth_test.dart`.
- Percentage splits, expense CRUD + auth, record/verify/reject
  payments, receipt OCR verify flow, QR entry, profile photos,
  invitations UI, demo benchmark card, welcome popup, light/dark
  theme toggles.
- Invitations local-only (same-device code/link accept, group
  switching, persisted household choice) —
  `mobile/test/invitations_test.dart`.
- AI chatbot: provider abstraction + Gemini REST implementation,
  household-context grounding, per-user history persisted in
  lock.json, not-configured state, chat UI — implemented and
  tested except the live call (see (c)) —
  `mobile/test/chatbot_test.dart`,
  `mobile/test/chatbot_widget_test.dart`.
- Structured logging: bounded, redacted `logs.json`, wired into
  app start, auth, repository errors, chatbot and invitations —
  `mobile/test/logger_test.dart`.

### (b) Needs external deployment

**NOTHING.** Firebase was dropped by user decision on 2026-11-07.
There is no console step, no database to create, no rules to
deploy, no provider to enable, no Cloud Function to publish.
The app runs entirely on the device. (The only optional external
step is obtaining a free Gemini API key if the AI Assistant is
wanted — see [AI integration](#ai-integration-gemini).)

### (c) Incomplete / not possible in this build

- **Cloud sync:** none — data lives in one file on one device.
- **Real Google Sign-In:** removed, no fake replacement.
- **Cross-device invites / shared households across devices:**
  invites work on the same device only.
- **Push notifications:** none (no FCM, no server).
- **Email sending:** none — no verification emails, no reset
  emails, no invite emails. The password reset is an on-device
  code, and the UI says plainly that anyone holding the device
  can reset a password that way.
- **Live AI call untested:** the Gemini provider is implemented
  and tested against a fake HTTP client, but the live call
  against Google's servers has not been run — no API key was
  supplied. The chat screen shows the not-configured state until
  a key is provided.
- **Release APK:** blocked until signing credentials are
  supplied/created — see [Release APK](#release-apk-blocked--no-signing-config).
- **On-device lock.json persistence:** verified in tests
  (temp-directory round-trips) and by the web build, but **not
  yet verified live on a real Android device** — that needs one
  live pass (install, sign in, kill the app, reopen, confirm the
  household is still there).

## Security considerations

- **Passwords** are stored as salted SHA-256 hashes in
  lock.json — never plaintext. One round of SHA-256 is not a
  slow KDF (no bcrypt/Argon2); that is an accepted limit for a
  device-local practice app, not a claim of server-grade
  password storage.
- **The Gemini API key** is supplied only via
  `--dart-define`, never hardcoded, never stored in the app, in
  lock.json, or in any committed file, and never logged. The
  logger redacts anything that looks like a key or token.
- **No server enforcement:** whoever holds the device holds the
  data. The repository enforces the app rules (owner/admin-only
  invite and verify, member-only edits of their own expenses) in
  code — there is no server to enforce them.
- **Device-local password reset:** the forgot-password flow
  displays a code on the device, so anyone holding the device
  can reset a password. The UI says so plainly.
- **No secrets in the repo:** `.env`, keystores and
  `key.properties` are git-ignored; `.env.example` carries
  placeholder names only. No Firebase config remains (dropped
  2026-11-07).

## Known limitations

- **APK:** debug APKs are built by GitHub Actions — local Gradle
  builds fail on the development VM. Release APKs are blocked
  on signing credentials (see above).
- **Auth:** local only (see above). Identity is the local account
  uid; there is no backend token and no Google account.
- **Expense history:** persisted in `lock.json` (`expenses`,
  newest first).
- **Month scope:** budget totals count the current month's
  expenses; balances are computed over all recorded expenses and
  settlements.
- **Web preview does not persist** — reload and the household
  starts fresh; the app shows a banner saying so.
