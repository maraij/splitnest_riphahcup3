# SplitNest — lock.json: the local data store (Phase 6)

**PRACTICE ONLY — NOT FOR SUBMISSION.** Since Phase 6 (2026-11-07,
user decision) the app has **no backend and no cloud**: every
household record lives in one JSON file, `lock.json`, in the app
documents directory on the device. Firebase was dropped entirely
— there is no Firestore database, no Firebase Auth, no Storage,
no Functions, no `google-services.json`. See the README for the
full status.

## Where the file lives

| Platform | Location |
|---|---|
| Android (real device / emulator) | The app documents directory from `path_provider`: `/data/data/com.practice.splitnest.splitnest/app_flutter/lock.json` (needs root or `adb run-as` / a file-manager backup to reach; the app itself never needs the path) |
| Web preview (`flutter build web`) | No file — the store is **in-memory only**. Reloading the page starts a fresh household. The app shows a plain banner saying so. |
| Tests | `LockJsonStore.inMemory()` (no files) or `LockJsonStore.inDirectory(<temp dir>)` (real files, for persistence round-trip tests) |

Alongside `lock.json` the store keeps:

- `lock.json.bak` — a copy of the **last good state**, written
  before every successful replace (see Atomicity).
- `lock.json.tmp` — the write-in-progress file, renamed over
  `lock.json` on success. Never read as data; a leftover `.tmp`
  after a crash is ignored and overwritten by the next write.
- `receipts/<groupId>/<expenseId>/receipt.jpg` — receipt photos
  (10 MB cap each), referenced by `receiptUrl` / `receiptPath`.
- `profile-photos/<uid>/photo.jpg` — profile photos (5 MB cap
  each), referenced by `photoUrl`.
- `logs.json` — the structured app log (Phase 7): bounded,
  redacted, same directory. See [docs/LOGGING.md](LOGGING.md).
  It is a separate file, not a collection inside lock.json.

## Schema (version 1)

One JSON object. `version` must be `1`; any other version, a
non-object document, or a missing collection makes the file
count as corrupt (see Recovery). Amounts are **integer paisa**
everywhere; dates are ISO-8601 strings.

```json
{
  "version": 1,
  "users": [],
  "groups": [],
  "expenses": [],
  "payments": [],
  "shopping": [],
  "fixedExpenses": [],
  "invitations": [],
  "activity": [],
  "chatMessages": [],
  "settings": {"budgetPaisa": 500000, "theme": "light"}
}
```

### `users[]` — local accounts

| Field | Type | Notes |
|---|---|---|
| `id` | string | Local account uid: `demo-M01`… for the three demo users, `u-<millis>-<hex>` for sign-ups |
| `email` | string | Lower-cased; unique (case-insensitive) |
| `displayName` | string | |
| `memberId` | string | `M01` / `M02` / `M03`… — the member this account acts as |
| `passwordSalt` | string | 32-char hex, 16 random bytes, fresh per user |
| `passwordHash` | string | SHA-256 hex of `salt + password`. **Salted hash only — never plaintext.** One round of SHA-256 is not a slow KDF (no bcrypt/Argon2); that is an accepted limit for a device-local practice app, not a claim of server-grade password storage |
| `isDemo` | bool | True for the three seeded demo users |
| `photoUrl` | string \| null | Local file path of the profile photo, or null |
| `createdAt` | string | ISO-8601 |

### `groups[]` — households

| Field | Type | Notes |
|---|---|---|
| `id` | string | `household-<uid>` for a user's own group |
| `name` | string | e.g. `SplitNest Household` |
| `budgetPaisa` | int | Monthly budget, default 500000 (= PKR 5,000) |
| `currency` | string | `PKR` |
| `createdBy` | string | Account uid that created the group |
| `createdAt` | string | ISO-8601 |
| `members` | array | Roster entries: `{uid, memberId, role, displayName, photoUrl, joinedAt}`. `role` is `owner` / `admin` / `member` |

### `expenses[]`

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `groupId` | string | |
| `title` | string | |
| `category` | string | |
| `amountPaisa` | int | |
| `date` | string | ISO-8601 |
| `paidBy` | string | **Member id** (`M01`…), not an account uid |
| `splitType` | string | `equal` / `custom` / `percentage` |
| `splits` | object | `{memberId: paisa}` — always sums exactly to `amountPaisa` |
| `createdBy` | string | Account uid |
| `createdAt` / `updatedAt` | string | ISO-8601 |
| `isDemo` | bool | True for benchmark expenses |
| `receiptUrl` / `receiptPath` | string \| null | Both hold the **same local file path** (no download URL exists) |
| `fixedExpenseId` | string \| null | Set when the expense came from a fixed template |

