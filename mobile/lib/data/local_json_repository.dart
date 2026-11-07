/// Local-only data store: one JSON file, `lock.json`, in the app
/// documents directory — the entire SplitNest household (users,
/// groups, expenses, payments, shopping, fixed templates,
/// invitations, activity, settings) in a single document.
///
/// Phase 6 (2026-11-07): the cloud backend was dropped entirely
/// by user decision. This file replaces the old cloud repository
/// with the same [SplitNestRepository] interface, so no screen and
/// no domain rule changed — only the storage behind the interface
/// did.
/// The full schema, atomicity rules and backup/restore story are in
/// `docs/LOCK_JSON.md`.
///
/// Member identity is LOCAL now: expenses, payments and splits are
/// keyed by member id (`M01`…) directly — there is no UID
/// translation any more (that existed only because the old cloud
/// rules checked cloud UIDs). `createdBy` / `recordedBy` /
/// `invitedBy` still store the local account uid (e.g. `demo-M01`,
/// or `u-<random>` for a signed-up account).
///
/// Uploads are local files too: `uploadReceipt` writes the bytes to
/// `receipts/<groupId>/<expenseId>/receipt.jpg` under the documents
/// directory and returns that local path in BOTH the url and path
/// fields — `receiptUrl` / `photoUrl` now hold local file paths,
/// never download URLs. On web (or any non-persistent store) there
/// is nowhere to write the bytes, so uploads return null and the
/// caller says so — never a fake path.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/money.dart';
import '../core/services/app_logger.dart';
import '../domain/balances.dart';
import '../domain/chat_message.dart';
import '../domain/expense_auth.dart';
import '../domain/invitations.dart';
import '../domain/models.dart';
import '../domain/payment_tracking.dart';
import 'demo_accounts.dart';
import 'demo_benchmark.dart';
import 'lock_file_access.dart';
import 'lock_file_io_stub.dart'
    if (dart.library.io) 'lock_file_io.dart' as lock_io;
import 'password_hash.dart';
import 'repository.dart';

/// The file names, relative to the app documents directory.
const String lockJsonFileName = 'lock.json';
const String lockJsonBackupFileName = 'lock.json.bak';
const String lockJsonTmpFileName = 'lock.json.tmp';

/// The schema version written into every lock.json. A future
/// version bump must add a migration here (see docs/LOCK_JSON.md).
const int lockJsonVersion = 1;

const int _maxReceiptBytes = 10 * 1024 * 1024;
const int _maxProfilePhotoBytes = 5 * 1024 * 1024;

/// Builds the first-run seed document: schema version, the three
/// demo accounts (salted hashes of the demo passwords — see
/// data/demo_accounts.dart), empty collections, and the PKR 5,000
/// budget in settings. No group is seeded here: each user's
/// household group is created on first login by [ensureGroup].
/// [random] is injectable for tests; production uses Random.secure.
Map<String, dynamic> buildSeedLockJson({Random? random}) {
  final now = DateTime.now().toIso8601String();
  final demoUsers = <Map<String, dynamic>>[];
  for (final demo in demoAccounts) {
    // One salt per demo user, generated once and used for both the
    // stored salt and the hash — they must match.
    final salt = generateSalt(random: random);
    demoUsers.add({
      'id': demoUidForMember(demo.memberId),
      'email': demo.email,
      'displayName': demo.name,
      'memberId': demo.memberId,
      'passwordSalt': salt,
      'passwordHash': hashPassword(demo.password, salt),
      'isDemo': true,
      'photoUrl': null,
      'createdAt': now,
    });
  }
  return {
    'version': lockJsonVersion,
    'users': demoUsers,
    'groups': [],
    'expenses': [],
    'payments': [],
    'shopping': [],
    'fixedExpenses': [],
    'invitations': [],
    'activity': [],
    'chatMessages': [],
    'settings': {'budgetPaisa': defaultBudgetPaisa, 'theme': 'light'},
  };
}

/// The lock.json store: one cached document, atomic writes, a
/// backup of the last good state, and corrupt-file recovery.
///
/// Read path: lock.json → (unreadable) lock.json.bak → (unreadable)
/// a fresh seed. A recovery is NEVER silent: [lastNotice] carries
/// the plain message for the UI, and [recoveredFromBackup] /
/// [seededFresh] say which path was taken. A missing file is a
/// normal first run (seeded, no notice). On web — or when the
/// documents directory cannot be resolved — the store is in-memory
/// only and [isPersistent] is false.
class LockJsonStore {
  LockJsonStore({LockFileAccess? access, this._directoryPath})
      : _providedAccess = access;

  /// In-memory store (tests, and the explicit non-persistent mode).
  /// Nothing persists; [lastNotice] stays null.
  factory LockJsonStore.inMemory() =>
      LockJsonStore(access: InMemoryLockFileAccess());

  /// A store rooted at [path] (tests): real files under that
  /// directory, so persistence round-trips can be verified.
  static Future<LockJsonStore> inDirectory(String path) async =>
      LockJsonStore(access: await lock_io.createAccess(directoryPath: path));

  final LockFileAccess? _providedAccess;
  final String? _directoryPath;

  Map<String, dynamic>? _doc;
  Future<LockFileAccess>? _accessFuture;
  LockFileAccess? _resolvedAccess;

  /// Plain notice for the UI after the last load: the web /
  /// in-memory warning, or what a corrupt-file recovery did. Null
  /// on a normal load (including a plain first run).
  String? lastNotice;

  /// True when the last load restored lock.json from lock.json.bak.
  bool recoveredFromBackup = false;

  /// True when the last load started from a fresh seed (first run,
  /// or both files unreadable).
  bool seededFresh = false;

  /// True once the underlying access is resolved and persistent.
  /// False before the first load, on web, and when the documents
  /// directory could not be resolved.
  bool get isPersistent => _resolvedAccess?.isPersistent ?? false;

  Future<LockFileAccess> _access() {
    final future = _accessFuture;
    if (future != null) return future;
    final resolved = _resolveAccess();
    _accessFuture = resolved;
    return resolved;
  }

  Future<LockFileAccess> _resolveAccess() async {
    final provided = _providedAccess;
    if (provided != null) {
      _resolvedAccess = provided;
      return provided;
    }
    final access =
        await lock_io.createAccess(directoryPath: _directoryPath);
    _resolvedAccess = access;
    return access;
  }

  /// The file access, for receipt/profile-photo byte writes.
  Future<LockFileAccess> get fileAccess => _access();

