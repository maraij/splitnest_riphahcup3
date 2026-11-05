/// Greedy largest-debtor → largest-creditor settlement plan, computed
/// from LIVE net balances (integer paisa). The plan zeroes every
/// balance; it is computed here, never hardcoded.
///
/// Example (benchmark balances +250 / -450 / +200):
///   Ayesha pays Ali PKR 250.00, Ayesha pays Bilal PKR 200.00.
List<({String senderId, String recipientId, int amountPaisa})>
    computeSettlePlan(List<({String memberId, int netPaisa})> nets) {
  final debts = <({String id, int amount})>[];
  final credits = <({String id, int amount})>[];
  for (final n in nets) {
    if (n.netPaisa < 0) {
      debts.add((id: n.memberId, amount: -n.netPaisa));
    } else if (n.netPaisa > 0) {
      credits.add((id: n.memberId, amount: n.netPaisa));
    }
  }
  debts.sort((a, b) => b.amount.compareTo(a.amount));
  credits.sort((a, b) => b.amount.compareTo(a.amount));
  final plan = <({String senderId, String recipientId, int amountPaisa})>[];
  var di = 0;
  var ci = 0;
  while (di < debts.length && ci < credits.length) {
    final pay = debts[di].amount < credits[ci].amount
        ? debts[di].amount
        : credits[ci].amount;
    plan.add((
      senderId: debts[di].id,
      recipientId: credits[ci].id,
      amountPaisa: pay,
    ));
    debts[di] = (id: debts[di].id, amount: debts[di].amount - pay);
    credits[ci] = (id: credits[ci].id, amount: credits[ci].amount - pay);
    if (debts[di].amount == 0) di++;
    if (credits[ci].amount == 0) ci++;
  }
  return plan;
}

