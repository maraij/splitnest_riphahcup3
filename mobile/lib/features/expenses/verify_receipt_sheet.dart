/// Verify-before-save sheet (Phase 5) — the single confirmation
/// step for every scanned expense, OCR receipt or QR code.
///
/// Nothing is ever saved straight from a scan: the extracted fields
/// (title, amount, date, category) are shown editable, with a plain
/// note about where they came from. When OCR could not run (web, or
/// a device failure) the sheet says so and the fields start empty
/// for manual entry — never auto-filled from nothing.
library;

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../core/theme.dart';

/// The confirmed values, or null when the user cancelled.
typedef VerifiedExpenseFields = ({
  String title,
  String amount,
  String category,
  String date,
});

Future<VerifiedExpenseFields?> showExpenseVerifySheet({
  required BuildContext context,
  required String sourceLabel,
  String? ocrText,
  bool ocrAvailable = true,
  String? initialTitle,
  String? initialAmount,
  String? initialCategory,
  DateTime? initialDate,
}) {
  return showModalBottomSheet<VerifiedExpenseFields>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.9,
      child: _VerifySheet(
        sourceLabel: sourceLabel,
        ocrText: ocrText,
        ocrAvailable: ocrAvailable,
        initialTitle: initialTitle,
        initialAmount: initialAmount,
        initialCategory: initialCategory,
        initialDate: initialDate,
      ),
    ),
  );
}

class _VerifySheet extends StatefulWidget {
  const _VerifySheet({
    required this.sourceLabel,
    required this.ocrText,
    required this.ocrAvailable,
    required this.initialTitle,
    required this.initialAmount,
    required this.initialCategory,
    required this.initialDate,
  });
  final String sourceLabel;
  final String? ocrText;
  final bool ocrAvailable;
  final String? initialTitle;
  final String? initialAmount;
  final String? initialCategory;
  final DateTime? initialDate;

  @override
  State<_VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends State<_VerifySheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.initialTitle ?? '');
  late final TextEditingController _amount =
      TextEditingController(text: widget.initialAmount ?? '');
  late String _category =
      categories.contains(widget.initialCategory) ? widget.initialCategory! : 'General';
  late DateTime _date = widget.initialDate ?? DateTime.now();
  String? _titleError;
  String? _amountError;

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _confirm() {
    final paisa = parsePaisa(_amount.text.trim());
    setState(() {
      _titleError =
          _title.text.trim().isEmpty ? 'Enter an expense title.' : null;
      _amountError = paisa == null || paisa <= 0
          ? 'Enter a positive amount, e.g. 1500.00.'
          : null;
    });
    if (_titleError != null || _amountError != null) return;
    Navigator.of(context).pop((
      title: _title.text.trim(),
      amount: formatPaisa(paisa!),
      category: _category,
      date:
          '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Check before saving',
                style: SplitNestTheme.titleStyle),
            const SizedBox(height: 8),
            Text(
              widget.sourceLabel,
              style: SplitNestTheme.supportingStyle,
            ),
            if (!widget.ocrAvailable) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius:
                      BorderRadius.circular(SplitNestTheme.cardRadius),
                ),
                child: const Text(
                  'Text recognition is not available on this device '
                  'or browser, so nothing was read from the photo. '
                  'Enter the details below — the photo can still be '
                  'attached to the expense.',
                  style: SplitNestTheme.supportingStyle,
                ),
              ),
            ] else if (widget.ocrText != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius:
                      BorderRadius.circular(SplitNestTheme.cardRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Text read from the receipt:',
                        style: SplitNestTheme.bodyStyle),
                    const SizedBox(height: 4),
                    Text(
                      widget.ocrText!.length > 500
                          ? '${widget.ocrText!.substring(0, 500)}…'
                          : widget.ocrText!,
                      style: SplitNestTheme.supportingStyle,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Title',
                errorText: _titleError,
                prefixIcon: const Icon(Icons.receipt_long_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount (PKR)',
                errorText: _amountError,
                prefixIcon: const Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Category', style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: categories
                  .map((c) => ChoiceChip(
                        label: Text(c),
                        selected: _category == c,
                        onSelected: (_) => setState(() => _category = c),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => _date = picked);
                    },
                    icon: const Icon(Icons.calendar_today),
                    label: Text(formatDate(_date)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _confirm,
                icon: const Icon(Icons.check),
                label: const Text('Looks right — use these details'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            Text(
              'Nothing is saved yet — confirming only fills the '
              'expense form, where you can still change the split '
              'before adding it.',
              style: SplitNestTheme.supportingStyle.copyWith(
                color: colors.warning,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