  /// Loads the document (cached after the first load). See the
  /// class doc comment for the fallback chain — never throws for a
  /// corrupt or missing file.
  Future<Map<String, dynamic>> load() async {
    final cached = _doc;
    if (cached != null) return cached;
    final access = await _access();
    lastNotice = access.notice;
    recoveredFromBackup = false;
    seededFresh = false;
    final raw = await access.readText(lockJsonFileName);
    if (raw != null) {
      try {
        _doc = _decode(raw);
        return _doc!;
      } catch (_) {
        // Corrupt live file: try the backup below.
      }
      final backupRaw = await access.readText(lockJsonBackupFileName);
      if (backupRaw != null) {
        try {
          _doc = _decode(backupRaw);
          recoveredFromBackup = true;
          lastNotice =
              'lock.json was damaged, so your last good backup was '
              'restored. Check your recent expenses — anything since '
              'that backup may be missing.';
          await _writeDoc();
          return _doc!;
        } catch (_) {
          // Backup corrupt too: fresh seed below.
        }
      }
      _doc = buildSeedLockJson();
      seededFresh = true;
      lastNotice =
          'lock.json and its backup were both unreadable, so a fresh '
          'household was started. Previous data could not be recovered.';
      await _writeDoc();
      return _doc!;
    }
    // First run: no file yet — seed and write it.
    _doc = buildSeedLockJson();
    seededFresh = true;
    await _writeDoc();
    return _doc!;
  }

  /// Persists [doc] atomically (tmp file + rename, backup of the
  /// previous good state kept). Callers pass the document they got
  /// from [load] after mutating it.
  Future<void> save(Map<String, dynamic> doc) async {
    _doc = doc;
    await _writeDoc();
  }

  Future<void> _writeDoc() async {
    final access = await _access();
    final doc = _doc;
    if (doc == null) return;
    await access.writeAtomic(
      fileName: lockJsonFileName,
      tmpName: lockJsonTmpFileName,
      backupName: lockJsonBackupFileName,
      bytes: utf8.encode(jsonEncode(doc)),
    );
  }

  /// Validates one decoded document: a map, the current schema
  /// version, and every collection present with the right shape.
  /// Throws [FormatException] on anything else, so the caller
  /// treats the file as corrupt and falls back to the backup.
  Map<String, dynamic> _decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('lock.json is not a JSON object');
    }
    if (decoded['version'] != lockJsonVersion) {
      throw FormatException(
          'lock.json version ${decoded['version']} is not supported '
          '(this app reads version $lockJsonVersion)');
    }
    const lists = [
      'users',
      'groups',
      'expenses',
      'payments',
      'shopping',
      'fixedExpenses',
      'invitations',
      'activity',
    ];
    for (final key in lists) {
      if (decoded[key] is! List) {
        throw FormatException('lock.json is missing "$key"');
      }
    }
    // `chatMessages` arrived in Phase 7: a lock.json written by an
    // older build has no such collection, and that is NOT corruption
    // — default it to empty so the old file still loads.
    if (decoded['chatMessages'] == null) {
      decoded['chatMessages'] = [];
    } else if (decoded['chatMessages'] is! List) {
      throw const FormatException('lock.json "chatMessages" is not a list');
    }
    if (decoded['settings'] is! Map) {
      throw const FormatException('lock.json is missing "settings"');
    }
    return decoded;
  }
}

// ---------------------------------------------------------------------------
// JSON mapping helpers (exported for tests — pure, no file access).
// ---------------------------------------------------------------------------

String _todayString() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

String _monthKey() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}';
}

String _nowIso() => DateTime.now().toIso8601String();

DateTime? _parseDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

ExpenseRecord expenseRecordFromJson(Map<String, dynamic> data) {
  final splits = data['splits'] as Map<String, dynamic>? ?? {};
  return ExpenseRecord(
    id: data['id'] as String? ?? '',
    title: data['title'] as String? ?? '',
    category: data['category'] as String? ?? 'General',
    amount: formatPaisa((data['amountPaisa'] as num?)?.toInt() ?? 0),
    payerId: data['paidBy'] as String? ?? '',
    date: data['date'] as String?,
    splitType: data['splitType'] as String?,
    shares: splits.entries
        .map((e) => ExpenseShare(
              memberId: e.key,
              amount: formatPaisa((e.value as num).toInt()),
            ))
        .toList(),
    isDemo: data['isDemo'] == true,
    createdByUid: data['createdBy'] as String?,
    receiptUrl: data['receiptUrl'] as String?,
    receiptPath: data['receiptPath'] as String?,
  );
}

PaymentRecord paymentRecordFromJson(Map<String, dynamic> data) {
  return PaymentRecord(
    id: data['id'] as String? ?? '',
    senderId: data['senderId'] as String? ?? '',
    recipientId: data['recipientId'] as String? ?? '',
    amount: formatPaisa((data['amountPaisa'] as num?)?.toInt() ?? 0),
    status: data['status'] as String? ?? 'recorded',
    verifiedBy: data['verifiedBy'] as String?,
    verifiedAt: _parseDate(data['verifiedAt']),
    rejectedBy: data['rejectedBy'] as String?,
    rejectedAt: _parseDate(data['rejectedAt']),
    createdAt: _parseDate(data['createdAt']),
  );
}

FixedExpense fixedExpenseFromJson(Map<String, dynamic> data) {
  final splitIds = data['splitMemberIds'] as List? ?? [];
  return FixedExpense(
    id: data['id'] as String? ?? '',
    title: data['title'] as String? ?? '',
    category: data['category'] as String? ?? 'General',
    amount: formatPaisa((data['amountPaisa'] as num?)?.toInt() ?? 0),
    payerId: data['payerId'] as String? ?? '',
    splitMemberIds: splitIds.map((e) => e.toString()).toList(),
  );
}

ShoppingItem shoppingItemFromJson(Map<String, dynamic> data) {
  return ShoppingItem(
    id: data['id'] as String? ?? '',
    title: data['title'] as String? ?? '',
    unit: data['unit'] as String? ?? 'pack',
    requestedQty: (data['requestedQty'] as num?)?.toInt() ?? 1,
    status: data['status'] as String? ?? 'Pending',
  );
}

Invitation invitationFromJson(Map<String, dynamic> data) {
  return Invitation(
    id: data['id'] as String? ?? '',
    groupId: data['groupId'] as String? ?? '',
    groupName: data['groupName'] as String? ?? '',
    invitedEmail: data['invitedEmail'] as String? ?? '',
    invitedBy: data['invitedBy'] as String? ?? '',
    inviterName: data['inviterName'] as String?,
    role: data['role'] as String? ?? 'member',
    status: data['status'] as String? ?? 'pending',
    createdAt: _parseDate(data['createdAt']) ?? DateTime.now(),
    expiresAt: _parseDate(data['expiresAt']) ??
        DateTime.now().add(const Duration(days: invitationValidityDays)),
    acceptedBy: data['acceptedBy'] as String?,
    acceptedAt: _parseDate(data['acceptedAt']),
  );
}

ActivityEntry activityEntryFromJson(Map<String, dynamic> data) {
  return ActivityEntry(
    type: data['type'] as String? ?? 'expense',
    title: data['title'] as String? ?? '',
    amount: data['amount'] as String? ?? '0.00',
    memberId: data['memberId'] as String? ?? '',
    detail: data['detail'] as String? ?? '',
    timestamp: _parseDate(data['timestamp']) ?? DateTime.now(),
  );
}

ChatMessage chatMessageFromJson(Map<String, dynamic> data) =>
    ChatMessage.fromJson(data);

// ---------------------------------------------------------------------------
// Local implementation of [SplitNestRepository] over lock.json.
// ---------------------------------------------------------------------------

