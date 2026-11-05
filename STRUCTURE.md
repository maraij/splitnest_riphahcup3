# SplitNest — Structure

**PRACTICE ONLY — NOT FOR SUBMISSION.** Shared-living expense app
(Flutter + Provider front end, Node + Express + SQLite back end).
Money rules live in `backend/` and `lib/core/money.dart`: integer
paisa, equal split remainder 1-by-1 in member-ID order, Net = Paid −
Share + Sent − Received, settlements never change total spending.

## Layout pattern (every screen)

Same AppBar style, same card style, 8pt spacing rhythm, 16pt screen
padding, 12pt card radius, 48pt minimum touch targets, section
headings in `SplitNestTheme.sectionStyle`. One home screen per
feature — no duplicated sections. Bottom tabs and drawer go to the
SAME screens, in the SAME order: Home, Shopping, Expenses, Settle Up,
then drawer-only Monthly view, Timeline, Profile.

## Flutter — `mobile/lib/`

### `core/` — theme, formatting, shared widgets (no app logic)
- `theme.dart` — light-only theme: teal `#0F766E` primary, navy
  `#1D2D44` text/headings only, gold `#EEC558` accent sparingly.
- `money.dart` — paisa parsing/formatting, equal-split maths.
- `format.dart` — date/amount display helpers.
- `constants.dart` — categories, cap categories, units.
- `widgets/` — `budget_ring.dart` (animated ring), `entrance.dart`
  (fade+slide-in), `error_banner.dart` (error + retry),
  `illustrations.dart` (Flutter-drawn nest/empty-state art),
  `member_avatar.dart` (initials, or the member's picked photo),
  `money_text.dart`, `status_pill.dart`.

### `domain/` — pure functions, no widgets, no HTTP
- `models.dart` — Member, ShoppingItem, Expense, BalanceRow,
  Balances, FixedExpense, ActivityEntry.
- `settle_plan.dart` — Smart Settle: greedy largest-debtor →
  largest-creditor from live balances.
- `insights.dart` — category breakdown, monthly summary, recurring
  bills, quick-add favourites, weekly spending, per-member
  summaries, cap spend, receipt parsing (`parseReceipt`).

### `data/` — the only place that talks HTTP
- `api_client.dart` — HTTP + Bearer token (login excepted).
- `repository.dart` — typed calls over the client; the store's only
  data source.

### `state/` — single source of truth
- `app_state.dart` — `AppState`: members, budget/balances, shopping,
  expenses, fixed templates, activity log, caps, profile photos,
  session token, logged-in member, welcome/celebration flags.
  Widgets read from it and call its methods only; every mutation
  refreshes it once. No `setState` for app data in widgets.

### `features/` — one folder per screen (screen + its own widgets)
- `splash/` — `splash_screen.dart`: logo fade+scale, coin drop-ins,
  pulse; auto-advances after ~2.5s, no tap.
- `auth/` — `login_screen.dart`: member select + password (show/hide),
  one Demo button → popup with name+ID only; demo fills the same
  form and calls the same login (no bypass).
- `home/` — `home_screen.dart`: budget ring, Your Balance card,
  Active Members, Pending Shopping, Budget Alert banner, Danger Zone
  (cap) banner; `insights_cards.dart` (category breakdown, monthly
  summary, recurring bills, category caps); `welcome_dialog.dart`
  (once per login); `celebration_dialog.dart` (saved-money popup,
  once per login, after the welcome popup).
- `shopping/` — `shopping_screen.dart`: Current/History tabs,
  add-item form, checkout bottom sheet, "Others" quick-add.
- `expenses/` — `expenses_screen.dart`: search/filter, quick-add
  favourites, per-member view, fixed-monthly list, Add Expense
  sheet (title, amount, category chips, date, payer, Equal/Custom,
  Repeat monthly, Paste receipt).
- `settle/` — `settle_screen.dart`: Balances table (only place with
  full Paid/Share), Smart Settle suggestion (prefills only),
  Settle Debt dialog.
- `monthly/` — `monthly_view_screen.dart`: the logged-in member's
  month — totals, per-category, per-expense, weekly trend bars.
- `timeline/` — `timeline_screen.dart`: read-only activity log
  (drawer only, never on Home).
- `profile/` — `profile_screen.dart`: name, member ID, month totals,
  net balance; photo edit (camera badge + "Change photo", image
  picker, stored per member in AppState). No email/role — members
  have only name + ID.

### `main.dart`
App root: splash → login → logged-in shell. The shell holds the
4-tab `NavigationBar` and the `Drawer` (same 4 tabs + Monthly view,
Timeline, Profile, Log out). Drawer tabs set the tab index; Monthly
view / Timeline / Profile are pushed routes with a back button.

## Backend — `backend/`

- `src/app.js` — Express app, 13 endpoints (7 original + auth +
  5 fixed-expense), `requireAuth` (Bearer) on all but login.
- `src/db.js` — SQLite schema + migrations (members with bcrypt
  password hashes, shopping, expenses, settlements, fixed templates).
- `src/auth.js` — bcrypt hashing, session tokens (in-memory).
- `src/money.js` — paisa + equal-split helpers.
- `test/api.test.js` — backend tests (log in first, then call with
  the token).

## Tests — `mobile/test/`

- `money_test.dart`, `insights_test.dart`, `widget_test.dart` —
  money maths, insights, and widget flows (login, demo, welcome,
  tabs, shopping, expenses, settle, caps, receipt parser, timeline,
  monthly view, drawer, celebration, profile photo).
