/// Domain models — pure data, no Firestore, no Flutter.
/// Firestore mapping lives in data/firestore_repository.dart.
library;

import 'invitations.dart';

class Member {
  Member({required this.id, required this.name, this.photoUrl});
  final String id;
  final String name;

  /// Download URL of the member's profile photo (Storage), when one
  /// was uploaded; null means initials avatar.
  final String? photoUrl;
  factory Member.fromJson(Map<String, dynamic> j) => Member(
        id: j['id'] as String,
        name: j['name'] as String,
        photoUrl: j['photoUrl'] as String?,
      );
}

class ShoppingItem {
  ShoppingItem({
    required this.id,
    required this.title,
    required this.unit,
    required this.requestedQty,
    required this.status,
  });
  final String id;
  final String title;
  final String unit;
  final int requestedQty;
  final String status;
  bool get isPending => status == 'Pending';
  factory ShoppingItem.fromJson(Map<String, dynamic> j) => ShoppingItem(
        id: j['id'] as String,
        title: j['title'] as String,
        unit: j['unit'] as String,
        requestedQty: (j['requested_qty'] as num).toInt(),
        status: j['status'] as String,
      );
}

class BalanceRow {
  BalanceRow({
    required this.memberId,
    required this.name,
    required this.net,
    required this.paid,
    required this.share,
  });
  final String memberId;
  final String name;
  final String net;
  final String paid;
  final String share;
  factory BalanceRow.fromJson(Map<String, dynamic> j) => BalanceRow(
        memberId: j['member_id'] as String,
        name: j['name'] as String? ?? j['member_id'] as String,
        net: j['net'] as String,
        paid: j['paid'] as String? ?? '0.00',
        share: j['share'] as String? ?? '0.00',
      );
}

class Balances {
  Balances({
    required this.rows,
    required this.totalSpending,
    required this.budget,
    required this.remaining,
    required this.usedPercent,
    required this.status,
  });
  final List<BalanceRow> rows;
  final String totalSpending;
  final String budget;
  final String remaining;
  final double usedPercent;
  final String status;
  factory Balances.fromJson(Map<String, dynamic> j) => Balances(
        rows: (j['balances'] as List)
            .map((e) => BalanceRow.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalSpending: j['total_spending'] as String,
        budget: j['budget'] as String,
        remaining: j['remaining'] as String,
        usedPercent: (j['used_percent'] as num).toDouble(),
        status: j['status'] as String,
      );
}

/// One entry in the in-memory activity log (Timeline screen).
/// Appended on every successful checkout, expense post and
/// settlement. Session-only: it resets when the app reloads.
class ActivityEntry {
  ActivityEntry({
    required this.type,
    required this.title,
    required this.amount,
    required this.memberId,
    required this.detail,
    required this.timestamp,
  });

  /// 'checkout' | 'expense' | 'settle'.
  final String type;
  final String title;

  /// Amount, two-decimal string ('1500.00').
  final String amount;

  /// Member who did it (payer for expenses, sender for settlements).
  final String memberId;

  /// Short extra info, e.g. 'Ayesha → Ali'.
  final String detail;
  final DateTime timestamp;
}

/// A fixed monthly expense TEMPLATE (not an expense itself).
/// Seeded: Internet 1500.00 (Bilal) + Electricity 1020.00 (Ali),
/// split equally among all three members. Templates post nothing
/// on their own; Apply posts one equal-split expense per month.
class FixedExpense {
  FixedExpense({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.payerId,
    required this.splitMemberIds,
  });
  final String id;
  final String title;
  final String category;

  /// Monthly amount, two-decimal string ('1500.00').
  final String amount;
  final String payerId;

  /// Members sharing it equally.
  final List<String> splitMemberIds;

  factory FixedExpense.fromJson(Map<String, dynamic> j) => FixedExpense(
        id: j['id'] as String,
        title: j['title'] as String,
        category: j['category'] as String,
        amount: j['amount'] as String,
        payerId: j['payer_id'] as String,
        splitMemberIds: (j['split_members'] as List)
            .map((e) => e as String)
            .toList(),
      );
}

class ExpenseShare {
  ExpenseShare({required this.memberId, required this.amount});
  final String memberId;
  final String amount;
  factory ExpenseShare.fromJson(Map<String, dynamic> j) => ExpenseShare(
        memberId: j['member_id'] as String,
        amount: j['amount'] as String,
      );
}

class ExpenseRecord {
  ExpenseRecord({
    required this.id,
    required this.title,
    required this.category,
    required this.amount,
    required this.payerId,
    this.date,
    this.splitType,
    this.shares = const [],
    this.isDemo = false,
    this.createdByUid,
    this.receiptUrl,
    this.receiptPath,
  });
  final String id;
  final String title;
  final String category;
  final String amount;
  final String payerId;
  final String? date;
  final String? splitType;
  final List<ExpenseShare> shares;

  /// True when this expense is clearly-labelled DEMO benchmark data
  /// (see SplitNestRepository.loadDemoBenchmark). Demo rows are never
  /// mixed silently into a real user's history.
  final bool isDemo;