### `payments[]` — settlements

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `groupId` | string | |
| `senderId` / `recipientId` | string | Member ids |
| `amountPaisa` | int | |
| `status` | string | `recorded` → `verified` / `rejected` |
| `recordedBy` | string | Account uid |
| `verifiedBy` / `verifiedAt` | string \| null | |
| `rejectedBy` / `rejectedAt` | string \| null | |
| `createdAt` | string | ISO-8601 |

### `shopping[]`

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `groupId` | string | |
| `name` | string | |
| `quantity` | number | |
| `unit` | string | |
| `status` | string | `pending` / `bought` |
| `createdBy` / `createdAt` | string | |

### `fixedExpenses[]` — monthly templates

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `groupId` | string | |
| `title` / `category` | string | |
| `amountPaisa` | int | |
| `payerId` | string | Member id |
| `splitMemberIds` | array of string | Member ids sharing the cost |
| `lastAppliedMonth` | string \| null | `YYYY-MM` of the last month it was applied — apply is once per month |
| `createdBy` / `createdAt` | string | |

### `invitations[]` — local-only invites

The invitation **id IS the code** (12 unambiguous characters;
see `docs/INVITATIONS.md`). Invites are generated and redeemed
on the **same device only** — there is no delivery, no email, no
cross-device join.

| Field | Type | Notes |
|---|---|---|
| `id` | string | The invite code |
| `groupId` / `groupName` | string | Group being joined |
| `invitedEmail` | string | Lower-cased; must match the invitee's account email |
| `invitedBy` / `inviterName` | string | Inviting owner/admin (uid + display name) |
| `role` | string | `member` (default) or `admin` (owner-granted only) |
| `status` | string | `pending` \| `accepted` \| `revoked` \| `expired` |
| `createdAt` / `expiresAt` | string | `expiresAt = createdAt + 7 days` |
| `acceptedBy` / `acceptedAt` | string \| null | Set by the accept flow |

### `activity[]` — Timeline log

| Field | Type | Notes |
|---|---|---|
| `groupId` | string | |
| `type` | string | e.g. `expense_added`, `payment_recorded`, `member_joined`, `invite_sent` |
| `title` | string | |
| `amount` | string | Display amount, e.g. `780.00` |
| `memberId` | string | |
| `detail` | string | |
| `timestamp` | string | ISO-8601 |
| `actorUid` | string | Account uid |

### `chatMessages[]` — AI chatbot history (Phase 7)

One entry per chat message, keyed by the owning account uid —
history is per user, so two accounts on one device never see
each other's chats. The AI assistant screen
(`mobile/lib/features/chatbot/`) loads these on open and appends
on every send/reply; clearing history deletes the user's rows.
The messages contain only the chat text — never an API key.

| Field | Type | Notes |
|---|---|---|
| `id` | string | `chat-<millis>-<random>` |
| `userId` | string | Local account uid that owns the message |
| `role` | string | `user` or `assistant` |
| `text` | string | The message text |
| `timestamp` | string | ISO-8601 |

A lock.json written before Phase 7 has no `chatMessages`
collection — that is **not** corruption: the store defaults it
to an empty list on load (and the repository does the same for
an already-cached document), so old files keep working.

### `settings`

| Field | Type | Notes |
|---|---|---|
| `budgetPaisa` | int | Default household budget, 500000 |
| `theme` | string | `light` / `dark` (also persisted in SharedPreferences as `theme_mode`) |

## Atomicity — how a write works

Every mutation saves the **whole document** in one step:

1. The current `lock.json` (if it exists) is copied to
   `lock.json.bak` — the last good state.
2. The new document is written to `lock.json.tmp` in the same
   directory, with `flush: true`.
3. `lock.json.tmp` is renamed over `lock.json` (atomic on the
   same filesystem).

A crash mid-write leaves either the old `lock.json` or the new
one — never a half-written file. A leftover `.tmp` is ignored.
Checkout and fixed-expense apply are single saves: items become
Bought and exactly one expense is posted, or nothing changes.

## Recovery — never silently lose data

Read order on load:

1. **`lock.json` parses** → normal load. No notice.
2. **`lock.json` missing** → normal first run: the store seeds
   a fresh household (see Seeding) and saves it. No notice.
3. **`lock.json` corrupt** (bad JSON, wrong version, missing
   collection) → try **`lock.json.bak`**:
   - Backup parses → it is restored as the live file
     (`recoveredFromBackup = true`) and the app shows a plain
     banner: *"lock.json was damaged, so your last good backup
     was restored. Check your recent expenses — anything since
     that backup may be missing."*
   - Backup also unreadable → start from a fresh seed
     (`seededFresh = true`) with the banner: *"lock.json and its
     backup were both unreadable, so a fresh household was
     started. Previous data could not be recovered."*

