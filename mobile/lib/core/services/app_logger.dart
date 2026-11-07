/// Structured app logging (Phase 7).
///
/// One JSON file, `logs.json`, next to `lock.json` in the app
/// documents directory (see docs/LOGGING.md): every entry is
/// `{timestamp, level, tag, message, data?}`. The file is bounded
/// (default 500 entries / 256 KB, oldest entries trimmed first)
/// so it can never grow without limit.
///
/// Secrets are NEVER logged: every message and every data value
/// passes through [AppLogger.redact], which replaces anything that
/// looks like an API key, token, password or secret with
/// `[REDACTED]` — including Gemini keys (`AIza…`) and `key=…`
/// query parameters. Callers must still avoid passing secrets in
/// the first place; redaction is the safety net, not the plan.
///
/// On web (or when the documents directory cannot be resolved)
/// the logger keeps entries in memory only, exactly like lock.json
/// — nothing is written, nothing throws, and the app keeps working.
/// A logger built with no file access at all (the default) is
/// memory-only too, which is what tests use.
library;

import 'dart:async';
import 'dart:convert';

import '../../data/lock_file_access.dart';

/// The file names, relative to the app documents directory.
const String logsJsonFileName = 'logs.json';
const String logsJsonBackupFileName = 'logs.json.bak';
const String logsJsonTmpFileName = 'logs.json.tmp';

/// The schema version written into every logs.json.
const int logsJsonVersion = 1;

/// Default bounds (see docs/LOGGING.md).
const int defaultMaxLogEntries = 500;
const int defaultMaxLogBytes = 256 * 1024;

enum LogLevel { debug, info, warn, error }

class AppLogger {
  AppLogger({
    LockFileAccess? access,
    this._accessLoader,
    this.maxEntries = defaultMaxLogEntries,
    this.maxBytes = defaultMaxLogBytes,
  }) : _providedAccess = access;

  /// Memory-only logger (tests, and the default when no file
  /// access is supplied). Entries accumulate in memory; nothing
  /// is ever written to disk.
  factory AppLogger.inMemory() =>
      AppLogger(access: InMemoryLockFileAccess());

  final int maxEntries;
  final int maxBytes;

  final LockFileAccess? _providedAccess;
  final Future<LockFileAccess> Function()? _accessLoader;
  LockFileAccess? _resolvedAccess;

  final List<Map<String, dynamic>> _entries = [];

  /// The entries currently held in memory, oldest first.
  /// A copy — mutating it never affects the logger.
  List<Map<String, dynamic>> get entries =>
      List<Map<String, dynamic>>.unmodifiable(_entries);

  Future<LockFileAccess?> _access() async {
    final resolved = _resolvedAccess;
    if (resolved != null) return resolved;
    final provided = _providedAccess;
    if (provided != null) {
      _resolvedAccess = provided;
      return provided;
    }
    final loader = _accessLoader;
    if (loader == null) return null;
    try {
      _resolvedAccess = await loader();
    } catch (_) {
      // No file access: stay memory-only, never throw.
      _resolvedAccess = null;
    }
    return _resolvedAccess;
  }

