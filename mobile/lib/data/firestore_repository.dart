import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../core/money.dart';
import '../domain/balances.dart';
import '../domain/expense_auth.dart';
import '../domain/invitations.dart';
import '../domain/models.dart';
import '../domain/payment_tracking.dart';
import 'demo_benchmark.dart';
import 'repository.dart';

/// Enables Firestore offline persistence. Call once, right after
/// `Firebase.initializeApp()` and before any Firestore use (see
/// `main.dart`). Persistence means reads/writes keep working offline
/// and sync when the device comes back; it never invents data — a
/// collection that was never synced still reads as empty, and the
/// app shows its empty state, not a fake one. Safe to call when
/// Firebase is not initialised: it logs and returns.
void configureFirestorePersistence() {
  try {
    FirebaseFirestore.instance.settings =
        const Settings(persistenceEnabled: true);
  } catch (e) {
    // Settings can only be applied once / before use: if that already
    // happened (or Firebase is not initialised), persistence just
    // stays as it was — the app still works, online only.
    debugPrint('SplitNest: Firestore persistence not applied ($e)');
  }
}

/// Pure Firestore mapping helpers (exported for tests — they need no
/// Firestore instance, so they run in plain unit tests).

/// Parses a `yyyy-MM-dd` date string into a Firestore [Timestamp]
/// (local noon, so no timezone shifts the day).
Timestamp timestampFromDateString(String date) {
  final parts = date.split('-');
  if (parts.length != 3) return Timestamp.now();
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return Timestamp.now();
  return Timestamp.fromDate(DateTime(y, m, d, 12));
}

