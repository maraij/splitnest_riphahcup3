/// QR expense payloads — pure functions, no widgets, no camera.
///
/// Format (one line, `|`-separated, no `|` allowed inside a field):
///   `SPLITNEST|<title>|<amount>|<category>[|<yyyy-MM-dd>]`
/// where `<amount>` is PKR as a decimal ("1500.00") and `<category>`
/// is one of the app categories (an unknown category is kept as
/// written and the verify screen offers the category picker, so a
/// QR from an older/other writer never silently becomes another
/// category — the user sees and confirms it first).
///
/// This is the documented format for the QR entry route; it is NOT
/// the receipt-paste format (free text parsed by `parseReceipt`).
/// A scanned code is always parsed into the same verify-before-save
/// flow as an OCR receipt — nothing is ever saved straight from a
/// scan.
library;

import '../core/money.dart';

class QrExpensePayload {
  const QrExpensePayload({
    required this.title,
    required this.amountPaisa,
    required this.category,
    this.date,
  });
  final String title;
  final int amountPaisa;
  final String category;

  /// `yyyy-MM-dd`, when the code carried one.
  final String? date;
}

/// Parses a scanned QR string into an expense payload, or null when
/// it is not a SplitNest expense code (wrong prefix, wrong field
/// count, empty title, non-positive amount, malformed date).
QrExpensePayload? parseQrPayload(String raw) {
  final text = raw.trim();
  if (!text.startsWith('SPLITNEST|')) return null;
  final parts = text.split('|');
  if (parts.length != 4 && parts.length != 5) return null;
  final title = parts[1].trim();
  if (title.isEmpty) return null;
  final amountPaisa = parsePaisa(parts[2].trim());
  if (amountPaisa == null || amountPaisa <= 0) return null;
  final category = parts[3].trim();
  if (category.isEmpty) return null;
  String? date;
  if (parts.length == 5) {
    final d = parts[4].trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) return null;
    final parsed = DateTime.tryParse(d);
    if (parsed == null) return null;
    date = d;
  }
  return QrExpensePayload(
    title: title,
    amountPaisa: amountPaisa,
    category: category,
    date: date,
  );
}

/// Builds a SplitNest QR payload string (for sharing / printing a
/// code, and for tests). Titles containing `|` are rejected — the
/// caller must strip them first — because `|` is the separator.
String? formatQrPayload({
  required String title,
  required int amountPaisa,
  required String category,
  String? date,
}) {
  final cleanTitle = title.trim();
  if (cleanTitle.isEmpty || cleanTitle.contains('|')) return null;
  if (amountPaisa <= 0) return null;
  final cleanCategory = category.trim();
  if (cleanCategory.isEmpty || cleanCategory.contains('|')) return null;
  final base =
      'SPLITNEST|$cleanTitle|${formatPaisa(amountPaisa)}|$cleanCategory';
  if (date == null || date.isEmpty) return base;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return null;
  return '$base|$date';
}
