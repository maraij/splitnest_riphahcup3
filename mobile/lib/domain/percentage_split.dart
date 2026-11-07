/// Percentage-based splits — pure functions, no widgets, no Firestore.
///
/// A percentage is stored as **hundredths of a percent** (an int):
/// 40% = 4000, 33.33% = 3333. Integers keep the "percentages sum to
/// 100" check exact (no double drift) and the share maths in integer
/// paisa, like every other split in the app.
///
/// Share rule (same remainder rule as equal splits): each member's
/// base share is `floor(amountPaisa * percent / 10000)`; the leftover
/// paisa (fewer than the member count, since each floor loses < 1
/// paisa) are handed out 1-by-1 in ascending member-ID order, so
/// `sum(shares) == amountPaisa` exactly.
library;

/// Parses a user-typed percent ("40", "33.33") into hundredths of a
/// percent, or null when it is not a number with at most 2 decimals
/// in the range 0–100.
int? parsePercentHundredths(String value) {
  final m = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(value.trim());
  if (m == null) return null;
  final whole = int.parse(m.group(1)!);
  final frac = (m.group(2) ?? '').padRight(2, '0');
  final hundredths = whole * 100 + int.parse(frac);
  if (hundredths < 0 || hundredths > 10000) return null;
  return hundredths;
}

/// Formats hundredths of a percent back for display ("40", "33.33").
String formatPercentHundredths(int hundredths) {
  final whole = hundredths ~/ 100;
  final frac = hundredths % 100;
  if (frac == 0) return '$whole';
  return '$whole.${frac.toString().padLeft(2, '0')}';
}

/// Percentage shares for [amountPaisa], in ascending member-ID order.
/// Callers must validate with [percentageSplitError] first: this
/// assumes the percents sum to 10000 and every member is listed once.
List<({String memberId, int amountPaisa})> percentageSplit(
  int amountPaisa,
  List<({String memberId, int percentHundredths})> shares,
) {
  final sorted = [...shares]..sort((a, b) => a.memberId.compareTo(b.memberId));
  final base = sorted
      .map((s) => (
            memberId: s.memberId,
            amountPaisa: amountPaisa * s.percentHundredths ~/ 10000,
          ))
      .toList();
  var remainder = amountPaisa -
      base.fold(0, (sum, s) => sum + s.amountPaisa);
  // Remainder is < member count (each floor loses < 1 paisa), so
  // 1-by-1 in member-ID order always closes it exactly.
  final out = <({String memberId, int amountPaisa})>[];
  for (var i = 0; i < base.length; i++) {
    var share = base[i].amountPaisa;
    if (remainder > 0) {
      share += 1;
      remainder -= 1;
    }
    out.add((memberId: base[i].memberId, amountPaisa: share));
  }
  return out;
}

/// Validates a percentage split. Returns a plain error message, or
/// null when the split may be saved. Checks: a positive amount, at
/// least one member, known members listed once, every percent in
/// 0–100, and the percents summing to exactly 100.
String? percentageSplitError({
  required int? amountPaisa,
  required List<({String memberId, int percentHundredths})> shares,
  required List<String> knownMembers,
}) {
  if (amountPaisa == null || amountPaisa <= 0) {
    return 'Enter a positive amount first.';
  }
  if (shares.isEmpty) {
    return 'Percentage split needs at least one member.';
  }
  final ids = shares.map((s) => s.memberId).toList();
  if (ids.toSet().length != ids.length ||
      ids.any((m) => !knownMembers.contains(m))) {
    return 'Split members must be known members, listed once.';
  }
  if (shares.any((s) =>
      s.percentHundredths < 0 || s.percentHundredths > 10000)) {
    return 'Each percentage must be between 0 and 100.';
  }
  final total = shares.fold(0, (sum, s) => sum + s.percentHundredths);
  if (total != 10000) {
    return 'Percentages add up to ${formatPercentHundredths(total)}% — '
        'they must add up to 100%.';
  }
  return null;
}