/// Formats a Firestore [Timestamp] as `yyyy-MM-dd`.
String dateStringFromTimestamp(Timestamp ts) {
  final d = ts.toDate();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Builds the Firestore document data for one expense, following
/// docs/FIRESTORE_STRUCTURE.md exactly: integer paisa, a `splits`
/// map whose values sum to `amountPaisa`, `paidBy` / `createdBy` as
/// the stored member keys, `expenseDate` as a Timestamp.
Map<String, Object?> expenseDocData({
  required String title,
  required String category,
  required int amountPaisa,
  required String date,
  required String paidByKey,
  required String splitType,
  required Map<String, int> splits,
  required String createdByUid,
  String? fixedExpenseId,
  String? note,
  bool isDemoData = false,
}) {
  return {
    'title': title,
    'category': category,
    'amountPaisa': amountPaisa,
    'expenseDate': timestampFromDateString(date),
    'paidBy': paidByKey,
    'splitType': splitType,
    'splits': splits,
    ...?fixedExpenseId == null ? null : {'fixedExpenseId': fixedExpenseId},
    ...?note == null ? null : {'note': note},
    'createdBy': createdByUid,
    'createdAt': Timestamp.now(),
    'updatedAt': Timestamp.now(),
    if (isDemoData) 'isDemoData': true,
  };
}

/// Reads one expense document back into an [ExpenseRecord].
/// [memberIdForKey] translates a stored splits/paidBy key (a Firebase
/// UID when the member has signed in, otherwise the legacy member id)
/// back to the app's member id (`M01`…).
ExpenseRecord expenseRecordFromData(
  String id,
  Map<String, dynamic> data,
  String Function(String key) memberIdForKey,
) {
  final splits = data['splits'] as Map<String, dynamic>? ?? {};
  final expenseDate = data['expenseDate'];
  return ExpenseRecord(
    id: id,
    title: data['title'] as String? ?? '',
    category: data['category'] as String? ?? 'General',
    amount: formatPaisa((data['amountPaisa'] as num?)?.toInt() ?? 0),
    payerId: memberIdForKey(data['paidBy'] as String? ?? ''),
    date: expenseDate is Timestamp
        ? dateStringFromTimestamp(expenseDate)
        : null,
    splitType: data['splitType'] as String?,
    shares: splits.entries
        .map((e) => ExpenseShare(
              memberId: memberIdForKey(e.key),
              amount: formatPaisa((e.value as num).toInt()),
            ))
        .toList(),
    isDemo: data['isDemoData'] == true,
    createdByUid: data['createdBy'] as String?,
    receiptUrl: data['receiptUrl'] as String?,
    receiptPath: data['receiptPath'] as String?,
  );
}

/// Reads one payment document back into a [PaymentRecord].
PaymentRecord paymentRecordFromData(
  String id,
  Map<String, dynamic> data,
  String Function(String key) memberIdForKey,
) {
  final createdAt = data['createdAt'];
  final verifiedAt = data['verifiedAt'];
  final rejectedAt = data['rejectedAt'];
  return PaymentRecord(
    id: id,
    senderId: memberIdForKey(data['fromUid'] as String? ?? ''),
    recipientId: memberIdForKey(data['toUid'] as String? ?? ''),
    amount: formatPaisa((data['amountPaisa'] as num?)?.toInt() ?? 0),
    status: data['status'] as String? ?? 'recorded',
    verifiedBy: data['verifiedBy'] as String?,
    verifiedAt: verifiedAt is Timestamp ? verifiedAt.toDate() : null,
    rejectedBy: data['rejectedBy'] as String?,
    rejectedAt: rejectedAt is Timestamp ? rejectedAt.toDate() : null,
    createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
  );
}

/// Reads one fixed-template document back into a [FixedExpense].
FixedExpense fixedExpenseFromData(
  String id,
  Map<String, dynamic> data,
  String Function(String key) memberIdForKey,
) {
  final splitKeys = data['splitMemberUids'] as List? ?? [];
  return FixedExpense(
    id: id,
    title: data['title'] as String? ?? '',
    category: data['category'] as String? ?? 'General',
    amount: formatPaisa((data['amountPaisa'] as num?)?.toInt() ?? 0),
    payerId: memberIdForKey(data['payerUid'] as String? ?? ''),
    splitMemberIds: splitKeys.map((k) => memberIdForKey(k as String)).toList(),
  );
}

/// Reads one shopping document back into a [ShoppingItem].
ShoppingItem shoppingItemFromData(String id, Map<String, dynamic> data) {
  return ShoppingItem(
    id: id,
    title: data['title'] as String? ?? '',
    unit: data['unit'] as String? ?? 'pack',
    requestedQty: (data['requestedQty'] as num?)?.toInt() ?? 1,
    status: data['status'] as String? ?? 'Pending',
  );
}

/// Reads one invitation document back into an [Invitation]. The
/// document id IS the invite code (see `domain/invitations.dart`).
Invitation invitationFromData(
  String id,
  Map<String, dynamic> data,
) {
  final createdAt = data['createdAt'];
  final expiresAt = data['expiresAt'];
  final acceptedAt = data['acceptedAt'];
  return Invitation(
    id: id,
    groupId: data['groupId'] as String? ?? '',
    groupName: data['groupName'] as String? ?? '',
    invitedEmail: data['invitedEmail'] as String? ?? '',
    invitedBy: data['invitedBy'] as String? ?? '',
    inviterName: data['inviterName'] as String?,
    role: data['role'] as String? ?? 'member',
    status: data['status'] as String? ?? 'pending',
    createdAt:
        createdAt is Timestamp ? createdAt.toDate() : DateTime.now(),
    expiresAt: expiresAt is Timestamp
        ? expiresAt.toDate()
        : DateTime.now().add(
            const Duration(days: invitationValidityDays)),
    acceptedBy: data['acceptedBy'] as String?,
    acceptedAt: acceptedAt is Timestamp ? acceptedAt.toDate() : null,
  );
}

/// Reads one activity document back into an [ActivityEntry].
ActivityEntry activityEntryFromData(Map<String, dynamic> data) {
  final createdAt = data['createdAt'];
  return ActivityEntry(
    type: data['type'] as String? ?? 'expense',
    title: data['title'] as String? ?? '',
    amount: data['amount'] as String? ?? '0.00',
    memberId: data['memberId'] as String? ?? '',
    detail: data['detail'] as String? ?? '',
    timestamp:
        createdAt is Timestamp ? createdAt.toDate() : DateTime.now(),
  );
}

/// Firestore implementation of [SplitNestRepository] — Cloud
/// Firestore is the app's ONLY data source.
///
/// Member identity: the app works in legacy member ids (`M01`…)
/// everywhere; Firestore documents store Firebase UIDs wherever the
/// security rules check membership (`paidBy`, `splits` keys,
/// `fromUid`/`toUid`, the group `members` map). This repository
/// translates at the boundary: a member id maps to the UID of the
/// Firebase user linked to it when that UID is known (from the
/// `members` subcollection mirror), and to the member id itself
/// otherwise. See docs/FIRESTORE_STRUCTURE.md § "Phase 3
/// implementation notes" for the consequences (a member who has never
/// signed in has no UID yet, so cross-member writes for them are
/// rejected by the rules until the invite-accept Function lands the
/// membership — the failure surfaces as the plain cloud-unavailable
/// message, never as fake data).
class FirestoreSplitNestRepository implements SplitNestRepository {
  FirestoreSplitNestRepository({FirebaseFirestore? firestore, FirebaseStorage? storage}) {
    _firestore = firestore;
    _storageOverride = storage;
  }

  FirebaseFirestore? _firestore;

  FirebaseFirestore get _store => _firestore ??= FirebaseFirestore.instance;

  /// UID ↔ legacy member id, learned from the `members` mirror of
  /// the group most recently read. Populated by [ensureGroup] and
  /// [getMembers]; writes translate through it.
  final Map<String, String> _uidByMember = {};
  final Map<String, String> _memberByUid = {};

  void _learnMapping(String memberId, String? uid) {
    if (uid == null || uid.isEmpty) return;
    _uidByMember[memberId] = uid;
    _memberByUid[uid] = memberId;
  }

  /// The stored Firestore key for an app member id: the Firebase UID
  /// when known, the member id itself otherwise.
  String _keyFor(String memberId) => _uidByMember[memberId] ?? memberId;

  /// The app member id for a stored Firestore key.
  String _memberFor(String key) => _memberByUid[key] ?? key;

  DocumentReference<Map<String, dynamic>> _groupDoc(String groupId) =>
      _store.collection('groups').doc(groupId);

  CollectionReference<Map<String, dynamic>> _sub(
          String groupId, String name) =>
      _groupDoc(groupId).collection(name);

  /// Runs [fn], translating Firestore failures into the plain
  /// [CloudDataException] the UI shows. [CloudDataException]s thrown
  /// by the shared validators pass through unchanged. Anything else
  /// becomes the generic message — raw SDK text never reaches the
  /// screen, and no failure ever returns fake data.
  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on CloudDataException {
      rethrow;
    } on FirebaseException catch (e) {
      debugPrint('SplitNest: Firestore call failed (${e.code}): $e');
      throw const CloudDataException(cloudUnavailableMessage);
    } catch (e) {
      debugPrint('SplitNest: Firestore call failed: $e');
      throw const CloudDataException(
          'Something went wrong. Please try again.');
    }
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _monthKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
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
        // Deterministic per-user group id until the invite flow can
        // move users between groups (see the class doc comment).
        final groupId = 'household-$uid';
        final doc = _groupDoc(groupId);
        final snap = await doc.get();
        if (!snap.exists) {
          final batch = _store.batch();
          batch.set(doc, {
            'name': 'SplitNest Household',
            'createdBy': uid,
            'createdAt': Timestamp.now(),
            'budgetPaisa': defaultBudgetPaisa,
            'currency': 'PKR',
            'members': {
              uid: {
                'role': 'owner',
                'joinedAt': Timestamp.now(),
              },
            },
          });
          // Members mirror: the creator (doc id = UID, role owner)
          // plus the other two household members as roster entries
          // (doc id = legacy member id; they get a UID-backed doc
          // when they sign in and join). This seeds the 3-member
          // household the screens show, with the PKR 5,000 budget.
          for (final m in householdMembers) {
            final isCreator = m.id == legacyMemberId;
            final ref = isCreator
                ? doc.collection('members').doc(uid)
                : doc.collection('members').doc(m.id);
            batch.set(ref, {
              'displayName': isCreator ? displayName : m.name,
              'role': isCreator ? 'owner' : 'member',
              'legacyMemberId': m.id,
              'joinedAt': Timestamp.now(),
              if (isCreator) 'uid': uid,
            });
          }
          await batch.commit();
          // Remember the creator's own mapping for later writes.
          _learnMapping(legacyMemberId, uid);
          // The user's doc records which group they belong to (used
          // by the later invite flow); best-effort, never blocking.
          try {
            await _store.collection('users').doc(uid).set({
              'displayName': displayName,
              'email': email?.toLowerCase(),
              'legacyMemberId': legacyMemberId,
              'groupId': groupId,
              'updatedAt': Timestamp.now(),
            }, SetOptions(merge: true));
          } catch (e) {
            debugPrint('SplitNest: users group link skipped ($e)');
          }
          return GroupInfo(
              groupId: groupId, budgetPaisa: defaultBudgetPaisa);
        }
        final data = snap.data() ?? {};
        await _refreshMappings(groupId);
        return GroupInfo(
          groupId: groupId,
          budgetPaisa: (data['budgetPaisa'] as num?)?.toInt() ??
              defaultBudgetPaisa,
        );
      });

  /// Re-reads the members mirror into the UID maps.
  Future<void> _refreshMappings(String groupId) async {
    try {
      final snap = await _sub(groupId, 'members').get();
      for (final d in snap.docs) {
        final data = d.data();
        final legacy = data['legacyMemberId'] as String? ?? d.id;
        final uid = data['uid'] as String? ?? (d.id == legacy ? null : d.id);
        _learnMapping(legacy, uid);
      }
    } catch (e) {
      debugPrint('SplitNest: member mapping refresh skipped ($e)');
    }
  }

  @override
  Future<List<Member>> getMembers(String groupId) => _guard(() async {
        final snap = await _sub(groupId, 'members').get();
        final members = <Member>[];
        for (final d in snap.docs) {
          final data = d.data();
          final legacy = data['legacyMemberId'] as String? ?? d.id;
          final uid =
              data['uid'] as String? ?? (d.id == legacy ? null : d.id);
          _learnMapping(legacy, uid);
          members.add(Member(
            id: legacy,
            name: data['displayName'] as String? ?? legacy,
            photoUrl: data['photoUrl'] as String?,
          ));
        }
        members.sort((a, b) => a.id.compareTo(b.id));
        return members;
      });

  @override
  Future<List<ShoppingItem>> getShopping(String groupId) =>
      _guard(() async {
        final snap = await _sub(groupId, 'shopping').get();
        final docs = snap.docs.toList();
        // Creation order (createdAt, then doc id): doc ids are random
        // auto-ids, so sorting by id alone would scramble the list
        // — and the checkout title is built from this order.
        docs.sort((a, b) {
          final ca = a.data()['createdAt'];
          final cb = b.data()['createdAt'];
          final ta = ca is Timestamp ? ca : null;
          final tb = cb is Timestamp ? cb : null;
          if (ta == null && tb == null) return a.id.compareTo(b.id);
          if (ta == null) return 1;
          if (tb == null) return -1;
          final byTime = ta.compareTo(tb);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
        return docs
            .map((d) => shoppingItemFromData(d.id, d.data()))
            .toList();
      });

  @override
  Future<List<ExpenseRecord>> getExpenses(String groupId) =>
      _guard(() async {
        final snap = await _sub(groupId, 'expenses').get();
        final expenses = snap.docs
            .map((d) =>
                expenseRecordFromData(d.id, d.data(), _memberFor))
            .toList();
        // Newest first: expenseDate desc, then createdAt desc. The
        // sort is client-side so no composite index is needed.
        expenses.sort((a, b) {
          final da = a.date ?? '';
          final db = b.date ?? '';
          final byDate = db.compareTo(da);
          if (byDate != 0) return byDate;
          return b.id.compareTo(a.id);
        });
        return expenses;
      });

  @override
  Future<List<PaymentRecord>> getPayments(String groupId) =>
      _guard(() async {
        final snap = await _sub(groupId, 'payments').get();
        final payments = snap.docs
            .map((d) => paymentRecordFromData(d.id, d.data(), _memberFor))
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
        final snap = await _sub(groupId, 'fixedExpenses').get();
        final fixed = snap.docs
            .map((d) => fixedExpenseFromData(d.id, d.data(), _memberFor))
            .toList();
        fixed.sort((a, b) => a.id.compareTo(b.id));
        return fixed;
      });

  @override
  Future<List<ActivityEntry>> getActivity(String groupId) =>
      _guard(() async {
        final snap = await _sub(groupId, 'activity').get();
        final entries = snap.docs
            .map((d) => activityEntryFromData(d.data()))
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
          throw const CloudDataException('Title is required.');
        }
        if (!shoppingUnits.contains(unit)) {
          throw CloudDataException(
              'Unit must be one of: ${shoppingUnits.join(', ')}.');
        }
        if (qty <= 0) {
          throw const CloudDataException(
              'Quantity must be a positive whole number.');
        }
        final ref = await _sub(groupId, 'shopping').add({
          'title': title.trim(),
          'unit': unit,
          'requestedQty': qty,
          'status': 'Pending',
          'createdBy': actorUid,
          'createdAt': Timestamp.now(),
        });
        return ShoppingItem(
          id: ref.id,
          title: title.trim(),
          unit: unit,
          requestedQty: qty,
          status: 'Pending',
        );
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
          throw const CloudDataException(
              'Total paid must be a positive amount.');
        }
        final members = await getMembers(groupId);
        final known = members.map((m) => m.id).toList();
        final items = await getShopping(groupId);
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
        final expenseRef = _sub(groupId, 'expenses').doc();
        final date = _todayString();
        // One transaction: exactly one expense is posted AND the
        // items become Bought, or nothing changes (the old backend's
        // atomic-checkout guarantee, now a Firestore transaction).
        await _store.runTransaction((tx) async {
          for (final id in itemIds) {
            final itemRef = _sub(groupId, 'shopping').doc(id);
            final snap = await tx.get(itemRef);
            final data = snap.data();
            if (data == null || data['status'] != 'Pending') {
              throw const CloudDataException(
                  'One of the selected items is already bought.');
            }
          }
          tx.set(
            expenseRef,
            expenseDocData(
              title: 'Shopping: ${titles.join(', ')}',
              category: 'Groceries',
              amountPaisa: totalPaisa,
              date: date,
              paidByKey: _keyFor(payerId),
              splitType: 'equal',
              splits: {
                for (final s in shares) _keyFor(s.memberId): s.amountPaisa,
              },
              createdByUid: actorUid,
            ),
          );
          for (final id in itemIds) {
            tx.update(_sub(groupId, 'shopping').doc(id), {
              'status': 'Bought',
              'checkoutExpenseId': expenseRef.id,
            });
          }
        });
        return ExpenseRecord(
          id: expenseRef.id,
          title: 'Shopping: ${titles.join(', ')}',
          category: 'Groceries',
          amount: formatPaisa(totalPaisa),
          payerId: payerId,
          date: date,
          splitType: 'equal',
          shares: shares
              .map((s) => ExpenseShare(
                    memberId: s.memberId,
                    amount: formatPaisa(s.amountPaisa),
                  ))
              .toList(),
        );
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
          throw const CloudDataException('Title is required.');
        }
        final amountPaisa = parsePaisa(amount);
        if (amountPaisa == null || amountPaisa <= 0) {
          throw const CloudDataException(
              'Amount must be a positive amount.');
        }
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
          throw const CloudDataException('Date must be YYYY-MM-DD.');
        }
        final members = await getMembers(groupId);
        final known = members.map((m) => m.id).toList();
        if (!known.contains(payerId)) {
          throw CloudDataException('Payer $payerId does not exist.');
        }
        final shares = validatedShares(
          amountPaisa: amountPaisa,
          splitType: splitType,
          splits: splits,
          splitMembers: splitMembers,
          percentageSplits: percentageSplits,
          knownMembers: known,
        );
        final ref = await _sub(groupId, 'expenses').add(
          expenseDocData(
            title: title.trim(),
            category: category.trim().isEmpty ? 'General' : category.trim(),
            amountPaisa: amountPaisa,
            date: date,
            paidByKey: _keyFor(payerId),
            splitType: splitType,
            splits: {
              for (final s in shares) _keyFor(s.memberId): s.amountPaisa,
            },
            createdByUid: actorUid,
          ),
        );
        return ExpenseRecord(
          id: ref.id,
          title: title.trim(),
          category: category.trim().isEmpty ? 'General' : category.trim(),
          amount: formatPaisa(amountPaisa),
          payerId: payerId,
          date: date,
          splitType: splitType,
          shares: shares
              .map((s) => ExpenseShare(
                    memberId: s.memberId,
                    amount: formatPaisa(s.amountPaisa),
                  ))
              .toList(),
          createdByUid: actorUid,
        );
      });

  /// Authorisation for an expense edit/delete: the actor is the
  /// expense's creator (or payer, via the stored key) or a group
  /// owner/admin. Mirrors domain/expense_auth.dart. NOTE: this is
  /// enforced here and in the UI, but `firestore.rules` still
  /// allows expense update/delete by owner/admin ONLY — on a live
  /// Firebase DB a creator edit/delete would be denied until the
  /// rules gain the creator branch. That rules change is pending
  /// the backend-store decision and was deliberately NOT made here.
  Future<void> _requireExpenseEditAllowed({
    required String groupId,
    required Map<String, dynamic> data,
    required String actorUid,
  }) async {
    final createdBy = data['createdBy'] as String?;
    final paidBy = data['paidBy'] as String?;
    String? role;
    try {
      role = await _roleInGroup(groupId, actorUid);
    } catch (_) {
      role = null;
    }
    final allowed = canEditExpense(
      isAdmin: role == 'owner' || role == 'admin',
      actorUid: actorUid,
      actorMemberId: _memberFor(actorUid),
      createdByUid: createdBy,
      payerMemberId: _memberFor(paidBy ?? ''),
    );
    if (!allowed) {
      throw const CloudDataException(
          'Only the member who added this expense (or the household '
          'owner/admin) can change or delete it.');
    }
  }

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
        final ref = _sub(groupId, 'expenses').doc(id);
        final snap = await ref.get();
        final data = snap.data();
        if (data == null) {
          throw const CloudDataException('Expense not found.');
        }
        await _requireExpenseEditAllowed(
          groupId: groupId,
          data: data,
          actorUid: actorUid,
        );
        final members = await getMembers(groupId);
        final known = members.map((m) => m.id).toList();
        final newTitle = title?.trim() ?? data['title'] as String? ?? '';
        if (newTitle.isEmpty) {
          throw const CloudDataException('Title is required.');
        }
        final newAmountPaisa = amount == null
            ? (data['amountPaisa'] as num?)?.toInt() ?? 0
            : parsePaisa(amount);
        if (newAmountPaisa == null || newAmountPaisa <= 0) {
          throw const CloudDataException(
              'Amount must be a positive amount.');
        }
        final newDate = date ?? () {
          final d = data['expenseDate'];
          return d is Timestamp ? dateStringFromTimestamp(d) : null;
        }();
        if (newDate == null ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(newDate)) {
          throw const CloudDataException('Date must be YYYY-MM-DD.');
        }
        final newPayerId = payerId ?? _memberFor(data['paidBy'] as String? ?? '');
        if (!known.contains(newPayerId)) {
          throw CloudDataException('Payer $newPayerId does not exist.');
        }
        final newSplitType = splitType ?? data['splitType'] as String? ?? 'equal';
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
          final stored = data['splits'] as Map<String, dynamic>? ?? {};
          shares = validatedShares(
            amountPaisa: newAmountPaisa,
            splitType: 'equal',
            splitMembers:
                stored.keys.map(_memberFor).toList()..sort(),
            knownMembers: known,
          );
        } else {
          final stored = data['splits'] as Map<String, dynamic>? ?? {};
          final storedShares = stored.entries
              .map((e) => ExpenseShare(
                    memberId: _memberFor(e.key),
                    amount: formatPaisa((e.value as num).toInt()),
                  ))
              .toList();
          // Amount unchanged + stored custom/percentage shares:
          // they already sum to the old amount, which equals the
          // new one here (amount changes with a split change go
          // through validatedShares above). Re-validate the sum so
          // a corrupt stored doc can never be re-saved as-is.
          final sum = storedShares.fold(
              0, (s, sh) => s + (parsePaisa(sh.amount) ?? 0));
          if (sum != newAmountPaisa) {
            throw CloudDataException(
                'Stored shares sum to ${formatPaisa(sum)} but the amount '
                'is ${formatPaisa(newAmountPaisa)} — re-enter the split.');
          }
          shares = storedShares
              .map((sh) => (
                    memberId: sh.memberId,
                    amountPaisa: parsePaisa(sh.amount) ?? 0,
                  ))
              .toList();
        }
        final updates = <String, Object?>{
          'title': newTitle,
          'category': category?.trim().isEmpty ?? true
              ? data['category'] as String? ?? 'General'
              : category!.trim(),
          'amountPaisa': newAmountPaisa,
          'expenseDate': timestampFromDateString(newDate),
          'paidBy': _keyFor(newPayerId),
          'splitType': newSplitType,
          'splits': {
            for (final s in shares) _keyFor(s.memberId): s.amountPaisa,
          },
          'updatedAt': Timestamp.now(),
        };
        if (receiptUrl != null) updates['receiptUrl'] = receiptUrl;
        if (receiptPath != null) updates['receiptPath'] = receiptPath;
        await ref.update(updates);
        final fresh = await ref.get();
        return expenseRecordFromData(id, fresh.data() ?? {}, _memberFor);
      });

  @override
  Future<void> deleteExpense({
    required String groupId,
    required String id,
    required String actorUid,
  }) =>
      _guard(() async {
        final ref = _sub(groupId, 'expenses').doc(id);
        final snap = await ref.get();
        final data = snap.data();
        if (data == null) {
          throw const CloudDataException('Expense not found.');
        }
        await _requireExpenseEditAllowed(
          groupId: groupId,
          data: data,
          actorUid: actorUid,
        );
        await ref.delete();
      });

  @override
  Future<void> setUserPhotoUrl({
    required String groupId,
    required String uid,
    required String photoUrl,
  }) async {
    // Best-effort mirror update: the members-mirror doc is keyed by
    // UID for joined members but by legacy id for roster entries
    // that never signed in — a miss there is not a failure, and the
    // users-doc write below is the durable record.
    try {
      await _store.collection('users').doc(uid).set({
        'photoUrl': photoUrl,
        'updatedAt': Timestamp.now(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('SplitNest: user photoUrl skipped ($e)');
    }
    try {
      await _sub(groupId, 'members').doc(uid).set({
        'photoUrl': photoUrl,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('SplitNest: member mirror photoUrl skipped ($e)');
    }
  }

  // ---- File uploads (Phase 5) ----
  // The Storage implementation behind the repository interface:
  // widgets and AppState only ever call the interface methods, so a
  // local-store implementation can replace these without touching
  // any screen. Storage is resolved lazily (see _storage) so
  // building this repository never touches Firebase.

  FirebaseStorage? _storageOverride;
  FirebaseStorage get _storage =>
      _storageOverride ?? FirebaseStorage.instance;

  static const int _maxReceiptBytes = 10 * 1024 * 1024;
  static const int _maxProfilePhotoBytes = 5 * 1024 * 1024;

  @override
  Future<({String url, String path})?> uploadReceipt({
    required String groupId,
    required String expenseId,
    required Uint8List bytes,
  }) async {
    if (bytes.length > _maxReceiptBytes) return null;
    final path = 'receipts/$groupId/$expenseId/receipt.jpg';
    try {
      final ref = _storage.ref(path);
      await ref.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      return (url: await ref.getDownloadURL(), path: path);
    } catch (e) {
      debugPrint('SplitNest: receipt upload failed ($e)');
      return null;
    }
  }

  @override
  Future<String?> uploadProfilePhoto({
    required String uid,
    required Uint8List bytes,
  }) async {
    if (bytes.length > _maxProfilePhotoBytes) return null;
    final path = 'profile-photos/$uid/photo.jpg';
    try {
      final ref = _storage.ref(path);
      await ref.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('SplitNest: profile photo upload failed ($e)');
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
          throw const CloudDataException(
              'Settlement amount must be positive.');
        }
        // Validate against the live ledger before writing anything.
        final members = await getMembers(groupId);
        final expenses = await getExpenses(groupId);
        final payments = await getPayments(groupId);
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
        if (error != null) throw CloudDataException(error);
        final ref = await _sub(groupId, 'payments').add({
          'fromUid': _keyFor(senderId),
          'toUid': _keyFor(recipientId),
          'amountPaisa': amountPaisa,
          'status': 'recorded',
          'recordedBy': actorUid,
          'createdAt': Timestamp.now(),
        });
        return PaymentRecord(
          id: ref.id,
          senderId: senderId,
          recipientId: recipientId,
          amount: formatPaisa(amountPaisa),
          status: 'recorded',
        );
      });

  @override
  Future<PaymentRecord> verifyPayment({
    required String groupId,
    required String paymentId,
    required String actorUid,
  }) =>
      _guard(() async {
        final ref = _sub(groupId, 'payments').doc(paymentId);
        final snap = await ref.get();
        final data = snap.data();
        if (data == null) {
          throw const CloudDataException('Payment not found.');
        }
        final role = await _roleInGroup(groupId, actorUid);
        final error = paymentStatusTransitionError(
          current: data['status'] as String? ?? 'recorded',
          target: 'verified',
          isAdmin: role == 'owner' || role == 'admin',
        );
        if (error != null) throw CloudDataException(error);
        final verifiedAt = Timestamp.now();
        await ref.update({
          'status': 'verified',
          'verifiedBy': actorUid,
          'verifiedAt': verifiedAt,
        });
        return paymentRecordFromData(paymentId, {
          ...data,
          'status': 'verified',
          'verifiedBy': actorUid,
          'verifiedAt': verifiedAt,
        }, _memberFor);
      });

  @override
  Future<PaymentRecord> rejectPayment({
    required String groupId,
    required String paymentId,
    required String actorUid,
  }) =>
      _guard(() async {
        final ref = _sub(groupId, 'payments').doc(paymentId);
        final snap = await ref.get();
        final data = snap.data();
        if (data == null) {
          throw const CloudDataException('Payment not found.');
        }
        final role = await _roleInGroup(groupId, actorUid);
        final error = paymentStatusTransitionError(
          current: data['status'] as String? ?? 'recorded',
          target: 'rejected',
          isAdmin: role == 'owner' || role == 'admin',
        );
        if (error != null) throw CloudDataException(error);
        final rejectedAt = Timestamp.now();
        await ref.update({
          'status': 'rejected',
          'rejectedBy': actorUid,
          'rejectedAt': rejectedAt,
        });
        return paymentRecordFromData(paymentId, {
          ...data,
          'status': 'rejected',
          'rejectedBy': actorUid,
          'rejectedAt': rejectedAt,
        }, _memberFor);
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
          throw const CloudDataException('Title is required.');
        }
        final amountPaisa = parsePaisa(amount);
        if (amountPaisa == null || amountPaisa <= 0) {
          throw const CloudDataException(
              'Amount must be a positive amount.');
        }
        final members = await getMembers(groupId);
        final known = members.map((m) => m.id).toList();
        if (!known.contains(payerId)) {
          throw CloudDataException('Payer $payerId does not exist.');
        }
        final splitIds = (splitMemberIds != null && splitMemberIds.isNotEmpty)
            ? splitMemberIds
            : known;
        if (splitIds.toSet().length != splitIds.length ||
            splitIds.any((m) => !known.contains(m))) {
          throw const CloudDataException(
              'Split members must be known members, listed once.');
        }
        final ref = await _sub(groupId, 'fixedExpenses').add({
          'title': title.trim(),
          'category': category.trim().isEmpty ? 'General' : category.trim(),
          'amountPaisa': amountPaisa,
          'payerUid': _keyFor(payerId),
          'splitMemberUids': splitIds.map(_keyFor).toList(),
          'createdBy': actorUid,
          'createdAt': Timestamp.now(),
        });
        return FixedExpense(
          id: ref.id,
          title: title.trim(),
          category: category.trim().isEmpty ? 'General' : category.trim(),
          amount: formatPaisa(amountPaisa),
          payerId: payerId,
          splitMemberIds: [...splitIds]..sort(),
        );
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
        final ref = _sub(groupId, 'fixedExpenses').doc(id);
        final snap = await ref.get();
        final data = snap.data();
        if (data == null) {
          throw const CloudDataException('Fixed expense not found.');
        }
        final updates = <String, Object?>{};
        if (title != null) updates['title'] = title.trim();
        if (category != null) updates['category'] = category.trim();
        if (amount != null) {
          final paisa = parsePaisa(amount);
          if (paisa == null || paisa <= 0) {
            throw const CloudDataException(
                'Amount must be a positive amount.');
          }
          updates['amountPaisa'] = paisa;
        }
        if (payerId != null) updates['payerUid'] = _keyFor(payerId);
        if (splitMemberIds != null) {
          updates['splitMemberUids'] =
              splitMemberIds.map(_keyFor).toList();
        }
        if (updates.isNotEmpty) {
          updates['updatedAt'] = Timestamp.now();
          await ref.update(updates);
        }
        final fresh = await ref.get();
        return fixedExpenseFromData(id, fresh.data() ?? {}, _memberFor);
      });

  @override
  Future<void> deleteFixedExpense({
    required String groupId,
    required String id,
  }) =>
      _guard(() async {
        await _sub(groupId, 'fixedExpenses').doc(id).delete();
      });

  @override
  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense({
    required String groupId,
    required String id,
    required String actorUid,
  }) =>
      _guard(() async {
        final fixedRef = _sub(groupId, 'fixedExpenses').doc(id);
        final monthKey = _monthKey();
        final date = _todayString();
        final expenseRef = _sub(groupId, 'expenses').doc();
        // Read the template first (its values are needed to build the
        // expense); the transaction then guards the once-per-month
        // stamp and posts the expense atomically with it.
        final preSnap = await fixedRef.get();
        final preData = preSnap.data();
        if (preData == null) {
          throw const CloudDataException('Fixed expense not found.');
        }
        final fixed = fixedExpenseFromData(id, preData, _memberFor);
        final amountPaisa = parsePaisa(fixed.amount) ?? 0;
        final shares = validatedShares(
          amountPaisa: amountPaisa,
          splitType: 'equal',
          splitMembers: fixed.splitMemberIds,
          knownMembers: fixed.splitMemberIds,
        );
        // One transaction: the month stamp and the expense post
        // together, so a template can never post twice in a month.
        final applied = await _store.runTransaction<bool>((tx) async {
          final snap = await tx.get(fixedRef);
          final data = snap.data();
          if (data == null) {
            throw const CloudDataException('Fixed expense not found.');
          }
          if (data['lastAppliedMonth'] == monthKey) return false;
          tx.set(
            expenseRef,
            expenseDocData(
              title: fixed.title,
              category: fixed.category,
              amountPaisa: amountPaisa,
              date: date,
              paidByKey: _keyFor(fixed.payerId),
              splitType: 'equal',
              splits: {
                for (final s in shares) _keyFor(s.memberId): s.amountPaisa,
              },
              createdByUid: actorUid,
              fixedExpenseId: id,
            ),
          );
          tx.update(fixedRef, {'lastAppliedMonth': monthKey});
          return true;
        });
        if (!applied) return (applied: false, expense: null);
        // Re-read the posted expense so the returned record is the
        // real one, not a reconstruction.
        final snap = await _sub(groupId, 'expenses').doc(expenseRef.id).get();
        final data = snap.data();
        if (data == null) return (applied: true, expense: null);
        return (
          applied: true,
          expense: expenseRecordFromData(expenseRef.id, data, _memberFor),
        );
      });

  @override
  Future<int> loadDemoBenchmark({
    required String groupId,
    required String actorUid,
    required String actorName,
  }) =>
      _guard(() async {
        // Idempotency: the deterministic benchmark expense ids.
        // If the first one exists, the benchmark is already loaded.
        final existing = await _sub(groupId, 'expenses')
            .doc(benchmarkExpenses.first.id)
            .get();
        if (existing.exists) return 0;
        final date = _todayString();
        final batch = _store.batch();
        for (final spec in benchmarkExpenses) {
          final shares = spec.splitType == 'custom'
              ? <String, int>{
                  for (final e in spec.customSplits!.entries)
                    _keyFor(e.key): e.value,
                }
              : <String, int>{
                  for (final s in equalSplit(
                      spec.amountPaisa, spec.splitMemberIds))
                    _keyFor(s.memberId): s.amountPaisa,
                };
          batch.set(
            _sub(groupId, 'expenses').doc(spec.id),
            expenseDocData(
              title: spec.title,
              category: spec.category,
              amountPaisa: spec.amountPaisa,
              date: date,
              paidByKey: _keyFor(spec.payerId),
              splitType: spec.splitType,
              splits: shares,
              createdByUid: actorUid,
              isDemoData: true,
            ),
          );
        }
        for (final spec in benchmarkFixed) {
          batch.set(
            _sub(groupId, 'fixedExpenses').doc(spec.id),
            {
              'title': spec.title,
              'category': spec.category,
              'amountPaisa': spec.amountPaisa,
              'payerUid': _keyFor(spec.payerId),
              'splitMemberUids':
                  householdMembers.map((m) => _keyFor(m.id)).toList(),
              'createdBy': actorUid,
              'createdAt': Timestamp.now(),
            },
          );
        }
        for (final spec in benchmarkShopping) {
          batch.set(
            _sub(groupId, 'shopping').doc(spec.id),
            {
              'title': spec.title,
              'unit': spec.unit,
              'requestedQty': spec.qty,
              'status': 'Pending',
              'createdBy': actorUid,
              'createdAt': Timestamp.now(),
            },
          );
        }
        await batch.commit();
        return benchmarkExpenses.length;
      });

  // ---- Invitations + shared households (Phase 4) ----

  /// The actor's own role in a group, read from the group doc's
  /// `members` map (the rules' source of truth). Throws when the
  /// group does not exist or the actor is not a member — the caller
  /// turns that into the plain "only owner/admin" message.
  Future<String> _roleInGroup(String groupId, String uid) async {
    final snap = await _groupDoc(groupId).get();
    final data = snap.data();
    if (data == null) {
      throw const CloudDataException('Group not found.');
    }
    final members = data['members'] as Map<String, dynamic>? ?? {};
    final entry = members[uid] as Map<String, dynamic>?;
    final role = entry?['role'] as String?;
    if (role == null) {
      throw const CloudDataException(
          'Only the household owner or an admin can do that.');
    }
    return role;
  }

  CollectionReference<Map<String, dynamic>> get _invitations =>
      _store.collection('invitations');

  /// Marks stored-`pending`, past-expiry invitations as `expired`.
  /// Admin path only (the rules let an owner/admin write that
  /// transition); every write is best-effort so a sweep can never
  /// fail the listing that triggered it.
  Future<void> _sweepExpired(List<Invitation> invites) async {
    for (final inv in invites) {
      if (!inv.isExpired) continue;
      try {
        await _invitations.doc(inv.id).update({'status': 'expired'});
      } catch (e) {
        debugPrint('SplitNest: invitation expiry sweep skipped ($e)');
      }
    }
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
          throw const CloudDataException(
              'Enter a valid email address, like name@example.com.');
        }
        if (actorEmail != null &&
            email == normalizeInviteEmail(actorEmail)) {
          throw const CloudDataException(
              'You cannot invite yourself — that email is already in '
              'this household.');
        }
        if (role != 'member' && role != 'admin') {
          throw const CloudDataException(
              'Role must be member or admin.');
        }
        final actorRole = await _roleInGroup(groupId, actorUid);
        if (actorRole != 'owner' && actorRole != 'admin') {
          throw const CloudDataException(
              'Only the household owner or an admin can invite.');
        }
        if (role == 'admin' && actorRole != 'owner') {
          throw const CloudDataException(
              'Only the household owner can grant the admin role.');
        }
        // No duplicate ACTIVE invitation for the same email + group.
        // Query on groupId + status (a composite index that already
        // exists); the email filter is client-side so no new index
        // is needed. Past-expiry duplicates are swept, not blocking.
        final dupSnap = await _invitations
            .where('groupId', isEqualTo: groupId)
            .where('status', isEqualTo: 'pending')
            .get();
        final dupes = dupSnap.docs
            .map((d) => invitationFromData(d.id, d.data()))
            .where((i) => i.invitedEmail == email)
            .toList();
        for (final dupe in dupes) {
          if (dupe.isExpired) continue;
          throw CloudDataException(
              'An invitation is already pending for $email in this '
              'household.');
        }
        await _sweepExpired(dupes);
        // The code is the document id: a secure-random 12-character
        // code, retried on the (negligible) chance of a collision.
        var code = '';
        var ref = _invitations.doc();
        for (var attempt = 0; attempt < 5; attempt++) {
          code = generateInviteCode();
          ref = _invitations.doc(code);
          if (!(await ref.get()).exists) break;
          if (attempt == 4) {
            throw const CloudDataException(
                'Could not create the invitation. Please try again.');
          }
        }
        final now = DateTime.now();
        await ref.set({
          'groupId': groupId,
          'groupName': groupName,
          'invitedEmail': email,
          'invitedBy': actorUid,
          'inviterName': actorName,
          'role': role,
          'status': 'pending',
          'createdAt': Timestamp.fromDate(now),
          'expiresAt':
              Timestamp.fromDate(invitationExpiryFrom(now)),
        });
        return Invitation(
          id: code,
          groupId: groupId,
          groupName: groupName,
          invitedEmail: email,
          invitedBy: actorUid,
          inviterName: actorName,
          role: role,
          status: 'pending',
          createdAt: now,
          expiresAt: invitationExpiryFrom(now),
        );
      });

  @override
  Future<List<Invitation>> getGroupInvitations(String groupId) =>
      _guard(() async {
        final snap = await _invitations
            .where('groupId', isEqualTo: groupId)
            .get();
        final invites = snap.docs
            .map((d) => invitationFromData(d.id, d.data()))
            .toList();
        invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        // Admin-side sweep: past-expiry pending invites are stored
        // as expired (the rules allow an owner/admin that write).
        await _sweepExpired(invites);
        return invites
            .map((i) => i.isExpired ? i.copyWith(status: 'expired') : i)
            .toList();
      });

  @override
  Future<List<Invitation>> getMyInvitations(String email) =>
      _guard(() async {
        final clean = normalizeInviteEmail(email);
        final snap = await _invitations
            .where('invitedEmail', isEqualTo: clean)
            .get();
        final invites = snap.docs
            .map((d) => invitationFromData(d.id, d.data()))
            .toList();
        invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        // No sweep here: the invitee cannot write the expiry
        // transition (rules), so expiry stays derived via
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
        final role = await _roleInGroup(groupId, actorUid);
        if (role != 'owner' && role != 'admin') {
          throw const CloudDataException(
              'Only the household owner or an admin can revoke an '
              'invitation.');
        }
        final ref = _invitations.doc(invitationId);
        final snap = await ref.get();
        final data = snap.data();
        if (data == null) {
          throw const CloudDataException('Invitation not found.');
        }
        if (data['status'] != 'pending') {
          throw const CloudDataException(
              'This invitation is no longer pending.');
        }
        await ref.update({'status': 'revoked'});
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
          throw const CloudDataException(
              'Sign in with an email address to accept an invitation.');
        }
        final code = normalizeInviteCode(invitationId);
        if (code.isEmpty) {
          throw const CloudDataException(
              'Enter an invite code to join a household.');
        }
        final invRef = _invitations.doc(code);
        // One transaction: verify the invite, add the user to the
        // group's members map AND the members mirror, and mark the
        // invite accepted — or nothing changes. This is the whole
        // accept flow, client-side: it does NOT depend on the
        // undeployed onInvitationAccepted Cloud Function (see
        // functions/index.js — that Function is only a redundant
        // notification path once deployed, and it re-checks the same
        // accepted transition).
        //
        // The group doc is deliberately NOT read inside the
        // transaction: the invitee is not a group member yet, so the
        // rules deny them a group read. The blind update below is
        // authorised by the rules' self-join branch (a pending,
        // unexpired invitation for this group + email, adding only
        // their own UID as `member`), and it fails outright when the
        // group does not exist — which is the existence check.
        final accepted = await _store.runTransaction<Invitation>(
          (tx) async {
            final snap = await tx.get(invRef);
            final data = snap.data();
            if (data == null) {
              throw const CloudDataException('Invitation not found.');
            }
            final inv = invitationFromData(code, data);
            if (inv.status == 'accepted') {
              throw const CloudDataException(
                  'This invitation has already been accepted.');
            }
            if (inv.status != 'pending') {
              throw const CloudDataException(
                  'This invitation is no longer pending.');
            }
            if (inv.isExpired) {
              throw const CloudDataException(
                  'This invitation has expired. Ask for a new one.');
            }
            if (inv.invitedEmail != cleanEmail) {
              throw const CloudDataException(
                  'This invitation was sent to a different email '
                  'address. Sign in with that email to accept it.');
            }
            final grantedRole =
                inv.role == 'admin' ? 'admin' : 'member';
            final groupRef = _groupDoc(inv.groupId);
            tx.update(groupRef, {
              'members.$actorUid': {
                'role': grantedRole,
                'joinedAt': Timestamp.now(),
              },
              'joinInvitationId': code,
            });
            tx.set(
              groupRef.collection('members').doc(actorUid),
              {
                'displayName': displayName,
                'role': grantedRole,
                'joinedAt': Timestamp.now(),
                'invitationId': code,
                'uid': actorUid,
              },
            );
            tx.update(invRef, {
              'status': 'accepted',
              'acceptedBy': actorUid,
              'acceptedAt': Timestamp.now(),
            });
            return inv.copyWith(
              status: 'accepted',
              acceptedBy: actorUid,
            );
          },
        );
        // Best-effort, outside the transaction: the activity log
        // (rules deny client activity writes until Functions deploy,
        // so logActivity swallows the denial) and the user's group
        // link (so listUserGroups also finds the group from the
        // profile, not only from the invitation).
        await logActivity(
          groupId: accepted.groupId,
          entry: ActivityEntry(
            type: 'member_joined',
            title: '$displayName joined the group',
            amount: '0.00',
            memberId: actorUid,
            detail: accepted.groupName,
            timestamp: DateTime.now(),
          ),
          actorUid: actorUid,
        );
        try {
          await _store.collection('users').doc(actorUid).set(
            {
              'groupIds': FieldValue.arrayUnion([accepted.groupId]),
              'updatedAt': Timestamp.now(),
            },
            SetOptions(merge: true),
          );
        } catch (e) {
          debugPrint('SplitNest: user group link skipped ($e)');
        }
        return accepted;
      });

  @override
  Future<List<GroupSummary>> listUserGroups({
    required String uid,
    required String? email,
  }) =>
      _guard(() async {
        // Candidate groups: the user's own household group, every
        // group in their profile's groupIds list, and every group
        // they joined by accepting an invitation. No members-map
        // query is used: a user cannot query groups they do not
        // belong to (rules), and the invitation trail already names
        // every joined group.
        final candidateIds = <String>{'household-$uid'};
        try {
          final userSnap =
              await _store.collection('users').doc(uid).get();
          final groupIds = userSnap.data()?['groupIds'] as List?;
          if (groupIds != null) {
            candidateIds.addAll(groupIds.whereType<String>());
          }
        } catch (e) {
          debugPrint('SplitNest: user groupIds skipped ($e)');
        }
        if (email != null && email.isNotEmpty) {
          final acceptedSnap = await _invitations
              .where('invitedEmail',
                  isEqualTo: normalizeInviteEmail(email))
              .where('status', isEqualTo: 'accepted')
              .get();
          for (final d in acceptedSnap.docs) {
            final gid = d.data()['groupId'] as String?;
            if (gid != null && gid.isNotEmpty) candidateIds.add(gid);
          }
        }
        final groups = <GroupSummary>[];
        for (final gid in candidateIds) {
          try {
            final snap = await _groupDoc(gid).get();
            final data = snap.data();
            if (data == null) continue;
            final members = data['members'] as Map<String, dynamic>? ?? {};
            final entry = members[uid] as Map<String, dynamic>?;
            groups.add(GroupSummary(
              groupId: gid,
              name: data['name'] as String? ?? 'SplitNest Household',
              budgetPaisa: (data['budgetPaisa'] as num?)?.toInt() ??
                  defaultBudgetPaisa,
              role: entry?['role'] as String?,
            ));
          } catch (e) {
            // Not a member (any more), or the group is gone: skip
            // it silently — a missing group is never faked.
            debugPrint('SplitNest: group $gid skipped ($e)');
          }
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
        final snap = await _groupDoc(groupId).get();
        final data = snap.data();
        if (data == null) return null;
        final members = data['members'] as Map<String, dynamic>? ?? {};
        final entry = members[uid] as Map<String, dynamic>?;
        return entry?['role'] as String?;
      });

  @override
  Future<void> logActivity({
    required String groupId,
    required ActivityEntry entry,
    required String actorUid,
  }) async {
    // Best-effort only: the security rules make activity
    // Functions-written, so a client write is denied until the
    // Functions deploy. That denial must never fail the mutation
    // the entry describes — log it and continue. The app's session
    // activity log is the Timeline source of truth in this phase.
    try {
      await _sub(groupId, 'activity').add({
        'type': entry.type,
        'actorUid': actorUid,
        'summary': entry.title,
        'title': entry.title,
        'amount': entry.amount,
        'memberId': entry.memberId,
        'detail': entry.detail,
        'createdAt': Timestamp.now(),
      });
    } catch (e) {
      debugPrint('SplitNest: cloud activity log skipped ($e)');
    }
  }
}
