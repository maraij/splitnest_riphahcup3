// Money helpers, mirroring backend/src/money.js.
// Amounts are integer paisa internally; JSON uses two-decimal strings.

int? parsePaisa(String value) {
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d{1,2}))?$').firstMatch(value.trim());
  if (m == null) return null;
  final sign = m.group(1) == '-' ? -1 : 1;
  final whole = int.parse(m.group(2)!);
  final frac = (m.group(3) ?? '').padRight(2, '0');
  return sign * (whole * 100 + int.parse(frac));
}

String formatPaisa(int paisa) {
  final sign = paisa < 0 ? '-' : '';
  final abs = paisa.abs();
  return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

/// Equal split: base share floored, remainder paisa 1-by-1 in ascending ID.
List<({String memberId, int amountPaisa})> equalSplit(
    int totalPaisa, List<String> memberIds) {
  final ids = [...memberIds]..sort();
  final base = totalPaisa ~/ ids.length;
  final remainder = totalPaisa - base * ids.length;
  return [
    for (var i = 0; i < ids.length; i++)
      (memberId: ids[i], amountPaisa: base + (i < remainder ? 1 : 0)),
  ];
}