  /// Loads the persisted entries (if any) into memory. Never
  /// throws; a corrupt or missing file simply starts empty.
  Future<void> load() async {
    try {
      final access = await _access();
      if (access == null) return;
      final raw = await access.readText(logsJsonFileName);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != logsJsonVersion) return;
      final stored = decoded['entries'];
      if (stored is! List) return;
      _entries
        ..clear()
        ..addAll(
          stored
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e)),
        );
      _trim();
    } catch (_) {
      // Corrupt log file: start empty rather than crash the app.
      // The next persist overwrites it with a valid document.
      _entries.clear();
    }
  }

  /// Appends one entry (redacted — see [redact]) and schedules a
  /// persist. Never throws and never blocks the caller: the write
  /// is fire-and-forget, and a failed write is silently dropped
  /// (the in-memory entries still exist for this session).
  void log(
    LogLevel level,
    String tag,
    String message, {
    Map<String, dynamic>? data,
  }) {
    final entry = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'level': level.name,
      'tag': tag,
      'message': redact(message),
      if (data != null) 'data': _redactValue(data),
    };
    _entries.add(entry);
    _trim();
    unawaited(_persist());
  }

  void debug(String tag, String message, {Map<String, dynamic>? data}) =>
      log(LogLevel.debug, tag, message, data: data);

  void info(String tag, String message, {Map<String, dynamic>? data}) =>
      log(LogLevel.info, tag, message, data: data);

  void warn(String tag, String message, {Map<String, dynamic>? data}) =>
      log(LogLevel.warn, tag, message, data: data);

  void error(String tag, String message, {Map<String, dynamic>? data}) =>
      log(LogLevel.error, tag, message, data: data);

  /// Writes the current entries to logs.json now. Tests await this
  /// after logging, so they can read the file back deterministically.
  /// Never throws.
  Future<void> flush() => _persist();

  Future<void> _persist() async {
    try {
      final access = await _access();
      if (access == null) return;
      final payload = jsonEncode({
        'version': logsJsonVersion,
        'entries': _entries,
      });
      await access.writeAtomic(
        fileName: logsJsonFileName,
        tmpName: logsJsonTmpFileName,
        backupName: logsJsonBackupFileName,
        bytes: utf8.encode(payload),
      );
    } catch (_) {
      // A failed log write must never fail the call it describes.
    }
  }

  /// Drops the oldest entries until both bounds hold. At least one
  /// entry is always kept, even if a single entry alone exceeds
  /// [maxBytes].
  void _trim() {
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    while (_entries.length > 1 &&
        utf8.encode(jsonEncode(_entries)).length > maxBytes) {
      _entries.removeAt(0);
    }
  }

  // ---- Redaction -------------------------------------------------------

  /// A Gemini API key (`AIza…` + at least 20 more characters).
  static final _geminiKeyPattern = RegExp(r'AIza[0-9A-Za-z_\-]{20,}');

  /// `?key=…` / `&token=…` / `&api_key=…` in a URL query string.
  static final _querySecretPattern =
      RegExp(r'([?&](?:key|token|api[_-]?key)=)[^&\s]+',
          caseSensitive: false);

  /// `api_key: <value>`, `password=<value>`, `Bearer <token>` …
  /// in free text. The value runs to the next whitespace, quote,
  /// comma or closing brace/bracket.
  static final _keyValuePattern = RegExp(
    r'''(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd|secret|token|bearer)(\s*[:=]\s*["']?)[^\s"',}\]]+''',
    caseSensitive: false,
  );

  /// `Authorization: Bearer <token>` header lines.
  static final _bearerHeaderPattern =
      RegExp(r'(authorization:\s*bearer\s+)\S+', caseSensitive: false);

  /// Replaces anything that looks like a key, token, password or
  /// secret in [input] with `[REDACTED]`. Pure and side-effect
  /// free — safe to call on any string, including ones that contain
  /// no secrets (they pass through unchanged).
  static String redact(String input) {
    var out = input.replaceAll(_geminiKeyPattern, '[REDACTED]');
    out = out.replaceAllMapped(
        _querySecretPattern, (m) => '${m.group(1)}[REDACTED]');
    out = out.replaceAllMapped(_keyValuePattern,
        (m) => '${m.group(1)}${m.group(2)}[REDACTED]');
    out = out.replaceAllMapped(
        _bearerHeaderPattern, (m) => '${m.group(1)}[REDACTED]');
    return out;
  }

  /// Keys whose VALUES are secrets regardless of what the value
  /// looks like — the value is replaced wholesale.
  static bool _isSensitiveKey(String key) {
    final lower = key.toLowerCase();
    return lower.contains('password') ||
        lower.contains('token') ||
        lower.contains('secret') ||
        lower.contains('api_key') ||
        lower.contains('apikey') ||
        lower.contains('authorization') ||
        lower == 'key';
  }

  /// Recursively redacts a log-data value: strings pass through
  /// [redact], map values under a sensitive key become
  /// `[REDACTED]`, lists are redacted element-wise. Anything else
  /// (numbers, bools, null) passes through unchanged.
  static dynamic _redactValue(dynamic value) {
    if (value is String) return redact(value);
    if (value is Map) {
      return value.map((key, v) => MapEntry(
            key.toString(),
            _isSensitiveKey(key.toString()) ? '[REDACTED]' : _redactValue(v),
          ));
    }
    if (value is List) return value.map(_redactValue).toList();
    return value;
  }
}
