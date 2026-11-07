# SplitNest — Invitations & Shared Households (Phase 4)

**PRACTICE ONLY — NOT FOR SUBMISSION.** How invitations work in
the practice app, as built in Phase 4 (2026-11-07).

**Status: implemented client-side, verified against
`FakeFirebaseFirestore` + the in-memory fake.** The Firestore
database itself still does not exist yet and the rules are not
deployed (see `docs/FIREBASE_SETUP.md`), so nothing has been
verified against a live Firestore DB or a second real device.
Real multi-user accept across two devices needs the Firestore DB
to exist and `firestore.rules` deployed.

## The short version

- An owner/admin invites someone **by email**. The invitee signs
  in with that email and accepts — from the "Invitations for you"
  list, or by entering a code.
- The invite **code is the invitation document's id**: 12
  characters from an unambiguous alphabet, generated with
  `Random.secure()` — never sequential, never derived from an
  email, a timestamp or a counter.
- Accepting runs **one Firestore transaction, entirely
  client-side**: verify the invite, add the user to the group's
  `members` map AND the `members` subcollection mirror, mark the
  invite accepted. It does **not** depend on the Cloud Function
  `onInvitationAccepted` (not deployed) — that Function is only a
  redundant notification path once deployed (it re-checks the same
  accepted transition and reads `acceptedBy`, which the client now
  sets; before Phase 4 the rules forbade setting `acceptedBy`, so
  the Function as written could never have fired usefully).
- After accepting, the joined group becomes the current household
  and the user can switch between their households.

## Code & link format (exact)

- **Code:** 12 characters, alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`
  (no `0`/`O`, `1`/`I`/`l`). Example: `ABCD1234EFGH`.
- **Displayed code:** grouped in fours: `ABCD-1234-EFGH`.
- **Shareable link (plain text):**
  `https://splitnest.app/join?code=ABCD1234EFGH`
  (ungrouped code in the `code` query parameter).
- **Entering a code:** the "Enter invite code" field accepts a bare
  code (`ABCD1234EFGH`), a grouped code (`ABCD-1234-EFGH`), or a
  pasted full link — the code is extracted, upper-cased, and
  dashes/spaces stripped before lookup (`parseInviteCode` in
  `mobile/lib/domain/invitations.dart`).

### What the link is NOT

`splitnest.app` is not a registered/hosted domain for this app and
**no App Links / deep-link auto-join is wired**. Tapping the link
does not open the app. The link is a convenient way to carry the
code in a message; the working mechanism is entering the code in
the app (Invite & households → Enter invite code) or accepting
from the "Invitations for you" list. True deep-link auto-join
would need App Links / Universal Links hosting config plus an
`assetlinks.json` / `apple-app-site-association` file and an
intent filter — none of that exists in this phase.

## Invitation fields (as built)

Top-level collection `invitations/{code}` — the document id IS
the code. See `docs/FIRESTORE_STRUCTURE.md` for the table.

| Field | Notes |
|---|---|
| `groupId` / `groupName` | Group being joined (name denormalised) |
| `invitedEmail` | Lower-cased + trimmed; must match the invitee's Auth email |
| `invitedBy` / `inviterName` | Inviting owner/admin (UID + display name) |
| `role` | `member` (default) or `admin` (owner-granted only) |
| `status` | `pending` \| `accepted` \| `revoked` \| `expired` |
| `createdAt` / `expiresAt` | `expiresAt = createdAt + 7 days` |
| `acceptedBy` / `acceptedAt` | Set by the accept flow (UID + time) |

## Rules (expiry, duplicates, revoke)

- **Expiry is 7 days from creation.** A stored-`pending`
  invitation past its expiry counts as **expired everywhere**:
  list filtering (`Invitation.isPending` / `effectiveStatus`),
  the accept guard (accept refuses it), and a sweep that stores
  `expired`. The sweep runs on the **admin listing path**
  (`getGroupInvitations`) and on the duplicate check during
  create — the rules only let an owner/admin write the
  `pending → expired` transition, so the invitee's own list
  (`getMyInvitations`) derives expiry without writing it.
- **No duplicate ACTIVE invitation** for the same email + group:
  creating a second pending, unexpired invite for the same email
  in the same group is rejected. Re-inviting after a revoke (or
  after expiry) is allowed.
- **Revoke** is owner/admin only, pending invitations only, via a
  confirm dialog in the UI. Revoked invitations disappear from the
  Pending list; the invitee can no longer accept them.
- **Self-invite** is rejected (inviting your own email).
- **Roles:** only owner/admin can invite or revoke (enforced in
  the repository AND the rules AND the UI gating). Granting
  `admin` additionally requires the inviter to be the group
  **owner** — a plain admin inviting as `admin` is rejected.

## The accept flow (client transaction)

`FirestoreSplitNestRepository.acceptInvitation` runs one
transaction:

1. Read `invitations/{code}`. Fail when missing, already
   accepted, revoked/expired, past `expiresAt`, or addressed to a
   different email.
