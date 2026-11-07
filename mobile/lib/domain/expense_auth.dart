/// Expense edit/delete authorisation — pure rules, no widgets, no
/// Firestore. The same rule is enforced in two places: this helper
/// (UI gating) and the repository implementations (client-side check
/// before writing). NOTE: `firestore.rules` does NOT yet encode this
/// rule — it still allows expense update/delete by owner/admin
/// only, and has no recorded→rejected payment branch. On a live
/// Firebase DB a creator edit/delete or a reject would be denied
/// until the rules are updated; that rules change is pending the
/// backend-store decision (Firebase dropped 2026-11-07 in favour of
/// a local store — the local implementation will enforce this rule
/// instead). See the Phase 5 report.
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
