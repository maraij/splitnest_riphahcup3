// Phase 7 — structured logging (AppLogger).
//
// Covers:
//   1. Secret redaction: Gemini keys, api_key=/password=/token=
//      pairs, Bearer headers and ?key= query parameters never
//      appear in any entry or in the written file.
//   2. Rotation bounds: max entries and max bytes are both
//      enforced (oldest entries trimmed first).
//   3. JSON validity + round-trip: the written logs.json parses,
//      carries version 1, and reloads into a fresh logger.
//   4. Levels and tags are recorded as given; a corrupt file
//      starts empty instead of throwing.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitnest/core/services/app_logger.dart';
import 'package:splitnest/data/lock_file_access.dart';

/// A fake key used ONLY to prove redaction — not a real key.
const String _fakeKey = 'AIzaSyFakeKeyForTestOnly1234567890abcdef';

void main() {
  group('redaction', () {
    test('Gemini API keys are replaced', () {
      expect(AppLogger.redact('key is $_fakeKey here'),
          isNot(contains('AIzaSyFake')));
      expect(AppLogger.redact('key is $_fakeKey here'),
          contains('[REDACTED]'));
    });

    test('key/value pairs are replaced', () {
      expect(
        AppLogger.redact('GEMINI_API_KEY=$_fakeKey'),
        isNot(contains('AIzaSyFake')),
      );
      expect(AppLogger.redact('password=hunter2'),
          isNot(contains('hunter2')));
      expect(AppLogger.redact('password=hunter2'),
          contains('password=[REDACTED]'));
      expect(
        AppLogger.redact('token: abc123def456'),
        isNot(contains('abc123def456')),
      );
    });

    test('Bearer headers and ?key= query parameters are replaced', () {
      expect(
        AppLogger.redact('Authorization: Bearer abc123tokenvalue'),
        isNot(contains('abc123tokenvalue')),
      );
      expect(
        AppLogger.redact(
            'https://example.com/x?key=$_fakeKey&other=1'),
        isNot(contains('AIzaSyFake')),
      );
      expect(
        AppLogger.redact(
            'https://example.com/x?key=$_fakeKey&other=1'),
        contains('other=1'),
      );
    });

    test('ordinary text passes through unchanged', () {
      const text = 'Signed in as Ali, household loaded.';
      expect(AppLogger.redact(text), text);
    });

    test('data values under sensitive keys are replaced wholesale', () {
      final logger = AppLogger.inMemory();
      logger.info(
        'auth',
        'Sign-in attempt',
        data: {
          'method': 'email',
          'password': 'hunter2',
          'apiKey': _fakeKey,
          'nested': {'token': 'abc123'},
        },
      );
      final logged = jsonEncode(logger.entries);
      expect(logged, isNot(contains('hunter2')));
      expect(logged, isNot(contains('AIzaSyFake')));
      expect(logged, isNot(contains('abc123')));
      expect(logged, contains('email'));
    });

    test('log() redacts the message before storing it', () {
      final logger = AppLogger.inMemory();
      logger.error('chatbot', 'Gemini failed with key $_fakeKey');
      expect(jsonEncode(logger.entries), isNot(contains('AIzaSyFake')));
      expect(logger.entries.single['message'], contains('[REDACTED]'));
    });
  });

  group('entries', () {
    test('levels and tags are recorded as given', () {
      final logger = AppLogger.inMemory();
      logger.debug('app', 'debug line');
      logger.info('auth', 'signed in');
      logger.warn('invitations', 'invite failed');
      logger.error('repository', 'store call failed');
      expect(
        logger.entries.map((e) => e['level']).toList(),
        ['debug', 'info', 'warn', 'error'],
      );
      expect(
        logger.entries.map((e) => e['tag']).toList(),
        ['app', 'auth', 'invitations', 'repository'],
      );
      for (final entry in logger.entries) {
        expect(entry['timestamp'], isA<String>());
        expect(DateTime.tryParse(entry['timestamp'] as String),
            isNotNull);
      }
    });

    test('memory-only logger keeps entries without any file access', () {
      final logger = AppLogger();
      logger.info('app', 'hello');
      expect(logger.entries, hasLength(1));
    });
  });

  group('rotation bounds', () {
    test('max entries is enforced, oldest first', () async {
      final access = InMemoryLockFileAccess();
      final logger = AppLogger(
        access: access,
        maxEntries: 5,
      );
      for (var i = 0; i < 8; i++) {
        logger.info('test', 'entry $i');
      }
      expect(logger.entries.length, 5);
      expect(logger.entries.first['message'], 'entry 3');
      expect(logger.entries.last['message'], 'entry 7');
      await logger.flush();
      final raw = await access.readText(logsJsonFileName);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect((decoded['entries'] as List).length, 5);
    });

    test('max bytes is enforced, oldest first', () async {
      final access = InMemoryLockFileAccess();
      final logger = AppLogger(
        access: access,
        maxEntries: 500,
        maxBytes: 300,
      );
      for (var i = 0; i < 10; i++) {
        logger.info('test', 'entry $i ${'x' * 40}');
      }
      expect(logger.entries.length, lessThan(10));
      expect(logger.entries.length, greaterThan(0));
      expect(logger.entries.last['message'], contains('entry 9'));
      await logger.flush();
      final raw = await access.readText(logsJsonFileName);
      expect(utf8.encode(raw!).length, lessThanOrEqualTo(400));
    });
  });

  group('persistence', () {
    test('written file is valid JSON with version + entries', () async {
      final access = InMemoryLockFileAccess();
      final logger = AppLogger(access: access);
      logger.info('app', 'SplitNest started');
      logger.warn('auth', 'Sign-in failed', data: {'method': 'email'});
      await logger.flush();

      final raw = await access.readText(logsJsonFileName);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['version'], logsJsonVersion);
      final entries = decoded['entries'] as List;
      expect(entries.length, 2);
      expect(entries[0]['level'], 'info');
      expect(entries[0]['tag'], 'app');
      expect(entries[1]['data'], {'method': 'email'});
    });

    test('round-trip: a fresh logger reloads the same entries',
        () async {
      final access = InMemoryLockFileAccess();
      final first = AppLogger(access: access);
      first.info('app', 'one');
      first.error('chatbot', 'two', data: {'status': 503});
      await first.flush();

      final second = AppLogger(access: access);
      await second.load();
      expect(second.entries.length, 2);
      expect(second.entries[0]['message'], 'one');
      expect(second.entries[1]['level'], 'error');
      expect(second.entries[1]['data'], {'status': 503});
    });

    test('corrupt file starts empty instead of throwing', () async {
      final access = InMemoryLockFileAccess();
      await access.writeBytes(logsJsonFileName, utf8.encode('{broken'));
      final logger = AppLogger(access: access);
      await logger.load();
      expect(logger.entries, isEmpty);
      // Logging still works afterwards.
      logger.info('app', 'after corrupt load');
      expect(logger.entries, hasLength(1));
    });

    test('missing file starts empty', () async {
      final logger = AppLogger(access: InMemoryLockFileAccess());
      await logger.load();
      expect(logger.entries, isEmpty);
    });
  });
}
