/// Expense edit/delete authorisation — pure rules, no widgets, no
/// storage. The same rule is enforced in two places: this helper
/// (UI gating) and the repository implementations (check before
/// writing). The local repository enforces it on every write —
/// there are no server-side rules any more, so this check plus the
/// repository check IS the enforcement. See the Phase 5 report.
///
/// A member may edit/delete an expense they recorded (they are its
/// creator, or its payer — the payer is the creator in every flow
/// the app offers, but both are checked so a payer recorded by
/// someone else is still covered). Owner/admin may edit/delete any
/// expense. Anyone else may not.
library;

/// True when [actorUid] (or [actorMemberId]) may edit or delete an
/// expense: owner/admin, its creator, or its payer.
bool canEditExpense({
  required bool isAdmin,
  required String actorUid,
  required String? actorMemberId,
  required String? createdByUid,
  required String payerMemberId,
}) {
  if (isAdmin) return true;
  if (createdByUid != null &&
      createdByUid.isNotEmpty &&
      createdByUid == actorUid) {
    return true;
  }
  if (actorMemberId != null && actorMemberId == payerMemberId) return true;
  return false;
}

/// True when the signed-in user's role may verify or reject a
/// recorded payment: owner or admin only. Plain members may record
/// payments but never verify/reject them.
bool canVerifyPayment(String? role) => role == 'owner' || role == 'admin';
