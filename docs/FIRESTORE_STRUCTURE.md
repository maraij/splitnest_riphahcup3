# SplitNest — Firestore Data Model

**PRACTICE ONLY — NOT FOR SUBMISSION.** Production Firestore model for
the SplitNest practice app (Flutter + Firebase).

**Status — Phase 3 implemented (2026-11-07): Firestore is now the
app's only data source.** `mobile/lib/data/firestore_repository.dart`
(`FirestoreSplitNestRepository`) implements the `SplitNestRepository`
interface in `mobile/lib/data/repository.dart`; `AppState` reads and
writes through it exclusively. The Node/SQLite backend is retired —
see `backend/LEGACY.md`. **The database itself still does not exist
yet** (console creation is a pending manual step) and the rules are
not deployed, so nothing has been verified against a live Firestore
DB; coverage is via `mobile/test/firestore_test.dart` (in-memory fake
repository + `FakeFirebaseFirestore` against the real repository
class). See `docs/FIREBASE_SETUP.md` for the pending console steps.

Project: **SplitNest** (`splitnest-b8071`, Spark plan).
Rules: `firestore.rules` (repo root). Storage rules: `storage.rules`.

## Phase 3 implementation notes (as built — divergences from design)

1. **Equal-split remainder order is ascending member-ID order
   (`M01, M02, M03`), not ascending Firebase UID order.** The
   original design said UID order; the app has always split in
   member-ID order and the benchmark depends on it, so the
   repository computes shares with `equalSplit` on member IDs and
   then maps the keys to UIDs for storage.
2. **Shopping and fixed-expense templates ARE in Firestore now**
   (`groups/{gid}/shopping`, `groups/{gid}/fixedExpenses`) — the
   design said "later"; Phase 3 moved them in so checkout and
   fixed-apply could be transactional.
3. **Group per user, for now.** `ensureGroup` creates a deterministic
   group `household-<uid>` owned by the signing-in user. The rules
   make the `members` map client-read-only and the invite-accept
   Function is not deployed, so a client cannot join another user's
   group yet. True shared households (one group, three Firebase
   users) need the invite-accept Function (Phase 4). The repository
   interface and the in-memory test fake already model the shared
   household; only the group-resolution step is per-user.
4. **Timestamps are client time (`Timestamp.now()`), not
   `FieldValue.serverTimestamp()`.** `fake_cloud_firestore` 4.4.0
   cannot handle the server-timestamp sentinel (it needs
   `cloud_firestore` 7; the app pins 6), so the real repository
   could not be tested against the fake with sentinels. Client
   timestamps are also immediately readable while offline, where a
   pending server timestamp reads as null. These are audit
   timestamps only — ordering uses `expenseDate` / client-side
   sorting, never `createdAt`.
5. **`paidBy` / `splits` / `fromUid` / `toUid` / `payerUid` keys are
   Firebase UIDs when known, legacy member IDs (`M01`…) otherwise.**
   Only the signing-in user has a UID in a fresh group; the other
   two roster members are known by member ID until they sign in and
   their mirror doc records a UID. The repository translates at the
   boundary (`_uidByMember` / `_memberByUid`); the app only ever
   sees member IDs.
6. **Activity writes are best-effort from the client.** Rules deny
   client activity writes until Functions deploy, so
   `logActivity` catches the denial and continues; the app's
   session activity log remains the Timeline source of truth, and
   `getActivity` reads whatever the subcollection holds (empty
   until Functions write it).
7. **Seeding.** `ensureGroup` seeds the group structure on first
   sign-in: group doc (`budgetPaisa` 500000 = PKR 5,000, `currency`
   PKR, creator as `owner` in the `members` map) + the 3-member
   roster mirror. Benchmark expenses are **never auto-seeded**; they
   load only through `loadDemoBenchmark` (deterministic doc ids
   `demo-benchmark-1..4`, `demo-fixed-internet/electricity`,
   `demo-shopping-milk/rice`; expense docs carry
   `isDemoData: true`), exposed in the app as a **Load demo
   benchmark** card visible only to demo users, hidden once loaded,
   idempotent (second call returns 0 and writes nothing).
