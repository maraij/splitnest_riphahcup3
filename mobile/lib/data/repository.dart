import '../core/money.dart';
import '../domain/balances.dart';
import '../domain/models.dart';

/// The one plain message the app shows whenever the cloud data
/// source is unreachable, the Firestore database does not exist yet,
/// or the device is offline. Repositories must surface failures as a
/// [CloudDataException] carrying a plain message — never raw SDK
/// text, and never fake data.
const String cloudUnavailableMessage =
    'Cloud data unavailable — check setup/connection.';

/// Thrown by a [SplitNestRepository] when the cloud data source
/// cannot serve a call (offline, Firestore database missing, rules
/// rejection, or any other failure). [message] is safe to show on
/// screen verbatim.
class CloudDataException implements Exception {
  const CloudDataException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A household group, as the repository resolved it for one user.
class GroupInfo {
  const GroupInfo({required this.groupId, required this.budgetPaisa});
  final String groupId;

  /// Monthly household budget, integer paisa (PKR 5,000 = 500000).
  final int budgetPaisa;
}

/// Household constants (carried over from the old backend seed).
/// The monthly budget every new group starts with.
const int defaultBudgetPaisa = 500000;

/// The three household members, in canonical order. Every new group
/// is seeded with this roster (see [SplitNestRepository.ensureGroup]).
const List<({String id, String name})> householdMembers = [
  (id: 'M01', name: 'Ali'),
  (id: 'M02', name: 'Ayesha'),
  (id: 'M03', name: 'Bilal'),
];

/// SplitNestRepository — the ONLY place that talks to the cloud data
/// source. The single store ([AppState]) talks to this repository,
/// never to Firestore (or HTTP) directly.
///
/// The production implementation is [FirestoreSplitNestRepository]
/// (Cloud Firestore); tests substitute an in-memory fake implementing
/// this same interface. All money is integer paisa inside the data
/// layer; amounts cross this interface as two-decimal strings
/// ('780.00'), exactly as the screens already pass them.
///
/// Identity: [actorUid] is the signed-in Firebase UID (or the local
/// demo/Google identity when Firebase is not wired in). It is stored
/// as `createdBy` / `recordedBy` on the documents the security rules
/// check — the repository never invents an actor.
abstract class SplitNestRepository {
  /// Resolves the household group for one signed-in user, creating
  /// it (with the 3-member roster and the PKR 5,000 budget) when it
  /// does not exist yet. The group id is deterministic per user
  /// (`household-<uid>`) until the invite flow (a later phase) can
  /// move users between groups — see docs/FIRESTORE_STRUCTURE.md.
  /// Never seeds benchmark expenses: those load only through
  /// [loadDemoBenchmark], on an explicit demo-user action.
  Future<GroupInfo> ensureGroup({
    required String uid,
    required String displayName,
    required String? email,
    required String legacyMemberId,
    required bool isDemo,
  });

  Future<List<Member>> getMembers(String groupId);

  Future<List<ShoppingItem>> getShopping(String groupId);

  /// All expenses in the group, newest first.
  Future<List<ExpenseRecord>> getExpenses(String groupId);

  /// All payments in the group, newest first.
  Future<List<PaymentRecord>> getPayments(String groupId);

  Future<List<FixedExpense>> getFixedExpenses(String groupId);

  /// Persisted activity entries (newest last, as stored). May be
  /// empty when the cloud activity log has no entries yet — the app
  /// keeps its own session log as well, so Timeline never goes blank
  /// because of this.
  Future<List<ActivityEntry>> getActivity(String groupId);

  Future<ShoppingItem> addShopping({
    required String groupId,
    required String title,
    required String unit,
    required int qty,
    required String actorUid,
  });

