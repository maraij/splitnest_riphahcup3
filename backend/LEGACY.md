# backend/ — LEGACY (retired as the app's data source)

**PRACTICE ONLY — NOT FOR SUBMISSION.**

As of Phase 3 of the production rebuild (2026-11-07), this Node.js +
Express + SQLite backend is **no longer the app's data source**. The
Flutter app now reads and writes **Cloud Firestore only**
(`mobile/lib/data/firestore_repository.dart` behind the
`SplitNestRepository` interface in `mobile/lib/data/repository.dart`).
No screen, state class, or repository in `mobile/` makes HTTP calls to
this backend any more; the `http` package dependency was removed from
`mobile/pubspec.yaml`, and the old `mobile/lib/data/api_client.dart`
was deleted.

## Why it is kept

- **Reference implementation.** The money rules the Firestore layer
  re-implements live here in executable form: integer paisa, equal
  split with remainder 1-by-1 in ascending member-ID order
  (`src/money.js`), Net = Paid − Share + Sent − Received, atomic
  shopping checkout (one transaction: exactly one expense + items
  marked Bought), settle validation (debtor → creditor, amount ≤
  outstanding), fixed templates applied at most once per month.
- **Benchmark tests.** `test/api.test.js` (11/11 passing, 2026-11-05)
  encodes the exact benchmark the Firestore migration was verified
  against: Milk+Rice 780.00, Cleaning 900.00, Internet 1500.00,
  Electricity 1020.00 → total 4200.00, 84% of the PKR 5,000 budget,
  nets Ali +250.00 / Ayesha −450.00 / Bilal +200.00, settlements to
  all-zero without changing spending. The same benchmark is now
  covered in Flutter by `mobile/test/firestore_test.dart` against the
  Firestore repository (in-memory fake + `FakeFirebaseFirestore`).
- **Local fallback for experiments only.** It can still be started
  (`npm install && npm start`, port 3000) for ad-hoc reference
  checks, but nothing in the app connects to it.

## What replaced it, file by file

| Backend piece | Firestore replacement |
|---|---|
| `src/app.js` endpoints | `FirestoreSplitNestRepository` methods (`addExpense`, `checkout`, `recordPayment`, `verifyPayment`, `applyFixedExpense`, …) |
| `src/db.js` SQLite schema | `docs/FIRESTORE_STRUCTURE.md` (collections + rules in `firestore.rules`) |
| `src/auth.js` bcrypt + in-memory tokens | Firebase Auth (Phase 2); the Firebase UID is the session |
| `src/money.js` | `mobile/lib/core/money.dart` + `mobile/lib/domain/balances.dart` |
| Seeded `splitnest.db` | `ensureGroup` seeds the group structure on first sign-in; benchmark expenses load only via the in-app **Load demo benchmark** action (demo users only, clearly labelled `isDemoData: true`) |

## Do not

- Do not point the app back at this backend (no `API_BASE_URL` any
  more; there is no HTTP client left in the app to point).
- Do not run both writers at once: if this backend is started for a
  reference check, it writes only its own `splitnest.db` and never
  touches Firestore.
- Do not delete this directory in a later phase without first moving
  the benchmark expectations in `test/api.test.js` somewhere durable
  (they are the executable record of the money rules).