8. **Balances are computed client-side** in the pure
   `mobile/lib/domain/balances.dart` (`computeBalances`): Paid /
   Share / Sent / Received all-time; total spending = current
   month's expenses only (undated/unparseable dates excluded from
   the monthly total); `usedPercent` rounded as
   `(total/limit*10000).round()/100`; status ≥84 Near Limit, ≥50 On
   Track, else Under Budget. Payments count in Net as soon as they
   are `recorded`; verification is a trust flag, not a second
   posting.
9. **Shopping list order is creation order** (`createdAt`, then doc
   id). Doc ids are random auto-ids, so sorting by id alone would
   scramble the list — and the checkout title (`Shopping: Milk,
   Rice`) is built from this order.

## Money rules (carried over unchanged from SQLite)

- **All amounts are integer paisa** (`int` in Firestore). Never store
  floats/doubles for money. Display formatting stays in
  `mobile/lib/core/money.dart` (`formatPaisa`).
- **Splits are per-member integer paisa.** For every expense,
  `sum(splits.values) == amountPaisa` exactly.
- **Equal split:** base share = `floor(amountPaisa / n)`; the remainder
  paisa are handed out 1-by-1 to the first members in ascending
  member-ID order (`M01, M02, M03`) — as built in Phase 3 (the
  original design said ascending UID order; see Phase 3 notes above
  for why member-ID order was kept).
- **Net balance per member** (per group):
  `Net = Paid − Share + Sent − Received`
  where Paid = sum of expenses the member paid for, Share = sum of
  their splits, Sent = sum of their payments to others,
  Received = sum of payments received from others.
- **Settlements (payments) never change total spending.** A payment
  moves money between members only; it does not create or reduce an
  expense. Total group spending = sum of `amountPaisa` over expenses.

## Collections overview

```
/users/{uid}                                  (one doc per Firebase Auth user)
/users/{uid}/notifications/{notificationId}   (per-user inbox, Functions-written)
/groups/{groupId}                             (household)
/groups/{groupId}/members/{uid}               (membership mirror, queryable)
/groups/{groupId}/expenses/{expenseId}
/groups/{groupId}/payments/{paymentId}
/groups/{groupId}/shopping/{itemId}           (Phase 3: shopping list)
/groups/{groupId}/fixedExpenses/{id}          (Phase 3: recurring templates)
/groups/{groupId}/activity/{activityId}       (Functions-written audit log)
/invitations/{invitationId}                   (top-level, keyed by invite)
```

### Why `members` is BOTH a map on the group doc and a subcollection

- The **`members` map on `groups/{groupId}`** is the source of truth
  for security rules: `resource.data.members[request.auth.uid]`
  is a single cheap read, and rules can check roles without an extra
  `get()` call. Keys are Firebase UIDs; values are small
  `{role, joinedAt}` objects.
- The **`members` subcollection** is the queryable mirror (list members
  with display names/photos, paginate, listen for joins/leaves).
  Cloud Functions keep the two in sync on join/leave/role change;
  clients never write the map directly (rules deny it — see
  `firestore.rules`).

## `users/{uid}`

One document per Firebase Auth user. Created on first sign-in
(Google sign-in or email/password); the client may create/update
only its own doc.

| Field | Type | Notes |
|---|---|---|
| `displayName` | string | From Google profile or chosen at sign-up |
| `email` | string | Lower-cased; matches `request.auth.token.email` |
| `photoUrl` | string? | Google photo URL, or Storage path after upload |
| `legacyMemberId` | string? | Link to the old Node backend member (`M01`…), used only during migration |
| `groupId` | string? | The user's household group (`household-<uid>` as built in Phase 3); written best-effort by `ensureGroup` |
| `fcmTokens` | map<string, Timestamp> | Device tokens, keyed by token; pruned by Functions on send failure |
| `createdAt` | Timestamp | Client timestamp (`Timestamp.now()` as built; see Phase 3 notes) |
| `updatedAt` | Timestamp | Updated on profile edits |

Read/write: the owning user only (`request.auth.uid == uid`).
No other user can read another user's doc (names/photos are read
from the group `members` subcollection instead).

## `users/{uid}/notifications/{notificationId}`

Per-user inbox. **Written only by Cloud Functions** (Admin SDK
bypasses rules); clients can only mark their own as read.

