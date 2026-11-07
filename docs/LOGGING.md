# SplitNest — structured logging (Phase 7)

**PRACTICE ONLY — NOT FOR SUBMISSION.** The app writes structured
logs to one JSON file, `logs.json`, next to `lock.json` in the app
documents directory. There is no remote logging, no crash
reporting service, and no log upload of any kind.

## Where the file lives

| Platform | Location |
|---|---|
| Android (real device / emulator) | The app documents directory from `path_provider`, next to `lock.json`: `/data/data/com.practice.splitnest.splitnest/app_flutter/logs.json` |
| Web preview (`flutter build web`) | No file — entries are kept **in memory only** for the session, exactly like lock.json on web |
| Tests | `AppLogger.inMemory()` (no files) or `AppLogger(access: InMemoryLockFileAccess())` |

Alongside `logs.json` the logger keeps `logs.json.bak` (the last
good state, written before every replace) and `logs.json.tmp`
(the write-in-progress file, renamed over `logs.json` on success)
— the same atomic-write pattern as lock.json.

## Format

One JSON object, schema version 1:

```json
{
  "version": 1,
  "entries": [
    {
      "timestamp": "2026-11-07T15:00:00.000",
      "level": "info",
      "tag": "auth",
      "message": "Signed in",
      "data": {"method": "demo"}
    }
  ]
}
```

- `timestamp` — ISO-8601, local device time.
- `level` — `debug` | `info` | `warn` | `error`.
- `tag` — the subsystem: `app`, `auth`, `repository`, `chatbot`,
  `invitations`.
- `message` — a short plain sentence.
- `data` — optional extra fields (status codes, counts, method
  names). Never a password, token or API key.

`docs/logs-template.json` is the empty structure
(`{"version": 1, "entries": []}`) for the ZIP — it contains no
real entries.

## What is logged

| Flow | Entries |
|---|---|
| App start | `app` / `info` — "SplitNest started" |
| Auth | `auth` / `info` on sign-in, sign-up, demo sign-in, sign-out; `auth` / `warn` on a failed sign-in or sign-up (method only, never the credential) |
| Repository errors | `repository` / `error` — "Local store call failed" with the redacted error text |
| Household refresh failure | `app_state` / `error` — "Household refresh failed" |
| Chatbot | `chatbot` / `info` on a reply shown and on history cleared; `chatbot` / `error` on a failed call (HTTP status only); `chatbot` / `warn` on an empty Gemini reply |
| Invitations | `invitations` / `info` on send/accept; `invitations` / `warn` on a failed send, revoke or accept |

A failed log write never fails the call it describes — the
entry stays in memory for the session and the write is dropped
silently.

## Secrets are never logged

Every message and every data value passes through
`AppLogger.redact` before it is stored. The redaction rules
(`mobile/lib/core/services/app_logger.dart`):

- Gemini API keys (`AIza…` + 20 or more characters) →
  `[REDACTED]`.
- `api_key` / `password` / `token` / `secret` / `bearer` key-value
  pairs (`key=value`, `key: value`) → the value becomes
  `[REDACTED]`.
- `Authorization: Bearer <token>` header lines → the token
  becomes `[REDACTED]`.
- `?key=…` / `&token=…` / `&api_key=…` URL query parameters →
  the value becomes `[REDACTED]`.
- Data-map values under a sensitive key (`password`, `token`,
  `secret`, `api_key`, `authorization`, …) → `[REDACTED]`
  wholesale, whatever the value looks like.

Redaction is the safety net, not the plan: callers must still
avoid passing secrets to the logger in the first place. The
Gemini API key in particular is never logged — provider failures
are logged with the HTTP status code only.

## Bounds — the file cannot grow without limit

- **Max 500 entries** (`defaultMaxLogEntries`).
- **Max 256 KB** of entries JSON (`defaultMaxLogBytes`).

When either bound is exceeded the oldest entries are trimmed
first, until both bounds hold again (at least one entry is
always kept). Trimming happens in memory on every log call, so
the persisted file never exceeds the bounds either. Both bounds
are constructor parameters of `AppLogger` and are covered by
tests (`mobile/test/logger_test.dart`).

## Reading the log

Copy `logs.json` off the device the same way as `lock.json`
(see `docs/LOCK_JSON.md` — back up / restore). It is plain
JSON: `jq . logs.json`, or open it in any text editor. There is
no in-app log viewer — the file is the viewer.

## Implementation

`mobile/lib/core/services/app_logger.dart` (`AppLogger`).
Wired in `mobile/lib/main.dart` (file-backed, sharing the
lock.json store's file access), into `LocalJsonRepository` and
`AppState`. Tests: `mobile/test/logger_test.dart` (redaction,
rotation bounds, JSON validity, round-trip, corrupt-file
recovery).