A recovery is **never silent**: `LockJsonStore.lastNotice`
carries the message, `AppState.dataNotice` surfaces it, and
`main.dart` shows it as a dismissible amber banner. The store
never invents data and never reports a failed save as success —
a save failure raises `LocalDataException` ("Local data
unavailable — the household file could not be read.") and the
UI says so plainly.

## Seeding — first run

On first run the store seeds **only the three demo accounts**
(hashed passwords, fresh random salts — see `users[]`):

| Member | Email | Password | Member id |
|---|---|---|---|
| Ali | `ali.demo@splitnest.app` | `ali123` | M01 |
| Ayesha | `ayesha.demo@splitnest.app` | `ayesha123` | M02 |
| Bilal | `bilal.demo@splitnest.app` | `bilal123` | M03 |

No group and no expenses are seeded. Each demo user gets their
own household (`household-demo-M01`…) on first sign-in via
`ensureGroup` (PKR 5,000 budget, 3-member roster). The benchmark
expenses are **not** preloaded — a demo user loads them from Home
via **Load demo benchmark** (labelled DEMO), exactly once
(idempotent). See `mobile/lib/data/demo_benchmark.dart`.

`mobile/assets/lock-seed.json` is the **reference/distribution
seed snapshot**: the same first-run content, but with **fixed
salts** so the file is stable and diffable. It is a reference
copy only — a real first run generates fresh random salts per
user (see `buildSeedLockJson` in
`mobile/lib/data/local_json_repository.dart`). Do not ship the
seed file as the live database; do not edit its hashes by hand.

## Back up / restore — how the user copies lock.json off the device

There is **no cloud backup** (Firebase was dropped). The whole
household is one file, so backup is copying that file:

- **Back up:** copy `lock.json` (and optionally
  `lock.json.bak`, plus the `receipts/` and `profile-photos/`
  folders if receipts/photos matter) off the device — e.g. via
  `adb pull`, Android file transfer, or a file-manager app.
  Do it before uninstalling the app: **uninstalling deletes the
  app documents directory and lock.json with it**.
- **Restore:** put a previously saved `lock.json` back in the
  documents directory before launching the app (same filename,
  `version: 1`, all collections present). A corrupt restored
  file falls back to `lock.json.bak` as above; a bad restore
  never silently overwrites good data — the backup copy is only
  replaced by a successful save.
- **Moving to a new device:** copy the file to the new device's
  documents directory the same way. Accounts, groups, expenses,
  invitations and settings move with it. (The password-reset
  code flow is device-local — see Auth below — so keep the
  passwords themselves safe; the file holds salted hashes, not
  plaintext, but anyone holding the file and the device can
  reset a password from the login screen.)

## Auth — local accounts in lock.json

See `mobile/lib/data/local_auth_service.dart` and
`mobile/lib/data/password_hash.dart`.

- **Sign-up** creates a local account directly (validated email
  + password ≥ 6 chars): fresh random salt, SHA-256(salt +
  password) stored; the user is signed in immediately. **No
  email verification — no email is ever sent.**
- **Sign-in** verifies the password against the stored salt +
  hash. Wrong-password and unknown-email share one message
  ("Invalid email or password.") so the screen does not reveal
  which accounts exist.
- **Session** is the account uid in SharedPreferences key
  `local_session_uid`; the next launch restores it.
- **Demo sign-in** verifies the seeded hashed demo password
  (`ali123` / `ayesha123` / `bilal123`).
- **Forgot / reset (device-local only):** the forgot-password
  screen generates a 6-digit code, valid 15 minutes, single-use,
  kept only in memory — and **displays the code on the device**.
  No email is sent; the screen says so plainly, and that anyone
  holding the device can reset the password this way. Entering
  the code + a new password (≥ 6 chars) re-hashes with a fresh
  salt and signs the user in.
- **No Google Sign-In.** The button was removed in Phase 6 —
  no fake button, no placeholder.

## Web fallback

On web, `dart:io` and `path_provider` do not exist, so the store
uses an in-memory document through the same code paths
(conditional import in `local_json_repository.dart`:
`lock_file_io_stub.dart` on web, `lock_file_io.dart` on native).
The in-app notice reads: *"Web preview: data is kept in memory
only and does not persist — reload the page and the household
starts fresh."* Receipt/profile-photo uploads return null on web
(the UI says the file could not be saved). `flutter build web`
must keep passing — it is a gate.

## What is NOT in this file

- No server rules, no access control beyond the app's own
  checks: whoever holds the device holds the data. The
  repository enforces the app rules (owner/admin-only invite
  and verify, member-only edits of their own expenses, and so
  on) in code — there is no server to enforce them.
- No sync, no multi-device households, no push, no email.
  Those are listed honestly in the README as not possible in
  this build.
