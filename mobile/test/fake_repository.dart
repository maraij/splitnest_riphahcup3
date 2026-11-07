// Shared in-memory fake of [SplitNestRepository] for widget, auth and
// Firestore-migration tests. It implements the exact same contract as
// the Firestore repository (same validators, same messages, same
// atomicity rules) over plain Dart lists, so tests never touch a real
// database — and the production Firestore behaviour is covered
// separately in firestore_test.dart against FakeFirebaseFirestore.
//
// Factories:
// - [FakeSplitNestRepository.benchmark] (default): the household as
//   the old backend left it after the benchmark — 4 benchmark
//   expenses (4200.00, 84%, nets +250/-450/+200), 2 fixed templates,
//   2 pending shopping items. This is what most widget tests need.
// - [FakeSplitNestRepository.empty]: the group structure only
//   (3 members, PKR 5,000 budget) — no expenses, no shopping, no
//   templates. Tests that build their own history from scratch use
//   this so the benchmark cannot pollute their numbers.
// - [FakeSplitNestRepository.overBudget]: 5000.00 spent, every net
//   zero — nobody saved anything, so no celebration may appear.
library;

import 'package:splitnest/core/money.dart';
import 'package:splitnest/data/demo_benchmark.dart';
import 'package:splitnest/domain/invitations.dart';
import 'package:splitnest/data/repository.dart';
import 'package:splitnest/domain/balances.dart';
import 'package:splitnest/domain/models.dart';

class FakeSplitNestRepository implements SplitNestRepository {
  FakeSplitNestRepository.benchmark()
      : _benchmarkLoaded = true,
        _expenses = benchmarkExpenseRecords(),
        _fixed = benchmarkFixedRecords(),
        _shopping = benchmarkShoppingRecords() {
    _expenses = _expenses.reversed.toList();
  }

  FakeSplitNestRepository.empty() : _benchmarkLoaded = false;

  FakeSplitNestRepository.overBudget() : _benchmarkLoaded = false {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _expenses = [
      ExpenseRecord(
        id: 'E-over-3',
        title: 'Over 3',
        category: 'General',
        amount: '1500.00',
        payerId: 'M03',
        date: date,
        splitType: 'custom',
        shares: [ExpenseShare(memberId: 'M03', amount: '1500.00')],
      ),
      ExpenseRecord(
        id: 'E-over-2',
        title: 'Over 2',
        category: 'General',
        amount: '1500.00',
        payerId: 'M02',
        date: date,
        splitType: 'custom',
        shares: [ExpenseShare(memberId: 'M02', amount: '1500.00')],
      ),
      ExpenseRecord(
        id: 'E-over-1',
        title: 'Over 1',
        category: 'General',
        amount: '2000.00',
        payerId: 'M01',
        date: date,
        splitType: 'custom',
        shares: [ExpenseShare(memberId: 'M01', amount: '2000.00')],
      ),
    ];
  }

  static const String groupId = 'fake-group';

  final List<Member> _members = [
    Member(id: 'M01', name: 'Ali'),
    Member(id: 'M02', name: 'Ayesha'),
    Member(id: 'M03', name: 'Bilal'),
  ];

  List<ShoppingItem> _shopping = [];
  List<ExpenseRecord> _expenses = [];
  final List<PaymentRecord> _payments = [];
  List<FixedExpense> _fixed = [];
  final List<ActivityEntry> _activity = [];
  final Map<String, String> _appliedFixed = {};
  bool _benchmarkLoaded;
  int _seq = 0;

  // ---- Invitations (Phase 4) ----
  final List<Invitation> _invitations = [];
  // groupId -> uid -> role. ensureGroup makes the first caller the
  // owner; later callers of the same (fake-collapsed) group join as
  // members — the fake has one group id, so this models the shared
  // household rather than per-user groups.
  final Map<String, Map<String, String>> _roles = {};
  // uid -> group ids the user belongs to (own group + accepted).
  final Map<String, Set<String>> _userGroups = {};
  final Map<String, String> _groupNames = {};

  /// Test hook: the next checkout throws mid-call (after
  /// validation, before any mutation) to prove atomicity.
  bool failNextCheckout = false;

