# SplitNest — Firestore Data Model

**PRACTICE ONLY — NOT FOR SUBMISSION.** Production Firestore model for
the SplitNest practice app (Flutter + Firebase). This is the design
document; the database does **not** exist yet and no data has been
migrated. The Node/SQLite backend (`backend/`) is still the live data
source in Phase 1 — this model is what a later phase migrates to.

Project: **SplitNest** (`splitnest-b8071`, Spark plan).
Rules: `firestore.rules` (repo root). Storage rules: `storage.rules`.

## Money rules (carried over unchanged from SQLite)

- **All amounts are integer paisa** (`int` in Firestore). Never store
  floats/doubles for money. Display formatting stays in
  `mobile/lib/core/money.dart` (`formatPaisa`).
- **Splits are per-member integer paisa.** For every expense,
  `sum(splits.values) == amountPaisa` exactly.
- **Equal split:** base share = `floor(amountPaisa / n)`; the remainder
  paisa are handed out 1-by-1 to the first members in ascending UID
  order. (SQLite used ascending member-ID order — `M01, M02, M03`;
  Firestore uses ascending Firebase UID order. Same rule, different
  key. A migration must re-derive splits from UIDs, not copy SQLite
  share rows blindly.)
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
| `fcmTokens` | map<string, Timestamp> | Device tokens, keyed by token; pruned by Functions on send failure |
| `createdAt` | Timestamp | `FieldValue.serverTimestamp()` |
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
| `paidBy` | string (uid) | Who paid; must be a group member |
| `splitType` | string | `equal` \| `custom` |
| `splits` | map<string, int> | `{uid: sharePaisa}` — must sum to `amountPaisa`; every group member present for `equal` splits |
| `receiptUrl` | string? | Firebase Storage download URL (see `storage.rules`) |
| `receiptPath` | string? | Storage path, e.g. `receipts/{groupId}/{expenseId}/receipt.jpg` |
| `fixedExpenseId` | string? | Link to the recurring template it was generated from |
| `note` | string? | Optional free text |
| `createdBy` | string (uid) | Who recorded it |
| `createdAt` | Timestamp | Server timestamp |
| `updatedAt` | Timestamp | Server timestamp |

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
| `createdAt` | Timestamp | Server timestamp |

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

## `groups/{groupId}/activity/{activityId}`

Append-only audit log, mirroring the app's Timeline screen.
**Functions-written only** (Admin SDK); clients have read-only
access.

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

## What is NOT in Firestore (stays in the Node backend for now)

- **Shopping list** (`shopping_items`) — still served by the Node
  backend in Phase 1; a `groups/{gid}/shopping/{itemId}` collection
  is the obvious later mapping (`title`, `unit`, `requestedQty`,
  `status`, `checkoutExpenseId`).
- **Fixed-expense templates** (`fixed_expenses`) — later mapping:
  `groups/{gid}/fixedExpenses/{id}` with `title`, `category`,
  `amountPaisa`, `payerUid`, `splitMemberUids`, `dayOfMonth`.
- **Monthly budget history** (`household_budget`) — the current
  month's `budgetPaisa` lives on the group doc; per-month history
  would be `groups/{gid}/budgets/{yyyy-MM}`.
- **Auth sessions / passwords** — Firebase Auth replaces the
  bcrypt + in-memory token scheme entirely; no password hashes are
  ever stored in Firestore.

## Migration notes (for a later phase)

1. Create Firebase Auth users for Ali / Ayesha / Bilal (email or
   Google) and record their UIDs against `legacyMemberId`
   (`M01`/`M02`/`M03`).
2. Create one group; set the `members` map + `members`
   subcollection from the three UIDs.
3. Copy expenses with `splits` re-derived in UID order
   (equal-split remainder rule); copy settlements as `payments`
   with `status = 'verified'` (they were already settled in the
   old system).
4. Keep the Node backend read-only during the cutover; do not run
   both writers at once.