  /// Atomic checkout: the selected items become Bought and exactly
  /// one equal-split expense is posted, or nothing changes. The
  /// expense title is `Shopping: <item1>, <item2>` and the category
  /// is always `Groceries`, as the old backend did.
  Future<ExpenseRecord> checkout({
    required String groupId,
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
    required String actorUid,
  });

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
  });

  /// Records a settlement as `recorded`. Validated against the live
  /// ledger (see [settlementError]): self-payments, non-debtors,
  /// non-creditors and over-settlements are rejected and nothing is
  /// written.
  Future<PaymentRecord> recordPayment({
    required String groupId,
    required String senderId,
    required String recipientId,
    required String amount,
    required String actorUid,
  });

  /// Flips a `recorded` payment to `verified`, stamping who verified
  /// it. Only an owner/admin may do this (enforced by the security
  /// rules on the real database); a verified payment can never be
  /// un-verified.
  Future<PaymentRecord> verifyPayment({
    required String groupId,
    required String paymentId,
    required String actorUid,
  });

  Future<FixedExpense> createFixedExpense({
    required String groupId,
    required String title,
    required String category,
    required String amount,
    required String payerId,
    List<String>? splitMemberIds,
    required String actorUid,
  });

  Future<FixedExpense> updateFixedExpense({
    required String groupId,
    required String id,
    String? title,
    String? category,
    String? amount,
    String? payerId,
    List<String>? splitMemberIds,
  });

  Future<void> deleteFixedExpense({
    required String groupId,
    required String id,
  });

  /// Applies one fixed template for the current month: posts at most
  /// one equal-split expense per month. Returns whether an expense
  /// was actually posted (false = already applied this month).
  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense({
    required String groupId,
    required String id,
    required String actorUid,
  });

  /// Loads the clearly-labelled DEMO benchmark into the group: the
  /// four benchmark expenses (Milk+Rice 780, Cleaning 900, Internet
  /// 1500, Electricity 1020), the two fixed templates (Internet,
  /// Electricity) and the two pending shopping items (Milk, Rice).
  /// Idempotent: calling it again loads nothing new. Returns how
  /// many benchmark expenses were seeded by this call (0 when the
  /// benchmark is already loaded). Demo-only — callers must gate it
  /// to demo users/groups; it is never called automatically.
  Future<int> loadDemoBenchmark({
    required String groupId,
    required String actorUid,
    required String actorName,
  });

  // ---- Invitations + shared households (Phase 4) ----
  // See docs/INVITATIONS.md. The invitation document id IS the
  // invite code (12 secure-random characters); expiry is 7 days
  // from creation; a stored-`pending` invitation past its expiry
  // counts as expired everywhere (derived status, accept guard,
  // admin-side sweep).

  /// Sends an invitation to join [groupId]. Only a group owner or
  /// admin may invite (enforced here and by the security rules);
  /// granting the `admin` role additionally requires the actor to be
  /// the group owner. Rejects an invalid or own email, an unknown
  /// role, and a second ACTIVE (pending, unexpired) invitation for
  /// the same email + group. Returns the created invitation — its
  /// [Invitation.id] is the shareable code.
  Future<Invitation> createInvitation({
    required String groupId,
    required String groupName,
    required String invitedEmail,
    required String role,
    required String actorUid,
    required String? actorEmail,
    required String actorName,
  });

  /// All invitations for one group, newest first. Expired pending
  /// invitations are swept to stored status `expired` by this call
  /// (admin path — the rules only let an owner/admin write that).
  /// Callers must be owner/admin; a plain member listing them is
  /// denied by the rules.
  Future<List<Invitation>> getGroupInvitations(String groupId);

  /// All invitations addressed to one email (any status), newest
  /// first. Expiry is derived client-side here — the invitee cannot
  /// write the sweep, so a past-expiry pending invite is returned
  /// with stored status `pending` and `isExpired == true`.
  Future<List<Invitation>> getMyInvitations(String email);

  /// Revokes a pending invitation. Only a group owner/admin may do
  /// this. A non-pending invitation cannot be revoked.
  Future<void> revokeInvitation({
    required String groupId,
    required String invitationId,
    required String actorUid,
  });

  /// Accepts an invitation, atomically: verifies status pending +
  /// not expired + [email] matches the invited email, then adds the
  /// user to the group's members map AND the members subcollection
  /// mirror AND marks the invitation accepted (with `acceptedBy`).
  /// This runs entirely client-side in a Firestore transaction — it
  /// does NOT depend on the (undeployed) `onInvitationAccepted`
  /// Cloud Function; that Function is only a redundant notification
  /// path once deployed. The activity entry is best-effort (the
  /// rules make activity Functions-written until they deploy).
  /// Returns the accepted invitation.
  Future<Invitation> acceptInvitation({
    required String invitationId,
    required String actorUid,
    required String email,
    required String displayName,
  });

  /// Every group [uid] belongs to: their own `household-<uid>`
  /// group plus every group joined by accepting an invitation.
  /// The user's own group comes first. A group that no longer
  /// exists (or the user no longer belongs to) is skipped, never
  /// faked.
  Future<List<GroupSummary>> listUserGroups({
    required String uid,
    required String? email,
  });

  /// The user's own role (`owner` | `admin` | `member`) in one
  /// group, or null when they are not a member of it.
  Future<String?> getMyRole({
    required String groupId,
    required String uid,
  });

  /// Persists one activity entry to the cloud log. Best-effort on
  /// the real database: the security rules make activity
  /// Functions-written only, so a client write is denied until the
  /// Functions deploy — the implementation must swallow that
  /// denial (and log it) rather than failing the mutation it
  /// describes. The app's session activity log is the Timeline
  /// source of truth in this phase.
  Future<void> logActivity({
    required String groupId,
    required ActivityEntry entry,
    required String actorUid,
  });
}