  // Read-only views for assertions.
  List<ExpenseRecord> get allExpenses => List.of(_expenses);
  List<PaymentRecord> get allPayments => List.of(_payments);
  List<ShoppingItem> get allShopping => List.of(_shopping);
  List<FixedExpense> get allFixed => List.of(_fixed);
  List<ActivityEntry> get allActivity => List.of(_activity);
  List<Invitation> get allInvitations => List.of(_invitations);
  bool get benchmarkLoaded => _benchmarkLoaded;

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _monthKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  List<String> get _knownIds => _members.map((m) => m.id).toList();

  Balances _balances() => computeBalances(
        expenses: _expenses,
        payments: _payments,
        members: _members,
        budgetPaisa: defaultBudgetPaisa,
      );

  @override
  Future<GroupInfo> ensureGroup({
    required String uid,
    required String displayName,
    required String? email,
    required String legacyMemberId,
    required bool isDemo,
  }) async {
    // First caller owns the group; later callers join as members
    // (the fake collapses every household to one group id).
    final roles = _roles[groupId] ??= {};
    if (!roles.values.contains('owner')) {
      roles[uid] = 'owner';
    } else {
      roles.putIfAbsent(uid, () => 'member');
    }
    (_userGroups[uid] ??= {}).add(groupId);
    _groupNames[groupId] ??= 'SplitNest Household';
    return const GroupInfo(groupId: groupId, budgetPaisa: defaultBudgetPaisa);
  }

  @override
  Future<List<Member>> getMembers(String groupId) async =>
      List.of(_members);

  @override
  Future<List<ShoppingItem>> getShopping(String groupId) async {
    final items = List.of(_shopping);
    items.sort((a, b) => a.id.compareTo(b.id));
    return items;
  }

  @override
  Future<List<ExpenseRecord>> getExpenses(String groupId) async =>
      List.of(_expenses);

  @override
  Future<List<PaymentRecord>> getPayments(String groupId) async =>
      List.of(_payments);

  @override
  Future<List<FixedExpense>> getFixedExpenses(String groupId) async =>
      List.of(_fixed);

  @override
  Future<List<ActivityEntry>> getActivity(String groupId) async =>
      List.of(_activity);

  @override
  Future<ShoppingItem> addShopping({
    required String groupId,
    required String title,
    required String unit,
    required int qty,
    required String actorUid,
  }) async {
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
    final item = ShoppingItem(
      id: 'S-fake-${++_seq}',
      title: title.trim(),
      unit: unit,
      requestedQty: qty,
      status: 'Pending',
    );
    _shopping.add(item);
    return item;
  }