/// Local implementation of [SplitNestRepository] — lock.json is the
/// app's ONLY data source.
///
/// Every method loads the cached document, mutates it in memory,
/// and saves it atomically (one file write per mutation), so a
/// multi-step operation such as checkout can never half-apply: the
/// in-memory changes and the single save either both happen or the
/// call throws before saving. The document is cached in
/// [LockJsonStore], so reads never touch the disk twice.
class LocalJsonRepository implements SplitNestRepository {
  LocalJsonRepository({LockJsonStore? store, AppLogger? logger})
      : _store = store ?? LockJsonStore(),
        _logger = logger ?? AppLogger.inMemory();

  final LockJsonStore _store;

  /// Structured log (Phase 7). Repository failures are logged
  /// here with the plain message only — never raw secrets, never
  /// the Gemini key. Defaults to a memory-only logger, so tests
  /// that build a repository without one stay file-free.
  final AppLogger _logger;

  /// The store, for the auth service (one shared store per app) and
  /// for tests that inspect the raw document.
  LockJsonStore get store => _store;

  /// Plain notice from the last store load (web in-memory warning,
  /// corrupt-file recovery, …), or null on a normal load. AppState
  /// surfaces this as a dismissible banner.
  String? get storeNotice => _store.lastNotice;

  /// Runs [fn], translating unexpected failures into the plain
  /// [LocalDataException] the UI shows. [LocalDataException]s thrown
  /// by the shared validators pass through unchanged. Anything else
  /// becomes the generic message — raw error text never reaches the
  /// screen, and no failure ever returns fake data.
  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on LocalDataException {
      rethrow;
    } catch (e) {
      debugPrint('SplitNest: local store call failed: $e');
      _logger.error(
        'repository',
        'Local store call failed',
        data: {'error': AppLogger.redact(e.toString())},
      );
      throw const LocalDataException(
          'Something went wrong. Please try again.');
    }
  }

  String _newId(String prefix) {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    final suffix =
        List.generate(6, (_) => alphabet[r.nextInt(alphabet.length)]).join();
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }

  List<Map<String, dynamic>> _list(
      Map<String, dynamic> doc, String key) {
    final list = doc[key] as List;
    return list.cast<Map<String, dynamic>>();
  }

  /// The `chatMessages` collection, defaulting a missing one to an
  /// empty list (a lock.json written before Phase 7 has no such
  /// collection, and the in-memory document cached by the store
  /// never passes through [_decode]'s tolerance — see the old-file
  /// test in test/chatbot_test.dart).
  List<Map<String, dynamic>> _chatList(Map<String, dynamic> doc) {
    final list = doc['chatMessages'];
    if (list is List) return list.cast<Map<String, dynamic>>();
    final created = <Map<String, dynamic>>[];
    doc['chatMessages'] = created;
    return created;
  }

  Map<String, dynamic>? _group(
      Map<String, dynamic> doc, String groupId) {
    for (final g in _list(doc, 'groups')) {
      if (g['id'] == groupId) return g;
    }
    return null;
  }

  List<Map<String, dynamic>> _groupMembers(
      Map<String, dynamic> doc, String groupId) {
    final group = _group(doc, groupId);
    if (group == null) return [];
    final members = group['members'] as List? ?? [];
    return members.cast<Map<String, dynamic>>();
  }

  /// The member entries of a group, as [Member]s, sorted by id.
  List<Member> _membersOf(Map<String, dynamic> doc, String groupId) {
    final members = _groupMembers(doc, groupId)
        .map((m) => Member(
              id: m['memberId'] as String? ?? '',
              name: m['displayName'] as String? ?? '',
              photoUrl: m['photoUrl'] as String?,
            ))
        .toList();
    members.sort((a, b) => a.id.compareTo(b.id));
    return members;
  }

  /// The role of [uid] in a group, or null when they are not a
  /// member of it. (Roster entries that never signed in have no
  /// uid, so they never match.)
  String? _roleOf(Map<String, dynamic> doc, String groupId, String uid) {
    for (final m in _groupMembers(doc, groupId)) {
      if (m['uid'] == uid) return m['role'] as String?;
    }
    return null;
  }

  /// The actor's own role in a group, or a plain error when they
  /// are not a member — the guard for owner/admin-only writes.
  String _requireRole(
      Map<String, dynamic> doc, String groupId, String uid) {
    final role = _roleOf(doc, groupId, uid);
    if (role == null) {
      throw const LocalDataException(
          'Only the household owner or an admin can do that.');
    }
    return role;
  }

  /// The member id linked to [uid] (from the users table, falling
  /// back to the group roster entry), or null when unknown.
  String? _memberIdForUid(
      Map<String, dynamic> doc, String uid, String groupId) {
    for (final u in _list(doc, 'users')) {
      if (u['id'] == uid) return u['memberId'] as String?;
    }
    for (final m in _groupMembers(doc, groupId)) {
      if (m['uid'] == uid) return m['memberId'] as String?;
    }
    return null;
  }

  /// Authorisation for an expense edit/delete: the actor is the
  /// expense's creator (or payer, via the stored member id) or a
  /// group owner/admin. Mirrors domain/expense_auth.dart, and is
  /// enforced here on every write — there are no security rules any
  /// more, so this check IS the enforcement.
  void _requireExpenseEditAllowed({
    required Map<String, dynamic> doc,
    required String groupId,
    required Map<String, dynamic> expense,
    required String actorUid,
  }) {
    final role = _roleOf(doc, groupId, actorUid);
    final allowed = canEditExpense(
      isAdmin: role == 'owner' || role == 'admin',
      actorUid: actorUid,
      actorMemberId: _memberIdForUid(doc, actorUid, groupId),
      createdByUid: expense['createdBy'] as String?,
      payerMemberId: expense['paidBy'] as String? ?? '',
    );
    if (!allowed) {
      throw const LocalDataException(
          'Only the member who added this expense (or the household '
          'owner/admin) can change or delete it.');
    }
  }

  Map<String, dynamic> _expenseToJson({
    required String id,
    required String groupId,
    required String title,
    required String category,
    required int amountPaisa,
    required String date,
    required String paidBy,
    required String splitType,
    required Map<String, int> splits,
    required String createdByUid,
    String? fixedExpenseId,
    bool isDemo = false,
    String? receiptUrl,
    String? receiptPath,
  }) {
    return {
      'id': id,
      'groupId': groupId,
      'title': title,
      'category': category,
      'amountPaisa': amountPaisa,
      'date': date,
      'paidBy': paidBy,
      'splitType': splitType,
      'splits': splits,
      'createdBy': createdByUid,
      'createdAt': _nowIso(),
      'updatedAt': _nowIso(),
      ...?fixedExpenseId == null ? null : {'fixedExpenseId': fixedExpenseId},
      if (isDemo) 'isDemo': true,
      ...?receiptUrl == null ? null : {'receiptUrl': receiptUrl},
      ...?receiptPath == null ? null : {'receiptPath': receiptPath},
    };
  }

  @override
  Future<GroupInfo> ensureGroup({
    required String uid,
    required String displayName,
    required String? email,
    required String legacyMemberId,
    required bool isDemo,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        // Deterministic per-user group id until the invite flow can
        // move users between groups.
        final groupId = 'household-$uid';
        final existing = _group(doc, groupId);
        if (existing != null) {
          return GroupInfo(
            groupId: groupId,
            budgetPaisa: (existing['budgetPaisa'] as num?)?.toInt() ??
                defaultBudgetPaisa,
          );
        }
        final now = _nowIso();
        final members = <Map<String, dynamic>>[];
        for (final m in householdMembers) {
          final isCreator = m.id == legacyMemberId;
          members.add({
            'uid': isCreator ? uid : null,
            'memberId': m.id,
            'role': isCreator ? 'owner' : 'member',
            'displayName': isCreator ? displayName : m.name,
            'photoUrl': null,
            'joinedAt': now,
          });
        }
        _list(doc, 'groups').add({
          'id': groupId,
          'name': 'SplitNest Household',
          'createdBy': uid,
          'createdAt': now,
          'budgetPaisa': defaultBudgetPaisa,
          'currency': 'PKR',
          'members': members,
        });
        // The user's own record (created by sign-up / the demo
        // seed); a missing record is added without password fields
        // — the auth service owns those and fills them at sign-up.
        final users = _list(doc, 'users');
        final hasUser = users.any((u) => u['id'] == uid);
        if (!hasUser) {
          users.add({
            'id': uid,
            'email': email?.toLowerCase(),
            'displayName': displayName,
            'memberId': legacyMemberId,
            'passwordSalt': null,
            'passwordHash': null,
            'isDemo': isDemo,
            'photoUrl': null,
            'createdAt': now,
          });
        }
        await _store.save(doc);
        return GroupInfo(groupId: groupId, budgetPaisa: defaultBudgetPaisa);
      });

  @override
  Future<List<Member>> getMembers(String groupId) => _guard(() async {
        final doc = await _store.load();
        return _membersOf(doc, groupId);
      });

  @override
  Future<List<ShoppingItem>> getShopping(String groupId) =>
      _guard(() async {
        final doc = await _store.load();
        final items = _list(doc, 'shopping')
            .where((i) => i['groupId'] == groupId)
            .map(shoppingItemFromJson)
            .toList();
        items.sort((a, b) => a.id.compareTo(b.id));
        return items;
      });

  @override
  Future<List<ExpenseRecord>> getExpenses(String groupId) =>
      _guard(() async {
        final doc = await _store.load();
        final expenses = _list(doc, 'expenses')
            .where((e) => e['groupId'] == groupId)
            .map(expenseRecordFromJson)
            .toList();
        // Newest first: expenseDate desc, then id desc.
        expenses.sort((a, b) {
          final byDate = (b.date ?? '').compareTo(a.date ?? '');
          if (byDate != 0) return byDate;
          return b.id.compareTo(a.id);
        });
        return expenses;
      });

  @override
  Future<List<PaymentRecord>> getPayments(String groupId) =>
      _guard(() async {
        final doc = await _store.load();
        final payments = _list(doc, 'payments')
            .where((p) => p['groupId'] == groupId)
            .map(paymentRecordFromJson)
            .toList();
        payments.sort((a, b) {
          final ca = a.createdAt;
          final cb = b.createdAt;
          if (ca == null && cb == null) return b.id.compareTo(a.id);
          if (ca == null) return 1;
          if (cb == null) return -1;
          return cb.compareTo(ca);
        });
        return payments;
      });

  @override
  Future<List<FixedExpense>> getFixedExpenses(String groupId) =>
      _guard(() async {
        final doc = await _store.load();
        final fixed = _list(doc, 'fixedExpenses')
            .where((f) => f['groupId'] == groupId)
            .map(fixedExpenseFromJson)
            .toList();
        fixed.sort((a, b) => a.id.compareTo(b.id));
        return fixed;
      });

  @override
  Future<List<ActivityEntry>> getActivity(String groupId) =>
      _guard(() async {
        final doc = await _store.load();
        final entries = _list(doc, 'activity')
            .where((a) => a['groupId'] == groupId)
            .map(activityEntryFromJson)
            .toList();
        entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return entries;
      });

  @override
  Future<ShoppingItem> addShopping({
    required String groupId,
    required String title,
    required String unit,
    required int qty,
    required String actorUid,
  }) =>
      _guard(() async {
        if (title.trim().isEmpty) {
          throw const LocalDataException('Title is required.');
        }
        if (!shoppingUnits.contains(unit)) {
          throw LocalDataException(
              'Unit must be one of: ${shoppingUnits.join(', ')}.');
        }
        if (qty <= 0) {
          throw const LocalDataException(
              'Quantity must be a positive whole number.');
        }
        final doc = await _store.load();
        final item = {
          'id': _newId('shop'),
          'groupId': groupId,
          'title': title.trim(),
          'unit': unit,
          'requestedQty': qty,
          'status': 'Pending',
          'createdBy': actorUid,
          'createdAt': _nowIso(),
        };
        _list(doc, 'shopping').add(item);
        await _store.save(doc);
        return shoppingItemFromJson(item);
      });

  @override
  Future<ExpenseRecord> checkout({
    required String groupId,
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
    required String actorUid,
  }) =>
      _guard(() async {
        final totalPaisa = parsePaisa(totalPaid);
        if (totalPaisa == null) {
          throw const LocalDataException(
              'Total paid must be a positive amount.');
        }
        final doc = await _store.load();
        final members = _membersOf(doc, groupId);
        final known = members.map((m) => m.id).toList();
        final items = _list(doc, 'shopping')
            .where((i) => i['groupId'] == groupId)
            .map(shoppingItemFromJson)
            .toList();
        validateCheckout(
          itemIds: itemIds,
          totalPaisa: totalPaisa,
          payerId: payerId,
          splitMembers: splitMembers,
          items: items,
          knownMembers: known,
        );
        final shares = validatedShares(
          amountPaisa: totalPaisa,
          splitType: 'equal',
          splitMembers: splitMembers,
          knownMembers: known,
        );
        final titles = itemIds
            .map((id) => items.firstWhere((i) => i.id == id).title)
            .toList();
        final date = _todayString();
        // One save: exactly one expense is posted AND the items
        // become Bought, or nothing changes.
        final expenseId = _newId('exp');
        final expense = _expenseToJson(
          id: expenseId,
          groupId: groupId,
          title: 'Shopping: ${titles.join(', ')}',
          category: 'Groceries',
          amountPaisa: totalPaisa,
          date: date,
          paidBy: payerId,
          splitType: 'equal',
          splits: {
            for (final s in shares) s.memberId: s.amountPaisa,
          },
          createdByUid: actorUid,
        );
        _list(doc, 'expenses').add(expense);
        for (final item in _list(doc, 'shopping')) {
          if (itemIds.contains(item['id'])) {
            item['status'] = 'Bought';
            item['checkoutExpenseId'] = expenseId;
          }
        }
        await _store.save(doc);
        return expenseRecordFromJson(expense);
      });

  @override
  Future<ExpenseRecord> addExpense({
    required String groupId,
    required String title,
    required String category,
    required String date,
    required String amount,
    required String payerId,
    required String splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
    List<Map<String, String>>? percentageSplits,
    required String actorUid,
  }) =>
      _guard(() async {
        if (title.trim().isEmpty) {
          throw const LocalDataException('Title is required.');
        }
        final amountPaisa = parsePaisa(amount);
        if (amountPaisa == null || amountPaisa <= 0) {
          throw const LocalDataException(
              'Amount must be a positive amount.');
        }
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
          throw const LocalDataException('Date must be YYYY-MM-DD.');
        }
        final doc = await _store.load();
        final known =
            _membersOf(doc, groupId).map((m) => m.id).toList();
        if (!known.contains(payerId)) {
          throw LocalDataException('Payer $payerId does not exist.');
        }
        final shares = validatedShares(
          amountPaisa: amountPaisa,
          splitType: splitType,
          splits: splits,
          splitMembers: splitMembers,
          percentageSplits: percentageSplits,
          knownMembers: known,
        );
        final expense = _expenseToJson(
          id: _newId('exp'),
          groupId: groupId,
          title: title.trim(),
          category: category.trim().isEmpty ? 'General' : category.trim(),
          amountPaisa: amountPaisa,
          date: date,
          paidBy: payerId,
          splitType: splitType,
          splits: {
            for (final s in shares) s.memberId: s.amountPaisa,
          },
          createdByUid: actorUid,
        );
        _list(doc, 'expenses').add(expense);
        await _store.save(doc);
        return expenseRecordFromJson(expense);
      });

  @override
  Future<ExpenseRecord> updateExpense({
    required String groupId,
    required String id,
    String? title,
    String? category,
    String? date,
    String? amount,
    String? payerId,
    String? splitType,
    List<Map<String, String>>? splits,
    List<String>? splitMembers,
    List<Map<String, String>>? percentageSplits,
    String? receiptUrl,
    String? receiptPath,
    required String actorUid,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final expenses = _list(doc, 'expenses');
        final index = expenses.indexWhere(
            (e) => e['id'] == id && e['groupId'] == groupId);
        if (index < 0) {
          throw const LocalDataException('Expense not found.');
        }
        final expense = expenses[index];
        _requireExpenseEditAllowed(
          doc: doc,
          groupId: groupId,
          expense: expense,
          actorUid: actorUid,
        );
        final known =
            _membersOf(doc, groupId).map((m) => m.id).toList();
        final newTitle =
            title?.trim() ?? expense['title'] as String? ?? '';
        if (newTitle.isEmpty) {
          throw const LocalDataException('Title is required.');
        }
        final newAmountPaisa = amount == null
            ? (expense['amountPaisa'] as num?)?.toInt() ?? 0
            : parsePaisa(amount);
        if (newAmountPaisa == null || newAmountPaisa <= 0) {
          throw const LocalDataException(
              'Amount must be a positive amount.');
        }
        final newDate = date ?? expense['date'] as String?;
        if (newDate == null ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(newDate)) {
          throw const LocalDataException('Date must be YYYY-MM-DD.');
        }
        final newPayerId = payerId ?? expense['paidBy'] as String? ?? '';
        if (!known.contains(newPayerId)) {
          throw LocalDataException('Payer $newPayerId does not exist.');
        }
        final newSplitType =
            splitType ?? expense['splitType'] as String? ?? 'equal';
        // Splits are recomputed from the new values, so the
        // integer-paisa invariant always holds after an edit. When
        // the caller passes no split at all, the stored splits are
        // re-derived: equal → same member set, custom/percentage →
        // the stored shares (already validated when created).
        List<({String memberId, int amountPaisa})> shares;
        if (splitType != null ||
            splits != null ||
            splitMembers != null ||
            percentageSplits != null) {
          shares = validatedShares(
            amountPaisa: newAmountPaisa,
            splitType: newSplitType,
            splits: splits,
            splitMembers: splitMembers,
            percentageSplits: percentageSplits,
            knownMembers: known,
          );
        } else if (newSplitType == 'equal') {
          final stored = expense['splits'] as Map<String, dynamic>? ?? {};
          shares = validatedShares(
            amountPaisa: newAmountPaisa,
            splitType: 'equal',
            splitMembers: stored.keys.toList()..sort(),
            knownMembers: known,
          );
        } else {
          final stored = expense['splits'] as Map<String, dynamic>? ?? {};
          final sum = stored.values
              .fold(0, (s, v) => s + ((v as num?)?.toInt() ?? 0));
          if (sum != newAmountPaisa) {
            throw LocalDataException(
                'Stored shares sum to ${formatPaisa(sum)} but the amount '
                'is ${formatPaisa(newAmountPaisa)} — re-enter the split.');
          }
          shares = stored.entries
              .map((e) => (
                    memberId: e.key,
                    amountPaisa: (e.value as num).toInt(),
                  ))
              .toList();
        }
        expense['title'] = newTitle;
        expense['category'] = category?.trim().isEmpty ?? true
            ? expense['category'] as String? ?? 'General'
            : category!.trim();
        expense['amountPaisa'] = newAmountPaisa;
        expense['date'] = newDate;
        expense['paidBy'] = newPayerId;
        expense['splitType'] = newSplitType;
        expense['splits'] = {
          for (final s in shares) s.memberId: s.amountPaisa,
        };
        expense['updatedAt'] = _nowIso();
        if (receiptUrl != null) expense['receiptUrl'] = receiptUrl;
        if (receiptPath != null) expense['receiptPath'] = receiptPath;
        await _store.save(doc);
        return expenseRecordFromJson(expense);
      });

  @override
  Future<void> deleteExpense({
    required String groupId,
    required String id,
    required String actorUid,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final expenses = _list(doc, 'expenses');
        final index = expenses.indexWhere(
            (e) => e['id'] == id && e['groupId'] == groupId);
        if (index < 0) {
          throw const LocalDataException('Expense not found.');
        }
        _requireExpenseEditAllowed(
          doc: doc,
          groupId: groupId,
          expense: expenses[index],
          actorUid: actorUid,
        );
        expenses.removeAt(index);
        await _store.save(doc);
      });

  @override
  Future<void> setUserPhotoUrl({
    required String groupId,
    required String uid,
    required String photoUrl,
  }) async {
    // Best-effort mirror update: the users-table record is the
    // durable one; the group roster entry is updated when the user
    // is a member of this group. A miss is not a failure.
    try {
      final doc = await _store.load();
      var changed = false;
      for (final u in _list(doc, 'users')) {
        if (u['id'] == uid) {
          u['photoUrl'] = photoUrl;
          changed = true;
        }
      }
      final group = _group(doc, groupId);
      if (group != null) {
        for (final m in (group['members'] as List)
            .cast<Map<String, dynamic>>()) {
          if (m['uid'] == uid) {
            m['photoUrl'] = photoUrl;
            changed = true;
          }
        }
      }
      if (changed) await _store.save(doc);
    } catch (e) {
      debugPrint('SplitNest: user photoUrl skipped ($e)');
    }
  }

  // ---- Local file uploads ----
  // The bytes live under the documents directory (see the file doc
  // comment). The returned `url` IS the local path — there is no
  // download URL any more. On a non-persistent store (web) there is
  // nowhere to write the bytes, so this returns null and the caller
  // says the upload could not be saved.

  @override
  Future<({String url, String path})?> uploadReceipt({
    required String groupId,
    required String expenseId,
    required Uint8List bytes,
  }) async {
    if (bytes.length > _maxReceiptBytes) return null;
    final access = await _store.fileAccess;
    if (!access.isPersistent) return null;
    final path = 'receipts/$groupId/$expenseId/receipt.jpg';
    try {
      await access.writeBytes(path, bytes);
      return (url: path, path: path);
    } catch (e) {
      debugPrint('SplitNest: receipt save failed ($e)');
      return null;
    }
  }

  @override
  Future<String?> uploadProfilePhoto({
    required String uid,
    required Uint8List bytes,
  }) async {
    if (bytes.length > _maxProfilePhotoBytes) return null;
    final access = await _store.fileAccess;
    if (!access.isPersistent) return null;
    final path = 'profile-photos/$uid/photo.jpg';
    try {
      await access.writeBytes(path, bytes);
      return path;
    } catch (e) {
      debugPrint('SplitNest: profile photo save failed ($e)');
      return null;
    }
  }

  @override
  Future<PaymentRecord> recordPayment({
    required String groupId,
    required String senderId,
    required String recipientId,
    required String amount,
    required String actorUid,
  }) =>
      _guard(() async {
        final amountPaisa = parsePaisa(amount);
        if (amountPaisa == null) {
          throw const LocalDataException(
              'Settlement amount must be positive.');
        }
        final doc = await _store.load();
        final members = _membersOf(doc, groupId);
        final expenses = _list(doc, 'expenses')
            .where((e) => e['groupId'] == groupId)
            .map(expenseRecordFromJson)
            .toList();
        final payments = _list(doc, 'payments')
            .where((p) => p['groupId'] == groupId)
            .map(paymentRecordFromJson)
            .toList();
        final balances = computeBalances(
          expenses: expenses,
          payments: payments,
          members: members,
          budgetPaisa: defaultBudgetPaisa,
        );
        final nets = {
          for (final r in balances.rows)
            r.memberId: parsePaisa(r.net) ?? 0,
        };
        final error = settlementError(
          nets: nets,
          senderId: senderId,
          recipientId: recipientId,
          amountPaisa: amountPaisa,
        );
        if (error != null) throw LocalDataException(error);
        final payment = {
          'id': _newId('pay'),
          'groupId': groupId,
          'senderId': senderId,
          'recipientId': recipientId,
          'amountPaisa': amountPaisa,
          'status': 'recorded',
          'recordedBy': actorUid,
          'createdAt': _nowIso(),
        };
        _list(doc, 'payments').add(payment);
        await _store.save(doc);
        return paymentRecordFromJson(payment);
      });

  @override
  Future<PaymentRecord> verifyPayment({
    required String groupId,
    required String paymentId,
    required String actorUid,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final payments = _list(doc, 'payments');
        final index = payments.indexWhere(
            (p) => p['id'] == paymentId && p['groupId'] == groupId);
        if (index < 0) {
          throw const LocalDataException('Payment not found.');
        }
        final payment = payments[index];
        final role = _roleOf(doc, groupId, actorUid);
        final error = paymentStatusTransitionError(
          current: payment['status'] as String? ?? 'recorded',
          target: 'verified',
          isAdmin: role == 'owner' || role == 'admin',
        );
        if (error != null) throw LocalDataException(error);
        payment['status'] = 'verified';
        payment['verifiedBy'] = actorUid;
        payment['verifiedAt'] = _nowIso();
        await _store.save(doc);
        return paymentRecordFromJson(payment);
      });

  @override
  Future<PaymentRecord> rejectPayment({
    required String groupId,
    required String paymentId,
    required String actorUid,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final payments = _list(doc, 'payments');
        final index = payments.indexWhere(
            (p) => p['id'] == paymentId && p['groupId'] == groupId);
        if (index < 0) {
          throw const LocalDataException('Payment not found.');
        }
        final payment = payments[index];
        final role = _roleOf(doc, groupId, actorUid);
        final error = paymentStatusTransitionError(
          current: payment['status'] as String? ?? 'recorded',
          target: 'rejected',
          isAdmin: role == 'owner' || role == 'admin',
        );
        if (error != null) throw LocalDataException(error);
        payment['status'] = 'rejected';
        payment['rejectedBy'] = actorUid;
        payment['rejectedAt'] = _nowIso();
        await _store.save(doc);
        return paymentRecordFromJson(payment);
      });

  @override
  Future<FixedExpense> createFixedExpense({
    required String groupId,
    required String title,
    required String category,
    required String amount,
    required String payerId,
    List<String>? splitMemberIds,
    required String actorUid,
  }) =>
      _guard(() async {
        if (title.trim().isEmpty) {
          throw const LocalDataException('Title is required.');
        }
        final amountPaisa = parsePaisa(amount);
        if (amountPaisa == null || amountPaisa <= 0) {
          throw const LocalDataException(
              'Amount must be a positive amount.');
        }
        final doc = await _store.load();
        final known =
            _membersOf(doc, groupId).map((m) => m.id).toList();
        if (!known.contains(payerId)) {
          throw LocalDataException('Payer $payerId does not exist.');
        }
        final splitIds = (splitMemberIds != null && splitMemberIds.isNotEmpty)
            ? splitMemberIds
            : known;
        if (splitIds.toSet().length != splitIds.length ||
            splitIds.any((m) => !known.contains(m))) {
          throw const LocalDataException(
              'Split members must be known members, listed once.');
        }
        final fixed = {
          'id': _newId('fixed'),
          'groupId': groupId,
          'title': title.trim(),
          'category': category.trim().isEmpty ? 'General' : category.trim(),
          'amountPaisa': amountPaisa,
          'payerId': payerId,
          'splitMemberIds': [...splitIds]..sort(),
          'createdBy': actorUid,
          'createdAt': _nowIso(),
          'lastAppliedMonth': null,
        };
        _list(doc, 'fixedExpenses').add(fixed);
        await _store.save(doc);
        return fixedExpenseFromJson(fixed);
      });

  @override
  Future<FixedExpense> updateFixedExpense({
    required String groupId,
    required String id,
    String? title,
    String? category,
    String? amount,
    String? payerId,
    List<String>? splitMemberIds,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final fixedList = _list(doc, 'fixedExpenses');
        final index = fixedList.indexWhere(
            (f) => f['id'] == id && f['groupId'] == groupId);
        if (index < 0) {
          throw const LocalDataException('Fixed expense not found.');
        }
        final fixed = fixedList[index];
        if (title != null) fixed['title'] = title.trim();
        if (category != null) fixed['category'] = category.trim();
        if (amount != null) {
          final paisa = parsePaisa(amount);
          if (paisa == null || paisa <= 0) {
            throw const LocalDataException(
                'Amount must be a positive amount.');
          }
          fixed['amountPaisa'] = paisa;
        }
        if (payerId != null) fixed['payerId'] = payerId;
        if (splitMemberIds != null) {
          fixed['splitMemberIds'] = splitMemberIds;
        }
        fixed['updatedAt'] = _nowIso();
        await _store.save(doc);
        return fixedExpenseFromJson(fixed);
      });

  @override
  Future<void> deleteFixedExpense({
    required String groupId,
    required String id,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final fixedList = _list(doc, 'fixedExpenses');
        fixedList.removeWhere(
            (f) => f['id'] == id && f['groupId'] == groupId);
        await _store.save(doc);
      });

  @override
  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense({
    required String groupId,
    required String id,
    required String actorUid,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final fixedList = _list(doc, 'fixedExpenses');
        final index = fixedList.indexWhere(
            (f) => f['id'] == id && f['groupId'] == groupId);
        if (index < 0) {
          throw const LocalDataException('Fixed expense not found.');
        }
        final fixed = fixedList[index];
        final monthKey = _monthKey();
        if (fixed['lastAppliedMonth'] == monthKey) {
          return (applied: false, expense: null);
        }
        final record = fixedExpenseFromJson(fixed);
        final amountPaisa = parsePaisa(record.amount) ?? 0;
        final shares = validatedShares(
          amountPaisa: amountPaisa,
          splitType: 'equal',
          splitMembers: record.splitMemberIds,
          knownMembers: record.splitMemberIds,
        );
        final expense = _expenseToJson(
          id: _newId('exp'),
          groupId: groupId,
          title: record.title,
          category: record.category,
          amountPaisa: amountPaisa,
          date: _todayString(),
          paidBy: record.payerId,
          splitType: 'equal',
          splits: {
            for (final s in shares) s.memberId: s.amountPaisa,
          },
          createdByUid: actorUid,
          fixedExpenseId: id,
        );
        _list(doc, 'expenses').add(expense);
        fixed['lastAppliedMonth'] = monthKey;
        await _store.save(doc);
        return (applied: true, expense: expenseRecordFromJson(expense));
      });

  @override
  Future<int> loadDemoBenchmark({
    required String groupId,
    required String actorUid,
    required String actorName,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        // Idempotency: the deterministic benchmark expense ids.
        // If the first one exists, the benchmark is already loaded.
        final exists = _list(doc, 'expenses').any((e) =>
            e['id'] == benchmarkExpenses.first.id &&
            e['groupId'] == groupId);
        if (exists) return 0;
        final date = _todayString();
        for (final spec in benchmarkExpenses) {
          final shares = spec.splitType == 'custom'
              ? <String, int>{
                  for (final e in spec.customSplits!.entries)
                    e.key: e.value,
                }
              : <String, int>{
                  for (final s in equalSplit(
                      spec.amountPaisa, spec.splitMemberIds))
                    s.memberId: s.amountPaisa,
                };
          _list(doc, 'expenses').add(_expenseToJson(
            id: spec.id,
            groupId: groupId,
            title: spec.title,
            category: spec.category,
            amountPaisa: spec.amountPaisa,
            date: date,
            paidBy: spec.payerId,
            splitType: spec.splitType,
            splits: shares,
            createdByUid: actorUid,
            isDemo: true,
          ));
        }
        for (final spec in benchmarkFixed) {
          _list(doc, 'fixedExpenses').add({
            'id': spec.id,
            'groupId': groupId,
            'title': spec.title,
            'category': spec.category,
            'amountPaisa': spec.amountPaisa,
            'payerId': spec.payerId,
            'splitMemberIds': householdMembers.map((m) => m.id).toList(),
            'createdBy': actorUid,
            'createdAt': _nowIso(),
            'lastAppliedMonth': null,
          });
        }
        for (final spec in benchmarkShopping) {
          _list(doc, 'shopping').add({
            'id': spec.id,
            'groupId': groupId,
            'title': spec.title,
            'unit': spec.unit,
            'requestedQty': spec.qty,
            'status': 'Pending',
            'createdBy': actorUid,
            'createdAt': _nowIso(),
          });
        }
        await _store.save(doc);
        return benchmarkExpenses.length;
      });

  // ---- Invitations + shared households (Phase 4, local-only) ----
  // The invitation id IS the invite code (12 secure-random
  // characters, see domain/invitations.dart); expiry is 7 days from
  // creation; a stored-`pending` invitation past its expiry counts
  // as expired everywhere. Codes are generated and redeemed on the
  // SAME device only — there is no server to deliver them to, so
  // the inviter shares the code (or link text) with the invitee by
  // whatever channel they like, and the invitee enters it on this
  // device. See docs/INVITATIONS.md.

  /// Marks stored-`pending`, past-expiry invitations as `expired`
  /// in the document. Returns true when anything changed (so the
  /// caller saves once, not per invite).
  bool _sweepExpired(List<Map<String, dynamic>> invitations) {
    var changed = false;
    for (final raw in invitations) {
      final inv = invitationFromJson(raw);
      if (inv.isExpired && raw['status'] == 'pending') {
        raw['status'] = 'expired';
        changed = true;
      }
    }
    return changed;
  }

  @override
  Future<Invitation> createInvitation({
    required String groupId,
    required String groupName,
    required String invitedEmail,
    required String role,
    required String actorUid,
    required String? actorEmail,
    required String actorName,
  }) =>
      _guard(() async {
        final email = normalizeInviteEmail(invitedEmail);
        if (!isValidInviteEmail(email)) {
          throw const LocalDataException(
              'Enter a valid email address, like name@example.com.');
        }
        if (actorEmail != null &&
            email == normalizeInviteEmail(actorEmail)) {
          throw const LocalDataException(
              'You cannot invite yourself — that email is already in '
              'this household.');
        }
        if (role != 'member' && role != 'admin') {
          throw const LocalDataException(
              'Role must be member or admin.');
        }
        final doc = await _store.load();
        final actorRole = _requireRole(doc, groupId, actorUid);
        if (actorRole != 'owner' && actorRole != 'admin') {
          throw const LocalDataException(
              'Only the household owner or an admin can invite.');
        }
        if (role == 'admin' && actorRole != 'owner') {
          throw const LocalDataException(
              'Only the household owner can grant the admin role.');
        }
        // No duplicate ACTIVE invitation for the same email + group.
        // Past-expiry duplicates are swept, not blocking.
        final invitations = _list(doc, 'invitations');
        for (final raw in invitations) {
          if (raw['groupId'] != groupId ||
              raw['invitedEmail'] != email) {
            continue;
          }
          final dupe = invitationFromJson(raw);
          if (dupe.status == 'pending' && !dupe.isExpired) {
            throw LocalDataException(
                'An invitation is already pending for $email in this '
                'household.');
          }
        }
        if (_sweepExpired(invitations)) await _store.save(doc);
        // The code is the invitation id: a secure-random
        // 12-character code, retried on the (negligible) chance of
        // a collision.
        var code = '';
        for (var attempt = 0; attempt < 5; attempt++) {
          code = generateInviteCode();
          final collision =
              invitations.any((raw) => raw['id'] == code);
          if (!collision) break;
          if (attempt == 4) {
            throw const LocalDataException(
                'Could not create the invitation. Please try again.');
          }
        }
        final now = DateTime.now();
        final invitation = {
          'id': code,
          'groupId': groupId,
          'groupName': groupName,
          'invitedEmail': email,
          'invitedBy': actorUid,
          'inviterName': actorName,
          'role': role,
          'status': 'pending',
          'createdAt': now.toIso8601String(),
          'expiresAt': invitationExpiryFrom(now).toIso8601String(),
        };
        invitations.add(invitation);
        await _store.save(doc);
        return invitationFromJson(invitation);
      });

  @override
  Future<List<Invitation>> getGroupInvitations(String groupId) =>
      _guard(() async {
        final doc = await _store.load();
        final invitations = _list(doc, 'invitations')
            .where((i) => i['groupId'] == groupId)
            .toList();
        // Admin-side sweep: past-expiry pending invites are stored
        // as expired.
        if (_sweepExpired(invitations)) await _store.save(doc);
        final invites =
            invitations.map(invitationFromJson).toList();
        invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return invites;
      });

  @override
  Future<List<Invitation>> getMyInvitations(String email) =>
      _guard(() async {
        final doc = await _store.load();
        final clean = normalizeInviteEmail(email);
        final invites = _list(doc, 'invitations')
            .where((i) => i['invitedEmail'] == clean)
            .map(invitationFromJson)
            .toList();
        invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        // No sweep here: expiry stays derived via
        // Invitation.isExpired / effectiveStatus.
        return invites;
      });

  @override
  Future<void> revokeInvitation({
    required String groupId,
    required String invitationId,
    required String actorUid,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final role = _requireRole(doc, groupId, actorUid);
        if (role != 'owner' && role != 'admin') {
          throw const LocalDataException(
              'Only the household owner or an admin can revoke an '
              'invitation.');
        }
        final invitations = _list(doc, 'invitations');
        final index = invitations.indexWhere(
            (i) => i['id'] == invitationId && i['groupId'] == groupId);
        if (index < 0) {
          throw const LocalDataException('Invitation not found.');
        }
        if (invitations[index]['status'] != 'pending') {
          throw const LocalDataException(
              'This invitation is no longer pending.');
        }
        invitations[index]['status'] = 'revoked';
        await _store.save(doc);
      });

  @override
  Future<Invitation> acceptInvitation({
    required String invitationId,
    required String actorUid,
    required String email,
    required String displayName,
  }) =>
      _guard(() async {
        final cleanEmail = normalizeInviteEmail(email);
        if (cleanEmail.isEmpty || !isValidInviteEmail(cleanEmail)) {
          throw const LocalDataException(
              'Sign in with an email address to accept an invitation.');
        }
        final code = normalizeInviteCode(invitationId);
        if (code.isEmpty) {
          throw const LocalDataException(
              'Enter an invite code to join a household.');
        }
        final doc = await _store.load();
        final invitations = _list(doc, 'invitations');
        final index = invitations.indexWhere((i) => i['id'] == code);
        if (index < 0) {
          throw const LocalDataException('Invitation not found.');
        }
        final raw = invitations[index];
        final inv = invitationFromJson(raw);
        if (inv.status == 'accepted') {
          throw const LocalDataException(
              'This invitation has already been accepted.');
        }
        if (inv.status != 'pending') {
          throw const LocalDataException(
              'This invitation is no longer pending.');
        }
        if (inv.isExpired) {
          throw const LocalDataException(
              'This invitation has expired. Ask for a new one.');
        }
        if (inv.invitedEmail != cleanEmail) {
          throw const LocalDataException(
              'This invitation was sent to a different email '
              'address. Sign in with that email to accept it.');
        }
        final grantedRole = inv.role == 'admin' ? 'admin' : 'member';
        // One save: the membership AND the accepted status change
        // together, or nothing changes.
        final group = _group(doc, inv.groupId);
        if (group == null) {
          throw const LocalDataException('Group not found.');
        }
        final memberId =
            _memberIdForUid(doc, actorUid, inv.groupId) ?? actorUid;
        final members =
            (group['members'] as List).cast<Map<String, dynamic>>();
        final memberIndex =
            members.indexWhere((m) => m['uid'] == actorUid);
        final entry = {
          'uid': actorUid,
          'memberId': memberId,
          'role': grantedRole,
          'displayName': displayName,
          'photoUrl': null,
          'joinedAt': _nowIso(),
        };
        if (memberIndex >= 0) {
          members[memberIndex] = entry;
        } else {
          members.add(entry);
        }
        raw['status'] = 'accepted';
        raw['acceptedBy'] = actorUid;
        raw['acceptedAt'] = _nowIso();
        await _store.save(doc);
        await logActivity(
          groupId: inv.groupId,
          entry: ActivityEntry(
            type: 'member_joined',
            title: '$displayName joined the group',
            amount: '0.00',
            memberId: actorUid,
            detail: inv.groupName,
            timestamp: DateTime.now(),
          ),
          actorUid: actorUid,
        );
        return inv.copyWith(status: 'accepted', acceptedBy: actorUid);
      });

  @override
  Future<List<GroupSummary>> listUserGroups({
    required String uid,
    required String? email,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        final groups = <GroupSummary>[];
        for (final g in _list(doc, 'groups')) {
          final members = (g['members'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          final entry =
              members.where((m) => m['uid'] == uid).firstOrNull;
          if (entry == null) continue;
          groups.add(GroupSummary(
            groupId: g['id'] as String,
            name: g['name'] as String? ?? 'SplitNest Household',
            budgetPaisa: (g['budgetPaisa'] as num?)?.toInt() ??
                defaultBudgetPaisa,
            role: entry['role'] as String?,
          ));
        }
        // The user's own group first, then the rest by name.
        groups.sort((a, b) {
          if (a.groupId == 'household-$uid') return -1;
          if (b.groupId == 'household-$uid') return 1;
          return a.name.compareTo(b.name);
        });
        return groups;
      });

  @override
  Future<String?> getMyRole({
    required String groupId,
    required String uid,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        return _roleOf(doc, groupId, uid);
      });

  @override
  Future<List<ChatMessage>> getChatMessages(String uid) =>
      _guard(() async {
        final doc = await _store.load();
        final messages = _chatList(doc)
            .where((m) => m['userId'] == uid)
            .map(chatMessageFromJson)
            .toList();
        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return messages;
      });

  @override
  Future<void> addChatMessage({
    required String uid,
    required ChatMessage message,
  }) =>
      _guard(() async {
        final doc = await _store.load();
        _chatList(doc).add(message.toJson());
        await _store.save(doc);
      });

  @override
  Future<void> clearChatMessages(String uid) => _guard(() async {
        final doc = await _store.load();
        _chatList(doc).removeWhere((m) => m['userId'] == uid);
        await _store.save(doc);
      });

  @override
  Future<void> logActivity({
    required String groupId,
    required ActivityEntry entry,
    required String actorUid,
  }) async {
    // Persisted into lock.json now (it used to be best-effort
    // against the cloud). A failure here must still never fail the
    // mutation the entry describes — log it and continue. The app's
    // session activity log is the Timeline source of truth.
    try {
      final doc = await _store.load();
      _list(doc, 'activity').add({
        'groupId': groupId,
        'type': entry.type,
        'actorUid': actorUid,
        'title': entry.title,
        'amount': entry.amount,
        'memberId': entry.memberId,
        'detail': entry.detail,
        'timestamp': entry.timestamp.toIso8601String(),
      });
      await _store.save(doc);
    } catch (e) {
      debugPrint('SplitNest: local activity log skipped ($e)');
    }
  }
}
