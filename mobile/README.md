# SplitNest (mobile) — PRACTICE ONLY

Professional Flutter + Provider app for the SplitNest practice project.
See `../README.md` for the full picture (backend, benchmark, money rules).

## Flow

Splash (logo, ~1.8s) → Member login (tap Ali / Ayesha / Bilal — no
password, selection only, not verified identity) → Home / Shopping /
Expenses & Settle. Log out in the AppBar returns to login.

## Theme

Light only, white background, primary navy `#1D2D44`, gold accent
`#EEC558` from the logo coins. No dark theme, no teal.

## Run

```sh
flutter pub get
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000  # web
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000   # Android emulator
```

## Verify

```sh
flutter analyze   # no issues
flutter test      # 17/17 pass
flutter build web --dart-define=API_BASE_URL=http://127.0.0.1:3000
```