2. Update `groups/{gid}`: set `members.{uid} = {role, joinedAt}`
   and `joinInvitationId = code` (audit trail of which invite let
   them in).
3. Set `groups/{gid}/members/{uid}` (mirror): display name, role,
   `joinedAt`, `invitationId`, `uid`.
4. Update the invitation: `status = accepted`,
   `acceptedBy = uid`, `acceptedAt = now`.
5. After the transaction (best-effort, outside it): an activity
   entry (`member_joined`) and the user's `groupIds` link. The
   activity write is denied by the rules until Functions deploy,
   so it is swallowed exactly like every other client activity
   write in this app — the session activity log is the Timeline
   source of truth until then.

Two rules subtleties this design works around (see
`firestore.rules`):

- The group doc is **not read inside the transaction**: the
  invitee is not a member yet, so the rules deny them a group
  read. The blind update is authorised by the rules' self-join
  branch (a pending, unexpired invitation for this group + email,
  adding only their own UID, with exactly the role the invitation
  grants), and it fails outright when the group does not exist —
  which is the existence check.
- The rules authorise the join against the **pending** invitation,
  not the accepted one: inside one transaction the invite flip and
  the join commit together, so rules see the pre-commit (pending)
  state for both. A second accept is stopped by the transaction's
  own checks (status is no longer pending on re-read) and by the
  rule requiring the UID to be absent from the members map.

## Sharing

From the invite screen, for any pending invitation:

- **Share** — system share sheet (`share_plus`) with the group
  name, the grouped code and the link.
- **WhatsApp** — `https://wa.me/?text=<prefilled message>`
  opened via `url_launcher`. When WhatsApp is not installed the
  app shows a plain message ("WhatsApp is not installed… copy
  the link instead") instead of crashing.
- **Copy link / Copy code** — clipboard + confirmation snackbar.

## Shared households / group switching

- Each user still gets their own `household-<uid>` group on first
  sign-in (Phase 3 behaviour, unchanged — the demo users' seeded
  groups and the benchmark are untouched).
- `AppState` now keeps `userGroups` (own group first, then joined
  groups, from the accepted-invitation trail + the profile's
  `groupIds`), `currentGroupId` (alias of `groupId`), and
  `currentRole` in the current group.
- Switching: Invite & households → Your households → tap a
  household. The choice persists in SharedPreferences, keyed per
  Firebase UID (`current_group_id_<uid>`), so the next launch
  re-opens the same household; a switch also updates the
  in-memory choice immediately. Users with one group always land
  on their own group, exactly as before.
- `listUserGroups` deliberately does **not** query the `members`
  map (a user cannot query groups they do not belong to, per the
  rules). It derives the list from the own-group id, the profile's
  `groupIds`, and accepted invitations for the user's email.
  A group that no longer exists is skipped, never faked.
- Member counts on the invite screen: Total members = roster
  size, Active members = roster size (every roster member counts
  as active — SplitNest has no deactivated members), Pending
  invites = pending invitations for the current group.

## What is NOT verified live

- No live Firestore DB exists yet and the rules are not deployed,
  so the rules changes below have **not** been evaluated by the
  real rules engine — they are written to match the client flows
  exactly, and covered by `mobile/test/invitations_test.dart`
  against `FakeFirebaseFirestore` (which does not enforce rules).
- Real two-device accept (two signed-in users, one invite) has
  not been run; the AppState end-to-end test in
  `mobile/test/invitations_test.dart` is the same flow against the
  fake.
- No email is actually sent: the invite travels as a code/link
  the inviter shares (Share / WhatsApp / copy). There is no SMTP
  or FCM invite delivery in this phase.

## Rules changes (Phase 4)

`firestore.rules` (deploy pending, with everything else):

1. **Invitations create:** role must be `member`, or `admin`
   only when the inviter is the group owner; `invitedEmail` must
   be a string and `expiresAt` a future timestamp.
2. **Invitations update:** the invitee's accept may now also set
   `acceptedBy` (= their own UID) and `acceptedAt`; an
   owner/admin may sweep `pending → expired`.
3. **Groups update:** new self-join branch (`canSelfJoin`): an
   invitee may add only themselves to the `members` map, with
   exactly the role the pending invitation grants, citing the
   invitation id in `joinInvitationId`. Admin name/budget edits
   are unchanged.
4. **Members mirror create:** new self-join branch: the invitee
   may create only their own mirror doc, with the role the pending
   invitation grants and the invitation id recorded. Update/delete
   stay owner/admin-only.
5. New helper `isPendingInvite(invitationId, groupId)`: the
   invitation exists, belongs to the group, is addressed to the
   signed-in user's Auth email, is `pending`, and is unexpired.

No new composite indexes were needed: the duplicate check uses
`groupId + status` and the joined-groups lookup uses
`invitedEmail + status`, both already in `firestore.indexes.json`.