| Field | Type | Notes |
|---|---|---|
| `type` | string | `invitation` \| `expense_added` \| `payment_recorded` \| `payment_verified` \| `monthly_summary` \| `reminder` |
| `groupId` | string | Group the event belongs to (empty for account-level) |
| `title` | string | Short, user-facing |
| `body` | string | One-line detail, includes the amount in PKR |
| `data` | map | `{expenseId?, paymentId?, invitationId?, actorUid?}` — deep-link targets |
| `read` | bool | Default `false`; client may set `true` |
| `createdAt` | Timestamp | Server timestamp |

Read: owning user only. Write: nobody from a client (Functions only).
Update: owning user may change `read` only (rules enforce that no
other field changes).

## `groups/{groupId}`

One document per household (the practice app has one household:
Ali, Ayesha, Bilal — but the model supports many).

| Field | Type | Notes |
|---|---|---|
| `name` | string | e.g. `SplitNest Household` |
| `createdBy` | string (uid) | Group creator; first `owner` |
| `createdAt` | Timestamp | |
| `budgetPaisa` | int | Monthly household budget, integer paisa (SQLite `household_budget.limit_paisa`; PKR 5,000 = `500000`) |
| `currency` | string | Always `PKR` for now |
| `members` | map<string, map> | `{uid: {role, joinedAt}}` — rules source of truth (see above) |
| `inviteCode` | string? | Optional short join code (later phase; not used while email invites are the flow) |

Read: any UID present in `members`. Write: only `owner`/`admin`
may update `name`/`budgetPaisa`; the `members` map itself is
client-read-only (Functions maintain it on invite accept / removal).
Delete: `owner` only.

### Roles

- `owner` — created the group; can do everything, including
  deleting the group and promoting/demoting admins.
- `admin` — can invite, revoke invites, verify payments, delete
  expenses, manage members.
- `member` — can add expenses, record their own payments, read
  everything in the group.

## `groups/{groupId}/members/{uid}`

Queryable mirror of the `members` map (kept in sync by Functions).

| Field | Type | Notes |
|---|---|---|
| `displayName` | string | Denormalised from `users/{uid}` at join time |
| `photoUrl` | string? | Denormalised likewise |
| `role` | string | `owner` \| `admin` \| `member` |
| `legacyMemberId` | string? | `M01`… during migration |
| `joinedAt` | Timestamp | |

Read: group members. Write: `owner`/`admin` only (role changes,
removal); the doc is created by the invite-accept Function.

## `groups/{groupId}/expenses/{expenseId}`

Mirrors SQLite `expenses` + `expense_shares` in a single document
(the shares are a map, not a join table).

| Field | Type | Notes |
|---|---|---|
| `title` | string | e.g. `Groceries — Milk & Rice` |
| `category` | string | One of the app categories (see `mobile/lib/core/constants.dart`) |
| `amountPaisa` | int | > 0, integer paisa |
| `expenseDate` | Timestamp | Date the expense happened (not `createdAt`) |
| `paidBy` | string (uid or member id) | Who paid; must be a group member (UID when known, else legacy member ID — see Phase 3 notes) |
| `splitType` | string | `equal` \| `custom` |
| `splits` | map<string, int> | `{uid-or-member-id: sharePaisa}` — must sum to `amountPaisa`; every group member present for `equal` splits |
| `receiptUrl` | string? | Firebase Storage download URL (see `storage.rules`) |
| `receiptPath` | string? | Storage path, e.g. `receipts/{groupId}/{expenseId}/receipt.jpg` |
| `fixedExpenseId` | string? | Link to the recurring template it was generated from |
| `isDemoData` | bool | `true` only for the labelled demo-benchmark expenses (Phase 3); absent/`false` otherwise |
| `note` | string? | Optional free text |
| `createdBy` | string (uid) | Who recorded it |
| `createdAt` | Timestamp | Client timestamp (see Phase 3 notes) |
| `updatedAt` | Timestamp | Client timestamp (see Phase 3 notes) |

Read: group members. Create: any group member (payer must be a
member; `splits` must sum to `amountPaisa` — enforced by rules).
Update: `owner`/`admin` only. Delete: `owner`/`admin` only.