  @override
  Future<ExpenseRecord> checkout({
    required String groupId,
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
    required String actorUid,
  }) async {
    final totalPaisa = parsePaisa(totalPaid);
    if (totalPaisa == null) {
      throw const CloudDataException('Total paid must be a positive amount.');
    }
    // Validate everything BEFORE mutating anything (atomicity).
    validateCheckout(
      itemIds: itemIds,
      totalPaisa: totalPaisa,
      payerId: payerId,
      splitMembers: splitMembers,
      items: _shopping,
      knownMembers: _knownIds,
    );
    final shares = validatedShares(
      amountPaisa: totalPaisa,
      splitType: 'equal',
      splitMembers: splitMembers,
      knownMembers: _knownIds,
    );
    if (failNextCheckout) {
      failNextCheckout = false;
      throw const CloudDataException(
          'Checkout failed; nothing was changed.');
    }
    final titles = itemIds
        .map((id) => _shopping.firstWhere((i) => i.id == id).title)
        .toList();
    final expense = ExpenseRecord(
      id: 'E-checkout-${++_seq}',
      title: 'Shopping: ${titles.join(', ')}',
      category: 'Groceries',
      amount: formatPaisa(totalPaisa),
      payerId: payerId,
      date: _today(),
      splitType: 'equal',
      shares: shares
          .map((s) => ExpenseShare(
                memberId: s.memberId,
                amount: formatPaisa(s.amountPaisa),
              ))
          .toList(),
    );
    _expenses.insert(0, expense);
    for (var i = 0; i < _shopping.length; i++) {
      if (itemIds.contains(_shopping[i].id)) {
        final old = _shopping[i];
        _shopping[i] = ShoppingItem(
          id: old.id,
          title: old.title,
          unit: old.unit,
          requestedQty: old.requestedQty,
          status: 'Bought',
        );
      }
    }
    return expense;
  }

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
    required String actorUid,
  }) async {
    if (title.trim().isEmpty) {
      throw const CloudDataException('Title is required.');
    }
    final amountPaisa = parsePaisa(amount);
    if (amountPaisa == null || amountPaisa <= 0) {
      throw const CloudDataException('Amount must be a positive amount.');
    }
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      throw const CloudDataException('Date must be YYYY-MM-DD.');
    }
    if (!_knownIds.contains(payerId)) {
      throw CloudDataException('Payer $payerId does not exist.');
    }
    final shares = validatedShares(
      amountPaisa: amountPaisa,
      splitType: splitType,
      splits: splits,
      splitMembers: splitMembers,
      knownMembers: _knownIds,
    );
    final expense = ExpenseRecord(
      id: 'E-fake-${++_seq}',
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
    );
    _expenses.insert(0, expense);
    return expense;
  }

  @override
  Future<PaymentRecord> recordPayment({
    required String groupId,
    required String senderId,
    required String recipientId,
    required String amount,
    required String actorUid,
  }) async {
    final amountPaisa = parsePaisa(amount);
    if (amountPaisa == null) {
      throw const CloudDataException('Settlement amount must be positive.');
    }
    final balances = _balances();
    final error = settlementError(
      nets: {
        for (final r in balances.rows) r.memberId: parsePaisa(r.net) ?? 0,
      },
      senderId: senderId,
      recipientId: recipientId,
      amountPaisa: amountPaisa,
    );
    if (error != null) throw CloudDataException(error);
    final payment = PaymentRecord(
      id: 'P-fake-${++_seq}',
      senderId: senderId,
      recipientId: recipientId,
      amount: formatPaisa(amountPaisa),
      status: 'recorded',
      createdAt: DateTime.now(),
    );
    _payments.insert(0, payment);
    return payment;
  }

  @override
  Future<PaymentRecord> verifyPayment({
    required String groupId,
    required String paymentId,
    required String actorUid,
  }) async {
    final i = _payments.indexWhere((p) => p.id == paymentId);
    if (i < 0) throw const CloudDataException('Payment not found.');
    final old = _payments[i];
    if (old.status != 'recorded') {
      throw const CloudDataException('This payment is already verified.');
    }
    final verified = PaymentRecord(
      id: old.id,
      senderId: old.senderId,
      recipientId: old.recipientId,
      amount: old.amount,
      status: 'verified',
      verifiedBy: actorUid,
      createdAt: old.createdAt,
    );
    _payments[i] = verified;
    return verified;
  }

  @override
  Future<FixedExpense> createFixedExpense({
    required String groupId,
    required String title,
    required String category,
    required String amount,
    required String payerId,
    List<String>? splitMemberIds,
    required String actorUid,
  }) async {
    if (title.trim().isEmpty) {
      throw const CloudDataException('Title is required.');
    }
    final amountPaisa = parsePaisa(amount);
    if (amountPaisa == null || amountPaisa <= 0) {
      throw const CloudDataException('Amount must be a positive amount.');
    }
    if (!_knownIds.contains(payerId)) {
      throw CloudDataException('Payer $payerId does not exist.');
    }
    final splitIds = (splitMemberIds != null && splitMemberIds.isNotEmpty)
        ? splitMemberIds
        : _knownIds;
    if (splitIds.toSet().length != splitIds.length ||
        splitIds.any((m) => !_knownIds.contains(m))) {
      throw const CloudDataException(
          'Split members must be known members, listed once.');
    }
    final fixed = FixedExpense(
      id: 'F-fake-${++_seq}',
      title: title.trim(),
      category: category.trim().isEmpty ? 'General' : category.trim(),
      amount: formatPaisa(amountPaisa),
      payerId: payerId,
      splitMemberIds: [...splitIds]..sort(),
    );
    _fixed.add(fixed);
    return fixed;
  }

  @override
  Future<FixedExpense> updateFixedExpense({
    required String groupId,
    required String id,
    String? title,
    String? category,
    String? amount,
    String? payerId,
    List<String>? splitMemberIds,
  }) async {
    final i = _fixed.indexWhere((f) => f.id == id);
    if (i < 0) throw const CloudDataException('Fixed expense not found.');
    final old = _fixed[i];
    final updated = FixedExpense(
      id: old.id,
      title: title ?? old.title,
      category: category ?? old.category,
      amount: amount ?? old.amount,
      payerId: payerId ?? old.payerId,
      splitMemberIds: splitMemberIds ?? old.splitMemberIds,
    );
    _fixed[i] = updated;
    return updated;
  }

  @override
  Future<void> deleteFixedExpense({
    required String groupId,
    required String id,
  }) async {
    _fixed.removeWhere((f) => f.id == id);
  }

  @override
  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense({
    required String groupId,
    required String id,
    required String actorUid,
  }) async {
    final key = '$id|${_monthKey()}';
    if (_appliedFixed.containsKey(key)) {
      return (applied: false, expense: null);
    }
    final fixed = _fixed.where((f) => f.id == id).firstOrNull;
    if (fixed == null) {
      throw const CloudDataException('Fixed expense not found.');
    }
    _appliedFixed[key] = _monthKey();
    final shares = validatedShares(
      amountPaisa: parsePaisa(fixed.amount) ?? 0,
      splitType: 'equal',
      splitMembers: fixed.splitMemberIds,
      knownMembers: fixed.splitMemberIds,
    );
    final expense = ExpenseRecord(
      id: 'E-fixed-${++_seq}',
      title: fixed.title,
      category: fixed.category,
      amount: fixed.amount,
      payerId: fixed.payerId,
      date: _today(),
      splitType: 'equal',
      shares: shares
          .map((s) => ExpenseShare(
                memberId: s.memberId,
                amount: formatPaisa(s.amountPaisa),
              ))
          .toList(),
    );
    _expenses.insert(0, expense);
    return (applied: true, expense: expense);
  }

  @override
  Future<int> loadDemoBenchmark({
    required String groupId,
    required String actorUid,
    required String actorName,
  }) async {
    if (_benchmarkLoaded) return 0;
    _expenses = [
      ...benchmarkExpenseRecords().reversed,
      ..._expenses,
    ];
    _fixed = [..._fixed, ...benchmarkFixedRecords()];
    _shopping = [..._shopping, ...benchmarkShoppingRecords()];
    _benchmarkLoaded = true;
    return benchmarkExpenses.length;
  }

  // ---- Invitations + shared households (Phase 4) ----
  // Same contract as FirestoreSplitNestRepository, over plain lists.

  String _roleOf(String groupId, String uid) {
    final role = _roles[groupId]?[uid];
    if (role == null) {
      throw const CloudDataException(
          'Only the household owner or an admin can do that.');
    }
    return role;
  }

  void _sweepExpiredFake() {
    for (var i = 0; i < _invitations.length; i++) {
      if (_invitations[i].isExpired) {
        _invitations[i] = _invitations[i].copyWith(status: 'expired');
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
  }) async {
    final email = normalizeInviteEmail(invitedEmail);
    if (!isValidInviteEmail(email)) {
      throw const CloudDataException(
          'Enter a valid email address, like name@example.com.');
    }
    if (actorEmail != null && email == normalizeInviteEmail(actorEmail)) {
      throw const CloudDataException(
          'You cannot invite yourself — that email is already in '
          'this household.');
    }
    if (role != 'member' && role != 'admin') {
      throw const CloudDataException('Role must be member or admin.');
    }
    final actorRole = _roleOf(groupId, actorUid);
    if (actorRole != 'owner' && actorRole != 'admin') {
      throw const CloudDataException(
          'Only the household owner or an admin can invite.');
    }
    if (role == 'admin' && actorRole != 'owner') {
      throw const CloudDataException(
          'Only the household owner can grant the admin role.');
    }
    _sweepExpiredFake();
    if (_invitations.any((i) =>
        i.groupId == groupId &&
        i.invitedEmail == email &&
        i.isPending)) {
      throw CloudDataException(
          'An invitation is already pending for $email in this '
          'household.');
    }
    var code = '';
    for (var attempt = 0; attempt < 5; attempt++) {
      code = generateInviteCode();
      if (!_invitations.any((i) => i.id == code)) break;
      if (attempt == 4) {
        throw const CloudDataException(
            'Could not create the invitation. Please try again.');
      }
    }
    final now = DateTime.now();
    final invite = Invitation(
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
    _invitations.add(invite);
    return invite;
  }

  @override
  Future<List<Invitation>> getGroupInvitations(String groupId) async {
    _sweepExpiredFake();
    final invites =
        _invitations.where((i) => i.groupId == groupId).toList();
    invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return invites;
  }

  @override
  Future<List<Invitation>> getMyInvitations(String email) async {
    final clean = normalizeInviteEmail(email);
    final invites =
        _invitations.where((i) => i.invitedEmail == clean).toList();
    invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return invites;
  }

  @override
  Future<void> revokeInvitation({
    required String groupId,
    required String invitationId,
    required String actorUid,
  }) async {
    final role = _roleOf(groupId, actorUid);
    if (role != 'owner' && role != 'admin') {
      throw const CloudDataException(
          'Only the household owner or an admin can revoke an '
          'invitation.');
    }
    final i = _invitations.indexWhere((v) => v.id == invitationId);
    if (i < 0) throw const CloudDataException('Invitation not found.');
    if (_invitations[i].status != 'pending') {
      throw const CloudDataException(
          'This invitation is no longer pending.');
    }
    _invitations[i] = _invitations[i].copyWith(status: 'revoked');
  }

  @override
  Future<Invitation> acceptInvitation({
    required String invitationId,
    required String actorUid,
    required String email,
    required String displayName,
  }) async {
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
    final i = _invitations.indexWhere((v) => v.id == code);
    if (i < 0) throw const CloudDataException('Invitation not found.');
    final inv = _invitations[i];
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
          'This invitation was sent to a different email address. '
          'Sign in with that email to accept it.');
    }
    // Atomic in the fake: every mutation below happens only after
    // every check above passed, mirroring the Firestore
    // transaction (members map + mirror + invite + activity).
    final accepted = inv.copyWith(status: 'accepted', acceptedBy: actorUid);
    _invitations[i] = accepted;
    final grantedRole = inv.role == 'admin' ? 'admin' : 'member';
    (_roles[inv.groupId] ??= {})[actorUid] = grantedRole;
    (_userGroups[actorUid] ??= {}).add(inv.groupId);
    _groupNames[inv.groupId] ??= inv.groupName;
    _activity.add(ActivityEntry(
      type: 'member_joined',
      title: '$displayName joined the group',
      amount: '0.00',
      memberId: actorUid,
      detail: inv.groupName,
      timestamp: DateTime.now(),
    ));
    return accepted;
  }

  @override
  Future<List<GroupSummary>> listUserGroups({
    required String uid,
    required String? email,
  }) async {
    final ids = <String>{...?_userGroups[uid]};
    if (email != null) {
      final clean = normalizeInviteEmail(email);
      for (final inv in _invitations) {
        if (inv.invitedEmail == clean && inv.status == 'accepted') {
          ids.add(inv.groupId);
        }
      }
    }
    if (ids.isEmpty) ids.add(groupId);
    return ids
        .map((gid) => GroupSummary(
              groupId: gid,
              name: _groupNames[gid] ?? 'SplitNest Household',
              budgetPaisa: defaultBudgetPaisa,
              role: _roles[gid]?[uid],
            ))
        .toList();
  }

  @override
  Future<String?> getMyRole({
    required String groupId,
    required String uid,
  }) async =>
      _roles[groupId]?[uid];

  @override
  Future<void> logActivity({
    required String groupId,
    required ActivityEntry entry,
    required String actorUid,
  }) async {
    _activity.add(entry);
  }
}
