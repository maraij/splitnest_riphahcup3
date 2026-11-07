# SplitNest — Cloud Functions

**PRACTICE ONLY — NOT FOR SUBMISSION.**

Cloud Functions for the SplitNest practice app (Firebase project
`splitnest-b8071`). **NOT DEPLOYED.** The code in `index.js` is
complete and syntax-checked, but nothing here runs until it is
deployed with the Firebase CLI — and the scheduled function needs a
plan upgrade first.

## What is here

| Export | Trigger | Does |
|---|---|---|
| `onInvitationCreated` | `invitations/{id}` onCreate | Logs the invite in the group activity feed |
| `onInvitationAccepted` | `invitations/{id}` onUpdate → `accepted` | Adds the invitee to the group's `members` map + `members` subcollection; notifies the inviter |
| `onExpenseCreated` | `groups/{gid}/expenses/{id}` onCreate | Validates the integer-paisa splits sum (rules can't); logs the expense; notifies other members |
| `onPaymentCreated` | `groups/{gid}/payments/{id}` onCreate | Logs the payment; notifies the recipient |
| `onPaymentVerified` | `groups/{gid}/payments/{id}` onUpdate → `verified` | Logs the verification; notifies the sender |
| `monthlySummary` | Schedule `0 9 1 * *` Asia/Karachi | Totals last month's spending per group; notifies every member |

All writes to `notifications` and `activity` go through the Admin
SDK, which bypasses Firestore rules — clients cannot write those
collections (see `firestore.rules`).

## Deploy status: NOT DEPLOYED

- No function is live. The app currently runs entirely on the Node
  backend; nothing in the Flutter app calls these functions.
- `onCreate` / `onUpdate` triggers work on the free **Spark** plan.
- The scheduled `monthlySummary` function **requires the Blaze
  (pay-as-you-go) plan** — Cloud Scheduler does not run on Spark.
  Do not deploy `monthlySummary` until the project is upgraded to
  Blaze (console → Upgrade; Blaze still includes the free tier, but
  a billing account is required).

## Deploy instructions (exact)

Prerequisites: Node 20+, the Firebase CLI, and a Google account with
access to project `splitnest-b8071`.

```bash
# 1. Install the Firebase CLI once (if not already installed)
npm install -g firebase-tools

# 2. Log in (browser step — the account that owns splitnest-b8071)
firebase login

# 3. From the repo root (~/workspace/splitnest-practice/)
cd ~/workspace/splitnest-practice
firebase use splitnest-b8071

# 4. Install function dependencies
cd functions && npm install && cd ..

# 5a. Deploy ONLY the Firestore triggers (works on Spark):
firebase deploy --only functions:onInvitationCreated,functions:onInvitationAccepted,functions:onExpenseCreated,functions:onPaymentCreated,functions:onPaymentVerified

# 5b. Deploy the scheduled summary ONLY after upgrading to Blaze:
firebase deploy --only functions:monthlySummary

# Or deploy everything at once (Blaze only):
firebase deploy --only functions
```

Verify after deploy:

```bash
firebase functions:list          # all 6 listed, state ACTIVE
firebase functions:log           # watch for errors on first trigger
```

## Local syntax check (no deploy, no credentials)

```bash
node --check functions/index.js   # parses only; does not run
```

## Region

Functions run in `asia-south1` (Mumbai — closest region to
Pakistan; there is no Pakistan region). The schedule uses timezone
`Asia/Karachi`.