## `groups/{groupId}/payments/{paymentId}`

Mirrors SQLite `settlements`. A payment is a **record** first and a
**verified fact** second — the two-step flow is the point.

| Field | Type | Notes |
|---|---|---|
| `fromUid` | string (uid) | Sender; must equal `request.auth.uid` on create |
| `toUid` | string (uid) | Recipient; must be a group member, `!= fromUid` |
| `amountPaisa` | int | > 0, integer paisa |
| `status` | string | `recorded` → `verified` |
| `recordedBy` | string (uid) | == `fromUid` |
| `verifiedBy` | string? (uid) | Set by the verifying owner/admin |
| `verifiedAt` | Timestamp? | |
| `note` | string? | e.g. `JazzCash` |
| `createdAt` | Timestamp | Client timestamp (see Phase 3 notes) |

Read: group members. Create: any group member, only for themselves
(`fromUid == request.auth.uid`, `status == 'recorded'`).
Update: only `owner`/`admin` may change `status` to `verified`
(and set `verifiedBy`/`verifiedAt`); members may not touch a payment
after recording it. Delete: `owner`/`admin` only.

> **Why verification matters:** an unverified payment still counts
> in the ledger preview (so the sender sees the effect immediately),
> but the settle-up screen must show it as *pending verification*.
> A later phase decides whether unverified payments count in the
> authoritative Net — the rules only enforce *who* can flip the flag.

## `invitations/{invitationId}`

Top-level (not under a group) so the invitee can read it before
they are a member of the group.

| Field | Type | Notes |
|---|---|---|
| `groupId` | string | Group being joined |
| `groupName` | string | Denormalised for the invite email/screen |
| `invitedEmail` | string | Lower-cased; must match the invitee's Auth email |
| `invitedBy` | string (uid) | Inviting owner/admin |
| `role` | string | Role granted on accept (`member` by default) |
| `status` | string | `pending` \| `accepted` \| `revoked` \| `expired` |
| `createdAt` | Timestamp | |
| `expiresAt` | Timestamp | `createdAt + 7 days` |

Read: the inviter, group owner/admins, and the invitee
(`request.auth.token.email == invitedEmail`). Create: group
owner/admin only. Update: owner/admin may set `status = 'revoked'`;
the invitee may set `status = 'accepted'` (the accept Function then
adds them to the group). Delete: nobody from a client.

## `groups/{groupId}/shopping/{itemId}` (Phase 3)

Shopping list. Checkout is a **transaction**: it re-reads each item
doc, requires `status == 'Pending'`, posts exactly one expense
(`Shopping: <item1>, <item2>`, category `Groceries`) and marks the
items `Bought` with `checkoutExpenseId` — or nothing changes. A
second checkout of the same items fails.

| Field | Type | Notes |
|---|---|---|
| `title` | string | e.g. `Milk` |
| `unit` | string | `pack` \| `dozen` \| `bottle` \| `bag` |
| `requestedQty` | int | > 0 |
| `status` | string | `Pending` \| `Bought` |
| `checkoutExpenseId` | string? | Set on checkout |
| `createdBy` | string (uid) | Who added it |
| `createdAt` | Timestamp | Client timestamp (see Phase 3 notes) |

## `groups/{groupId}/fixedExpenses/{id}` (Phase 3)

Recurring monthly templates. Applying is a **transaction** guarding
`lastAppliedMonth` together with the expense post, so a template
applies at most once per `YYYY-MM`. Applying is explicit only (no
auto-posting).

| Field | Type | Notes |
|---|---|---|
| `title` | string | e.g. `Internet` |
| `category` | string | App category |
| `amountPaisa` | int | > 0, integer paisa |
| `payerUid` | string (uid or member id) | Who pays when applied |
| `splitMemberUids` | list<string> | Member IDs/UIDs sharing the expense |
| `lastAppliedMonth` | string? | `YYYY-MM` of the last applied month, or absent |
| `createdBy` | string (uid) | Who created it |
| `createdAt` | Timestamp | Client timestamp (see Phase 3 notes) |

## `groups/{groupId}/activity/{activityId}`

