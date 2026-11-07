# SplitNest — Invitations & Shared Households (Phase 4, local since Phase 6)

**PRACTICE ONLY — NOT FOR SUBMISSION.** How invitations work in
the practice app, as built in Phase 4 (2026-11-07) and moved to
the local `lock.json` store in Phase 6 (2026-11-07, Firebase
dropped by user decision).

**Status: implemented, verified against the real
`LocalJsonRepository` (in-memory lock.json store) + the
in-memory fake.** Invitations are **local-only**: codes are
generated and redeemed on the **same device**. There is no
server, no email delivery, and no cross-device join — a second
device cannot accept an invite from this device. See
[docs/LOCK_JSON.md](LOCK_JSON.md) for the store.

## The short version

- An owner/admin invites someone **by email**. The invitee signs
  in with that email on the same device and accepts — from the
  "Invitations for you" list, or by entering a code.
- The invite **code is the invitation's id**: 12 characters from
  an unambiguous alphabet, generated with `Random.secure()` —
  never sequential, never derived from an email, a timestamp or
  a counter.
- Accepting is **one local save**: verify the invite, add the
  user to the group's roster, mark the invite accepted — all in
  the same `lock.json` document write, so it cannot half-apply.
  The old Firestore transaction and the `onInvitationAccepted`
  Cloud Function are gone with Firebase.
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

One entry in the `invitations[]` array of `lock.json` — the
entry's `id` IS the code. See [docs/LOCK_JSON.md](LOCK_JSON.md)
for the full schema.

| Field | Notes |
|---|---|
| `id` | The invite code (12 chars) |
| `groupId` / `groupName` | Group being joined (name denormalised) |
| `invitedEmail` | Lower-cased + trimmed; must match the invitee's local account email |
| `invitedBy` / `inviterName` | Inviting owner/admin (local account uid + display name) |
| `role` | `member` (default) or `admin` (owner-granted only) |
| `status` | `pending` \| `accepted` \| `revoked` \| `expired` |
| `createdAt` / `expiresAt` | `expiresAt = createdAt + 7 days` |
| `acceptedBy` / `acceptedAt` | Set by the accept flow (local account uid + time) |

## Rules (expiry, duplicates, revoke)

- **Expiry is 7 days from creation.** A stored-`pending`
  invitation past its expiry counts as **expired everywhere**:
  list filtering (`Invitation.isPending` / `effectiveStatus`),
  the accept guard (accept refuses it), and a sweep that stores
  `expired`. The sweep runs on the **admin listing path**
  (`getGroupInvitations`) and on the duplicate check during
  create — the local repository enforces the owner/admin-only
  write; the invitee's own list (`getMyInvitations`) derives
  expiry without writing it.
- **No duplicate ACTIVE invitation** for the same email + group:
  creating a second pending, unexpired invite for the same email
  in the same group is rejected. Re-inviting after a revoke (or
  after expiry) is allowed.
- **Revoke** is owner/admin only, pending invitations only, via a
  confirm dialog in the UI. Revoked invitations disappear from the
  Pending list; the invitee can no longer accept them.
- **Self-invite** is rejected (inviting your own email).
- **Roles:** only owner/admin can invite or revoke (enforced in
  the repository AND the UI gating — there are no server rules
  any more, so the repository is the enforcement point).
  Granting `admin` additionally requires the inviter to be the
  group **owner** — a plain admin inviting as `admin` is rejected.

## The accept flow (local, one save)

`LocalJsonRepository.acceptInvitation` (see
`mobile/lib/data/local_json_repository.dart`):

1. Load `lock.json`. Fail when the invite is missing, already
   accepted, revoked/expired, past `expiresAt`, or addressed to
   a different email.
2. Add the invitee to the group's roster (`members` entry:
   local account uid, member id, role, display name, `joinedAt`,
   `invitationId` = code).
3. Update the invitation: `status = accepted`,
   `acceptedBy = uid`, `acceptedAt = now`.
4. Append an activity entry (`member_joined`) and link the group
   to the user — then save the document **once** (atomic write +
   backup, see [docs/LOCK_JSON.md](LOCK_JSON.md)). A second
   accept is stopped by step 1 (status is no longer pending on
   re-read).

## Sharing

From the invite screen, for any pending invitation:

- **Share** — system share sheet (`share_plus`) with the group
  name, the grouped code and the link.
- **WhatsApp** — `https://wa.me/?text=<prefilled message>`
  opened via `url_launcher`. When WhatsApp is not installed the
  app shows a plain message ("WhatsApp is not installed… copy
  the link instead") instead of crashing.
- **Copy link / Copy code** — clipboard + confirmation snackbar.

Sharing only carries the code — the invitee must be on the
**same device** (same `lock.json`) to accept it. Sending the
code to someone on another device does nothing: their device
has a different household file and no such invitation.

## Shared households / group switching

- Each user still gets their own `household-<uid>` group on first
  sign-in (Phase 3 behaviour, unchanged — the demo users' seeded
  groups and the benchmark are untouched). The uid is now the
  **local account uid** (`demo-M01`… / `u-…`), not a Firebase UID.
- `AppState` now keeps `userGroups` (own group first, then joined
  groups, from the accepted-invitation trail + the profile's
  `groupIds`), `currentGroupId` (alias of `groupId`), and
  `currentRole` in the current group.
- Switching: Invite & households → Your households → tap a
  household. The choice persists in SharedPreferences, keyed per
  local account uid (`current_group_id_<uid>`), so the next launch
  re-opens the same household; a switch also updates the
  in-memory choice immediately. Users with one group always land
  on their own group, exactly as before.
- `listUserGroups` derives the list from the own-group id, the
  profile's `groupIds`, and accepted invitations for the user's
  email. A group that no longer exists is skipped, never faked.
- Member counts on the invite screen: Total members = roster
  size, Active members = roster size (every roster member counts
  as active — SplitNest has no deactivated members), Pending
  invites = pending invitations for the current group.

## What is NOT verified live

- No live on-device run has been done yet: the flows are covered
  by `mobile/test/invitations_test.dart` against the real
  `LocalJsonRepository` (in-memory store) and the AppState
  end-to-end tests, but `lock.json` persistence on a real Android
  device (documents directory, backup/restore) still needs one
  live pass.
- Real two-device accept is **not possible** in this build by
  design (local-only store) — the AppState end-to-end test in
  `mobile/test/invitations_test.dart` is the same flow with two
  AppStates sharing one in-memory store, i.e. two accounts on
  one device.
- No email is actually sent: the invite travels as a code/link
  the inviter shares (Share / WhatsApp / copy). There is no SMTP
  or push invite delivery in this phase — and none is planned
  while the store stays local.

## Enforcement (local — no server rules any more)

`firestore.rules` was deleted in Phase 6 with Firebase. The
rules below are now enforced by `LocalJsonRepository` in code
(and gated in the UI); there is no server to back them up, so
whoever holds the device holds the data:

1. **Invitations create:** role must be `member`, or `admin`
   only when the inviter is the group owner; `invitedEmail` must
   be a string and `expiresAt` a future timestamp.
2. **Invitations update:** the invitee's accept may set
   `acceptedBy` (= their own local uid) and `acceptedAt`; an
   owner/admin may sweep `pending → expired`.
3. **Groups update (join):** an invitee may add only themselves
   to the roster, with exactly the role the pending invitation
   grants, citing the invitation id. Admin name/budget edits
   stay owner/admin-only.
4. **Accept guards:** the invitation must exist, belong to the
   group, be addressed to the accepting user's account email, be
   `pending`, and be unexpired.