/// A repository that can never serve data: used when Firebase never
/// initialised, so the app shows the honest cloud-unavailable state
/// instead of crashing or inventing data. Every method throws the
/// same [CloudDataException].
class UnavailableSplitNestRepository implements SplitNestRepository {
  const UnavailableSplitNestRepository();

  Never _unavailable() =>
      throw const CloudDataException(cloudUnavailableMessage);

  @override
  Future<GroupInfo> ensureGroup({
    required String uid,
    required String displayName,
    required String? email,
    required String legacyMemberId,
    required bool isDemo,
  }) =>
      _unavailable();

  @override
  Future<List<Member>> getMembers(String groupId) => _unavailable();

  @override
  Future<List<ShoppingItem>> getShopping(String groupId) => _unavailable();

  @override
  Future<List<ExpenseRecord>> getExpenses(String groupId) => _unavailable();

  @override
  Future<List<PaymentRecord>> getPayments(String groupId) => _unavailable();

  @override
  Future<List<FixedExpense>> getFixedExpenses(String groupId) =>
      _unavailable();

  @override
  Future<List<ActivityEntry>> getActivity(String groupId) => _unavailable();

  @override
  Future<ShoppingItem> addShopping({
    required String groupId,
    required String title,
    required String unit,
    required int qty,
    required String actorUid,
  }) =>
      _unavailable();

  @override
  Future<ExpenseRecord> checkout({
    required String groupId,
    required List<String> itemIds,
    required String totalPaid,
    required String payerId,
    required List<String> splitMembers,
    required String actorUid,
  }) =>
      _unavailable();

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
  }) =>
      _unavailable();

  @override
  Future<PaymentRecord> recordPayment({
    required String groupId,
    required String senderId,
    required String recipientId,
    required String amount,
    required String actorUid,
  }) =>
      _unavailable();

  @override
  Future<PaymentRecord> verifyPayment({
    required String groupId,
    required String paymentId,
    required String actorUid,
  }) =>
      _unavailable();

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
      _unavailable();

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
      _unavailable();

  @override
  Future<void> deleteFixedExpense({
    required String groupId,
    required String id,
  }) =>
      _unavailable();

  @override
  Future<({bool applied, ExpenseRecord? expense})> applyFixedExpense({
    required String groupId,
    required String id,
    required String actorUid,
  }) =>
      _unavailable();

  @override
  Future<int> loadDemoBenchmark({
    required String groupId,
    required String actorUid,
    required String actorName,
  }) =>
      _unavailable();

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
      _unavailable();

  @override
  Future<List<Invitation>> getGroupInvitations(String groupId) =>
      _unavailable();

  @override
  Future<List<Invitation>> getMyInvitations(String email) => _unavailable();

  @override
  Future<void> revokeInvitation({
    required String groupId,
    required String invitationId,
    required String actorUid,
  }) =>
      _unavailable();

  @override
  Future<Invitation> acceptInvitation({
    required String invitationId,
    required String actorUid,
    required String email,
    required String displayName,
  }) =>
      _unavailable();

  @override
  Future<List<GroupSummary>> listUserGroups({
    required String uid,
    required String? email,
  }) =>
      _unavailable();

  @override
  Future<String?> getMyRole({
    required String groupId,
    required String uid,
  }) =>
      _unavailable();

  @override
  Future<void> logActivity({
    required String groupId,
    required ActivityEntry entry,
    required String actorUid,
  }) =>
      _unavailable();
}