Append-only audit log, mirroring the app's Timeline screen.
**Functions-written only** (Admin SDK); clients have read-only
access. **As built in Phase 3:** the client also attempts a
best-effort write on expense/payment/member events (rules deny it
until Functions deploy, so the attempt is caught and dropped); the
app's session activity log remains the Timeline source of truth
until then.

| Field | Type | Notes |
|---|---|---|
| `type` | string | `expense_added` \| `expense_deleted` \| `payment_recorded` \| `payment_verified` \| `member_joined` \| `member_left` \| `budget_changed` \| `invite_sent` |
| `actorUid` | string (uid) | Who did it |
| `actorName` | string | Denormalised for display |
| `summary` | string | Human-readable line, e.g. `Ali added Groceries — PKR 780.00` |
| `amountPaisa` | int? | When the event has an amount |
| `refId` | string? | `expenseId` / `paymentId` / `invitationId` |
| `createdAt` | Timestamp | Server timestamp |

Read: group members. Write: nobody from a client.

## Required composite indexes

Single-field queries inside one group's subcollection need no
composite index. These do — create them in the Firebase console
(Functions / Firestore → Indexes) or let the console's error link
generate them on first use:

| Collection | Fields | Purpose |
|---|---|---|
| `groups/{gid}/expenses` | `paidBy` ASC, `expenseDate` DESC | Per-member expense history |
| `groups/{gid}/expenses` | `category` ASC, `expenseDate` DESC | Category breakdown |
| `groups/{gid}/expenses` | `fixedExpenseId` ASC, `expenseDate` DESC | Recurring-template history |
| `groups/{gid}/payments` | `fromUid` ASC, `createdAt` DESC | Payments sent by a member |
| `groups/{gid}/payments` | `toUid` ASC, `createdAt` DESC | Payments received by a member |
| `groups/{gid}/payments` | `status` ASC, `createdAt` DESC | Pending-verification queue |
| `groups/{gid}/activity` | `type` ASC, `createdAt` DESC | Filtered timeline |
| `invitations` (collection) | `invitedEmail` ASC, `status` ASC | Invitee's pending invites |
| `invitations` (collection) | `groupId` ASC, `status` ASC | Group's outstanding invites |
| `users/{uid}/notifications` | `read` ASC, `createdAt` DESC | Unread inbox |

No collection-group indexes are needed: expenses/payments/activity
are always queried within one group.

## What is NOT in Firestore

- **Monthly budget history** (`household_budget`) — the current
  month's `budgetPaisa` lives on the group doc; per-month history
  would be `groups/{gid}/budgets/{yyyy-MM}`.
- **Auth sessions / passwords** — Firebase Auth replaces the
  bcrypt + in-memory token scheme entirely; no password hashes are
  ever stored in Firestore.
- **Monthly caps + profile photos** — caps and photo paths stay in
  `SharedPreferences` (local) for now; Storage upload of profile
  photos is Phase 5.

Shopping and fixed-expense templates **are** in Firestore since
Phase 3 (see the sections above); the earlier "later" mapping is
done.

## Migration status (Phase 3 done — what remains)

Phase 3 (2026-11-07) completed the migration: the app's only data
source is Firestore; the Node backend is retired (see
`backend/LEGACY.md`). What is still outstanding, in order:

1. **Console steps** (manual, see `docs/FIREBASE_SETUP.md`): create
   the Firestore database (production mode, `asia-south1`), deploy
   `firestore.rules` / `storage.rules`, enable Storage and the
   Email/Password provider. Nothing has been verified against a live
   DB yet.
2. **Cloud Functions deploy** (Phase 4): invite-accept (adds the
   invitee to the group's `members` map + mirror), activity-log and
   notification triggers. Until then: one group per Firebase user
   (`household-<uid>`), activity client writes are best-effort
   no-ops, and no notifications are produced.
3. **Shared household** follows from (2): once invite-accept lands,
   the three demo users can share one group instead of three
   per-user groups; the repository interface already supports it.
4. **Live verification pass**: one live sign-up/sign-in + benchmark
   load on a device/emulator after the console steps, to confirm
   the rules accept the Phase 3 write shapes (group create with the
   creator as owner, expense create with UID-keyed splits, payment
   verify by owner).
