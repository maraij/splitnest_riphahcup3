# SplitNest (mobile) — PRACTICE ONLY

Flutter + Provider app for the SplitNest practice project.
See `../README.md` for the full picture (local lock.json store,
benchmark, money rules, honest lists).

## Data — local only (Phase 6)

No backend, no Firebase. Everything lives in one local JSON file,
`lock.json`, in the app documents directory, behind
`LocalJsonRepository` + `LockJsonStore`
(`lib/data/local_json_repository.dart`). Auth is local-only:
salted + SHA-256-hashed passwords in `lock.json`, session in
SharedPreferences. Full schema, atomicity, backup/restore:
`../docs/LOCK_JSON.md`. Web preview runs the same code against an
in-memory store that does not persist (reload = fresh household).

## Flow

Splash (logo, ~2.5s) → Login (Demo popup, or "Sign in with email
instead" — local email/password; no Google button, no verification)
→ Home / Shopping / Expenses / Settle Up. Log out in the drawer
returns to login. Forgot password shows a 6-digit code on the
device (15 min, single-use); no email is sent.

Demo accounts (seeded hashed on first run):

| Member | Email | Password |
|---|---|---|
| Ali (M01) | `ali.demo@splitnest.app` | `ali123` |
| Ayesha (M02) | `ayesha.demo@splitnest.app` | `ayesha123` |
| Bilal (M03) | `bilal.demo@splitnest.app` | `bilal123` |

## Theme

Light/dark with a toggle in the AppBar and the drawer. Navy
`#1D2D44`, gold accent `#EEC558` from the logo coins.

## Run

```sh
flutter pub get
flutter run
```

No `API_BASE_URL`, no server to start, no console step.

## Verify

```sh
flutter analyze   # no issues
flutter test      # 171/171 pass
flutter build web # succeeds
```