  /// Firebase UID that recorded the expense (the edit/delete
  /// authorisation key — see domain/expense_auth.dart).
  final String? createdByUid;

  /// Receipt image: Storage download URL / path, when a receipt
  /// photo was attached (see storage.rules `receipts/{gid}/{eid}/`).
  final String? receiptUrl;
  final String? receiptPath;
  factory ExpenseRecord.fromJson(Map<String, dynamic> j) => ExpenseRecord(
        id: j['id'] as String,
        title: j['title'] as String,
        category: j['category'] as String,
        amount: j['amount'] as String,
        payerId: j['payer_id'] as String,
        date: j['date'] as String?,
        splitType: j['split_type'] as String?,
        shares: (j['shares'] as List?)
                ?.map((s) => ExpenseShare.fromJson(s as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// One settlement (payment) between two members.
///
/// A payment is a **record** first and a **verified fact** second:
/// `status` starts as `recorded` (set by the sender) and moves to
/// `verified` when an owner/admin confirms it, or to `rejected`
/// when an owner/admin rejects it (a rejected payment counts
/// nowhere in any balance; the sender records a new, corrected
/// payment instead — that is the correctable path). Only `verified`
/// payments count in the settled balance (see
/// domain/payment_tracking.dart); a `recorded` payment is shown as
/// pending and never displayed as confirmed. A payment never
/// changes total spending.
class PaymentRecord {
  PaymentRecord({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.amount,
    required this.status,
    this.verifiedBy,
    this.verifiedAt,
    this.rejectedBy,
    this.rejectedAt,
    this.createdAt,
  });
  final String id;
  final String senderId;
  final String recipientId;

  /// Amount, two-decimal string ('250.00').
  final String amount;

  /// 'recorded' | 'verified' | 'rejected'.
  final String status;
  final String? verifiedBy;
  final DateTime? verifiedAt;

  /// UID of the owner/admin who rejected it (set only on reject).
  final String? rejectedBy;
  final DateTime? rejectedAt;
  final DateTime? createdAt;
}

/// One household the signed-in user belongs to, for the group
/// switcher (Phase 4). [role] is the user's own role in that group.
class GroupSummary {
  const GroupSummary({
    required this.groupId,
    required this.name,
    required this.budgetPaisa,
    this.role,
  });
  final String groupId;
  final String name;
  final int budgetPaisa;
  final String? role;
}

/// One invitation to join a household (Phase 4, top-level
/// `invitations` collection).
///
/// The document id IS the invite code (see
/// `domain/invitations.dart`): a 12-character code from an
/// unambiguous alphabet, generated with a cryptographically secure
/// random source. That makes "enter invite code" a direct document
/// read, and lets the security rules authorise a self-join by
/// reading the invitation doc by id.
class Invitation {
  const Invitation({
    required this.id,
    required this.groupId,
    required this.groupName,
    required this.invitedEmail,
    required this.invitedBy,
    this.inviterName,
    required this.role,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.acceptedBy,
    this.acceptedAt,
  });

  /// The invite code (document id).
  final String id;
  final String groupId;
  final String groupName;

  /// Lower-cased; must match the invitee's Auth email to accept.
  final String invitedEmail;

  /// UID of the owner/admin who sent the invite.
  final String invitedBy;
  final String? inviterName;

  /// Role granted on accept: `member` (default) or `admin`
  /// (owner-granted only).
  final String role;

  /// Stored status: `pending` | `accepted` | `revoked` | `expired`.
  final String status;
  final DateTime createdAt;

  /// `createdAt + 7 days`.
  final DateTime expiresAt;

  /// UID of the user who accepted (set by the accept flow).
  final String? acceptedBy;
  final DateTime? acceptedAt;

  /// A stored-`pending` invitation whose expiry has passed counts as
  /// expired everywhere — list filtering, the accept guard, and the
  /// admin-side sweep all use this, never the stored status alone.
  bool get isExpired =>
      status == 'pending' && DateTime.now().isAfter(expiresAt);

  /// The status the UI and the accept guard use: `expired` when a
  /// pending invite is past its expiry, otherwise the stored status.
  String get effectiveStatus => isExpired ? 'expired' : status;

  bool get isPending => effectiveStatus == 'pending';

  /// The code as shown to humans: `XXXX-XXXX-XXXX`.
  String get displayCode => formatInviteCode(id);

  /// The shareable link (plain text; see docs/INVITATIONS.md).
  String get link => inviteLinkFor(id);

  Invitation copyWith({String? status, String? acceptedBy}) => Invitation(
        id: id,
        groupId: groupId,
        groupName: groupName,
        invitedEmail: invitedEmail,
        invitedBy: invitedBy,
        inviterName: inviterName,
        role: role,
        status: status ?? this.status,
        createdAt: createdAt,
        expiresAt: expiresAt,
        acceptedBy: acceptedBy ?? this.acceptedBy,
        acceptedAt: acceptedAt,
      );
}