// ---------------------------------------------------------------------------
// Shared input validation (used by every implementation, so the fake
// and the Firestore repository reject exactly the same bad input).
// These throw [CloudDataException] with the same plain messages the
// old backend returned — the app shows them verbatim.
// ---------------------------------------------------------------------------

/// The shopping units the add-item form offers.
const List<String> shoppingUnits = ['pack', 'dozen', 'bottle', 'bag'];

/// Validates an expense's shares and returns them as
/// (memberId, paisa) pairs. `equal` derives them from [splitMembers]
/// (default: all [knownMembers]); `custom` takes them from [splits]
/// and requires the sum to equal [amountPaisa] exactly.
List<({String memberId, int amountPaisa})> validatedShares({
  required int amountPaisa,
  required String splitType,
  List<Map<String, String>>? splits,
  List<String>? splitMembers,
  required List<String> knownMembers,
}) {
  bool known(String id) => knownMembers.contains(id);
  if (splitType == 'custom') {
    if (splits == null || splits.isEmpty) {
      throw const CloudDataException(
          'Custom split needs at least one share.');
    }
    final ids = splits.map((s) => s['member_id']!).toList();
    if (ids.toSet().length != ids.length || ids.any((m) => !known(m))) {
      throw const CloudDataException(
          'Split members must be known members, listed once.');
    }
    var sum = 0;
    final out = <({String memberId, int amountPaisa})>[];
    for (final s in splits) {
      final p = parsePaisa(s['amount']!);
      if (p == null || p < 0) {
        throw const CloudDataException(
            'Each share must be a non-negative amount.');
      }
      sum += p;
      out.add((memberId: s['member_id']!, amountPaisa: p));
    }
    if (sum != amountPaisa) {
      throw CloudDataException(
          'Custom shares sum to ${formatPaisa(sum)} but the amount is '
          '${formatPaisa(amountPaisa)}.');
    }
    return out;
  }
  if (splitType != 'equal') {
    throw const CloudDataException('split_type must be "equal" or "custom".');
  }
  final members = (splitMembers != null && splitMembers.isNotEmpty)
      ? splitMembers
      : knownMembers;
  if (members.toSet().length != members.length ||
      members.any((m) => !known(m))) {
    throw const CloudDataException(
        'Split members must be known members, listed once.');
  }
  // Remainder paisa 1-by-1 in ascending member-ID order (M01, M02,
  // M03) — the preserved rule from the old backend, applied here in
  // member-ID order before the Firestore keys are derived.
  return equalSplit(amountPaisa, members);
}

/// Validates a checkout before anything is written: at least one
/// item, no duplicates, a positive total, a known payer, known split
/// members, and every item existing and still Pending.
void validateCheckout({
  required List<String> itemIds,
  required int totalPaisa,
  required String payerId,
  required List<String> splitMembers,
  required List<ShoppingItem> items,
  required List<String> knownMembers,
}) {
  if (itemIds.isEmpty) {
    throw const CloudDataException('Select at least one item to check out.');
  }
  if (itemIds.toSet().length != itemIds.length) {
    throw const CloudDataException('An item was selected more than once.');
  }
  if (totalPaisa <= 0) {
    throw const CloudDataException('Total paid must be a positive amount.');
  }
  if (!knownMembers.contains(payerId)) {
    throw CloudDataException('Payer $payerId does not exist.');
  }
  if (splitMembers.toSet().length != splitMembers.length ||
      splitMembers.any((m) => !knownMembers.contains(m))) {
    throw const CloudDataException(
        'Split members must be known members, listed once.');
  }
  for (final id in itemIds) {
    final item = items.where((i) => i.id == id).firstOrNull;
    if (item == null) {
      throw const CloudDataException(
          'One of the selected items does not exist.');
    }
    if (!item.isPending) {
      throw const CloudDataException(
          'One of the selected items is already bought.');
    }
  }
}
