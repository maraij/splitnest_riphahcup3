import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../domain/insights.dart';
import '../../domain/models.dart';
import '../../domain/percentage_split.dart';
import '../../domain/qr_payload.dart';
import '../../core/format.dart';
import '../../core/money.dart';
import '../../state/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/member_avatar.dart';
import '../../core/widgets/money_text.dart';
import 'qr_scan_screen.dart';
import 'verify_receipt_sheet.dart';

/// Expenses tab: the group's recorded expense history (loaded from
/// Firestore — it persists across reloads) + an Add New Expense
/// bottom sheet.
///
/// Search + filters and the Quick-add favourites below are purely
/// local UI state; the list itself always comes from AppState.
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final _query = TextEditingController();
  String _category = 'All';
  String _payer = 'All';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<ExpenseRecord> _filtered(AppState state) {
    final q = _query.text.trim().toLowerCase();
    return state.recentExpenses.where((e) {
      if (q.isNotEmpty && !e.title.toLowerCase().contains(q)) return false;
      if (_category != 'All' && e.category != _category) return false;
      if (_payer != 'All' && e.payerId != _payer) return false;
      return true;
    }).toList();
  }

  /// One-tap re-add of a favourite: posts a REAL expense to Firestore
  /// (same title, amount, payer and split as its last occurrence,
  /// dated today) and refreshes the single store.
  Future<void> _quickAdd(AppState state, FavouriteExpense fav) async {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final ok = await state.addExpense(
      title: fav.title,
      category: fav.category,
      date: date,
      amount: fav.amount,
      payerId: fav.payerId,
      splitType: fav.splitType,
      splits: fav.splitType == 'custom' ? fav.splitsPayload : null,
      splitMembers: fav.splitType == 'equal'
          ? (fav.splitMemberIds.isNotEmpty
              ? fav.splitMemberIds
              : state.members.map((m) => m.id).toList())
          : null,
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${fav.title} — PKR ${fav.amount}.')),
      );
    }
  }

  /// Deletes [expense] after an explicit confirmation. Only the
  /// payer/creator or an owner/admin ever sees the button (gated
  /// below); the repository enforces it again.
  Future<void> _deleteExpense(AppState state, ExpenseRecord e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${e.title}?'),
        content: Text(
          'This removes the PKR ${e.amount} expense and its split. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await state.deleteExpense(e);
    if (done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${e.title}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final history = state.recentExpenses;
    final favourites = quickAddFavourites(history);
    final filtered = _filtered(state);
    final categoriesInUse = categories
        .where((c) => history.any((e) => e.category == c))
        .toList();
    final payersInUse = state.members
        .where((m) => history.any((e) => e.payerId == m.id))
        .toList();
    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView(
        padding: const EdgeInsets.all(SplitNestTheme.screenPadding),
        children: [
          if (state.errorMessage != null) ...[
            ErrorBanner(
              message: state.errorMessage!,
              onDismiss: state.clearError,
              onRetry: state.refresh,
            ),
            const SizedBox(height: 16),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Recent expenses',
                  style: SplitNestTheme.sectionStyle),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: state.isBusy
                      ? null
                      : () => _openAddExpense(context, state),
                  icon: const Icon(Icons.add),
                  label: const Text('Add New Expense'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (favourites.isNotEmpty) ...[
            const Text('Quick add', style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: favourites
                  .map((fav) => OutlinedButton.icon(
                        onPressed: state.isBusy
                            ? null
                            : () => _quickAdd(state, fav),
                        icon: const Icon(Icons.replay_rounded, size: 18),
                        label: Text(
                            '${fav.title} — PKR ${fav.amount}'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
          ],
          // Fixed monthly expenses (templates, persisted in Firestore).
          // The seeded Internet + Electricity templates are
          // equal splits; the benchmark's custom-split Internet
          // expense is separate and untouched by this section.
          const Text('Fixed monthly expenses',
              style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          _FixedMonthlySection(state: state),
          const SizedBox(height: 16),
          if (history.isNotEmpty) ...[
            TextField(
              controller: _query,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Search expenses by title',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear search',
                        onPressed: () => setState(_query.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('All categories'),
                  selected: _category == 'All',
                  onSelected: (_) => setState(() => _category = 'All'),
                ),
                ...categoriesInUse.map((c) => ChoiceChip(
                      label: Text(c),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                    )),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('All members'),
                  selected: _payer == 'All',
                  onSelected: (_) => setState(() => _payer = 'All'),
                ),
                ...payersInUse.map((m) => ChoiceChip(
                      avatar: MemberAvatar(
                          memberId: m.id, name: m.name, radius: 13),
                      label: Text(m.name),
                      selected: _payer == m.id,
                      onSelected: (_) => setState(() => _payer = m.id),
                    )),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (state.isLoading && history.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (history.isEmpty)
            Entrance(
              child: const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      EmptyStateIllustration(
                          kind: EmptyArtKind.receipt),
                      SizedBox(height: 8),
                      Text('No expenses recorded yet',
                          style: SplitNestTheme.sectionStyle,
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            )
          else if (filtered.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.search_off_outlined, size: 40),
                    SizedBox(height: 8),
                    Text('No expenses match your filters',
                        style: SplitNestTheme.sectionStyle,
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ...filtered.map((e) => Card(
                child: ListTile(
                  leading: MemberAvatar(
                    memberId: e.payerId,
                    name: memberName(state.members, e.payerId),
                  ),
                  title: Text(e.isDemo ? '${e.title} · DEMO' : e.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.category} · ${e.date ?? ''} · Paid by ${memberName(state.members, e.payerId)}',
                      ),
                      if (e.shares.isNotEmpty)
                        Text(
                          '${switch (e.splitType) { 'custom' => 'Custom', 'percentage' => 'Percentage', _ => 'Equal' }} split: ${e.shares.map((s) => '${memberName(state.members, s.memberId)} ${s.amount}').join(' · ')}',
                          style: SplitNestTheme.supportingStyle,
                        ),
                      if (e.receiptUrl != null)
                        const Text(
                          'Receipt attached',
                          style: SplitNestTheme.supportingStyle,
                        ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MoneyText(e.amount,
                          style: SplitNestTheme.bodyStyle
                              .copyWith(fontWeight: FontWeight.w700)),
                      // Edit/delete only for the payer/creator or an
                      // owner/admin (AppState.mayEditExpense); the
                      // repository + rules enforce it again.
                      if (state.mayEditExpense(e)) ...[
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: 'Edit expense',
                          onPressed: state.isBusy
                              ? null
                              : () => _openAddExpense(context, state,
                                  existing: e),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: 'Delete expense',
                          onPressed: state.isBusy
                              ? null
                              : () => _deleteExpense(state, e),
                        ),
                      ],
                    ],
                  ),
                  isThreeLine: e.shares.isNotEmpty,
                ),
              )),
          const SizedBox(height: 16),
          // Per-member view: every member's paid total, share total
          // and expense list, from the shared recorded history.
          // No member's expenses are hidden from the others.
          const Text('Expenses by member',
              style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          ...memberExpenseSummaries(history, state.members)
              .map((summary) => _MemberExpensesCard(summary: summary)),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// One member's slice of the shared ledger: paid total, share total
/// and the expenses they paid. Empty members show an honest empty
/// line, never invented rows.
class _MemberExpensesCard extends StatelessWidget {
  const _MemberExpensesCard({required this.summary});
  final MemberExpenseSummary summary;

  @override
  Widget build(BuildContext context) {
    final m = summary.member;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MemberAvatar(memberId: m.id, name: m.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    m.name,
                    style: SplitNestTheme.sectionStyle,
                  ),
                ),
                Text(
                  'Paid PKR ${summary.totalPaid.toStringAsFixed(2)} · Share PKR ${summary.totalShare.toStringAsFixed(2)}',
                  style: SplitNestTheme.bodyStyle
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (summary.expenses.isEmpty)
              const Text(
                'No expenses recorded yet',
                style: SplitNestTheme.supportingStyle,
              )
            else
              ...summary.expenses.map((e) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${e.title} · ${e.date ?? ''}',
                            style: SplitNestTheme.bodyStyle,
                          ),
                        ),
                        MoneyText(e.amount,
                            style: SplitNestTheme.bodyStyle
                                .copyWith(fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

/// Fixed monthly expenses: the persisted templates, their monthly
/// total and the logged-in member's share, plus Apply (posts each
/// template at most once per month), edit-amount and delete.
class _FixedMonthlySection extends StatelessWidget {
  const _FixedMonthlySection({required this.state});
  final AppState state;

  /// This member's equal share of one template (exact, remainder
  /// paisa in member-ID order — the preserved split rule).
  String _myShare(FixedExpense f) {
    final paisa = parsePaisa(f.amount) ?? 0;
    final shares = equalSplit(paisa, f.splitMemberIds);
    final mine = shares
        .where((s) => s.memberId == state.activeMemberId)
        .firstOrNull;
    return formatPaisa(mine?.amountPaisa ?? 0);
  }

  double _monthlyTotal() => state.fixedExpenses.fold(
      0.0, (sum, f) => sum + (double.tryParse(f.amount) ?? 0));

  double _myMonthlyShare() => state.fixedExpenses.fold(0.0, (sum, f) {
        final paisa = parsePaisa(f.amount) ?? 0;
        final shares = equalSplit(paisa, f.splitMemberIds);
        final mine = shares
            .where((s) => s.memberId == state.activeMemberId)
            .firstOrNull;
        return sum + (mine?.amountPaisa ?? 0) / 100;
      });

  Future<void> _apply(BuildContext context) async {
    final n = await state.applyFixedForMonth();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n > 0
          ? 'Applied $n fixed expense(s) for this month.'
          : 'Already applied for this month.'),
    ));
  }

  Future<void> _editAmount(BuildContext context, FixedExpense f) async {
    final paisa = await showDialog<int>(
      context: context,
      builder: (ctx) =>
          _FixedAmountDialog(title: f.title, currentAmount: f.amount),
    );
    if (paisa != null) {
      await state.updateFixedExpense(id: f.id, amount: formatPaisa(paisa));
    }
  }

  Future<void> _delete(BuildContext context, FixedExpense f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${f.title}?'),
        content: const Text(
            'This stops it repeating monthly. Past expenses stay.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteFixedExpense(f.id);
  }

  @override
  Widget build(BuildContext context) {
    final fixed = state.fixedExpenses;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Monthly total PKR ${_monthlyTotal().toStringAsFixed(2)} · Your share PKR ${_myMonthlyShare().toStringAsFixed(2)}',
                    style: SplitNestTheme.bodyStyle
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (fixed.isEmpty)
              const Text(
                'No fixed monthly expenses',
                style: SplitNestTheme.supportingStyle,
              )
            else
              ...fixed.map((f) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Icon(
                          categoryIcons[f.category] ??
                              Icons.receipt_long,
                          size: 20,
                          color:
                              Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${f.title} — PKR ${f.amount} / month',
                                style: SplitNestTheme.bodyStyle.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                              Text(
                                '${f.category} · Paid by ${memberName(state.members, f.payerId)} · Your share PKR ${_myShare(f)}',
                                style: SplitNestTheme.supportingStyle,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: 'Edit amount',
                          onPressed: state.isBusy
                              ? null
                              : () => _editAmount(context, f),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete fixed expense',
                          onPressed: state.isBusy
                              ? null
                              : () => _delete(context, f),
                        ),
                      ],
                    ),
                  )),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: state.isBusy || fixed.isEmpty
                    ? null
                    : () => _apply(context),
                icon: const Icon(Icons.event_repeat),
                label: const Text('Apply fixed for this month'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openAddExpense(
  BuildContext context,
  AppState state, {
  ExpenseRecord? existing,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Bound the sheet to 90% of the screen: an unbounded sheet
    // grows taller than a short screen and its scroll view can
    // then never scroll the submit button into view.
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.9,
      child: _AddExpenseSheet(state: state, existing: existing),
    ),
  );
  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          existing == null ? 'Expense added.' : 'Expense updated.'),
    ));
  }
}

/// Add New Expense bottom sheet.
///
/// Split strategies — the UI labels ARE the Firestore split types,
/// no translation layer:
/// - Equal: pick the members who share, split evenly among the chosen
///   (remainder paisa in member-ID order).
/// - Custom: enter an exact PKR amount per member; shares must sum
///   exactly to the total.
class _AddExpenseSheet extends StatefulWidget {
  const _AddExpenseSheet({required this.state, this.existing});
  final AppState state;

  /// When set, the sheet edits this expense instead of adding one.
  final ExpenseRecord? existing;

  @override
  State<_AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends State<_AddExpenseSheet> {
  final _title = TextEditingController();
  final _amount = TextEditingController();
  final _receipt = TextEditingController();
  String _category = 'Groceries';
  String _payerId = 'M01';
  String _splitType = 'equal';
  bool _repeatMonthly = false;
  DateTime _date = DateTime.now();
  final Map<String, TextEditingController> _exact = {};
  final Map<String, TextEditingController> _percent = {};
  final Set<String> _splitMembers = {};

  /// Receipt photo picked via scan/upload, attached on save.
  XFile? _receiptImage;
  String? _receiptNote;

  /// Percentage seed values (hundredths of a percent): from the
  /// existing percentage split when editing one, otherwise an equal
  /// split of 100%. Adjusted so they sum to exactly 10000.
  late final Map<String, int> _percentSeed = _seedPercents();
  String? _titleError;
  String? _amountError;
  String? _formError;
  String? _receiptError;

  AppState get state => widget.state;

  Map<String, int> _seedPercents() {
    final ids = state.members.map((m) => m.id).toList()..sort();
    final ex = widget.existing;
    if (ex != null && ex.splitType == 'percentage') {
      final amountPaisa = parsePaisa(ex.amount) ?? 0;
      final map = <String, int>{};
      var sum = 0;
      for (final id in ids) {
        final share =
            ex.shares.where((s) => s.memberId == id).firstOrNull;
        final pct = (share == null || amountPaisa <= 0)
            ? 0
            : (parsePaisa(share.amount)! * 10000 ~/ amountPaisa);
        map[id] = pct;
        sum += pct;
      }
      if (ids.isNotEmpty) map[ids.first] = map[ids.first]! + (10000 - sum);
      return map;
    }
    final base = ids.isEmpty ? 0 : 10000 ~/ ids.length;
    final rem = ids.isEmpty ? 0 : 10000 - base * ids.length;
    return {
      for (var i = 0; i < ids.length; i++) ids[i]: base + (i < rem ? 1 : 0),
    };
  }

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      // Edit mode: prefill everything from the stored expense.
      _title.text = ex.title;
      _amount.text = ex.amount;
      _category = ex.category;
      _payerId = ex.payerId;
      _splitType = ex.splitType ?? 'equal';
      _date = DateTime.tryParse(ex.date ?? '') ?? _date;
      _splitMembers.addAll(ex.shares.map((s) => s.memberId));
      for (final s in ex.shares) {
        _exact[s.memberId] = TextEditingController(text: s.amount);
      }
    } else {
      // Payer defaults to the logged-in member, so every screen agrees
      // on who is acting — never a hardcoded member.
      _payerId = state.activeMemberId;
      _splitMembers.addAll(state.members.map((m) => m.id));
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _receipt.dispose();
    for (final c in _exact.values) {
      c.dispose();
    }
    for (final c in _percent.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Paste-receipt parser (REGEX only, see parseReceipt): fills title,
  /// amount and date from the pasted text. On failure the form stays
  /// EMPTY and a clear message is shown — never invents data.
  void _parseReceipt() {
    final parsed = parseReceipt(_receipt.text);
    setState(() {
      if (parsed == null) {
        _receiptError = 'Could not read a price/item from this receipt';
      } else {
        _receiptError = null;
        _title.text = parsed.title;
        _amount.text = parsed.amount.toStringAsFixed(2);
        if (parsed.date != null) _date = parsed.date!;
        _titleError = null;
        _amountError = null;
      }
    });
  }

  TextEditingController _exactCtrl(String id) =>
      _exact.putIfAbsent(id, () => TextEditingController(text: '0.00'));

  TextEditingController _percentCtrl(String id) => _percent.putIfAbsent(
        id,
        () => TextEditingController(
            text: formatPercentHundredths(_percentSeed[id] ?? 0)),
      );

  int _exactSum() {
    var sum = 0;
    for (final c in _exact.values) {
      sum += parsePaisa(c.text.trim()) ?? 0;
    }
    return sum;
  }

  /// Fills the form from verified scan fields (OCR receipt or QR
  /// code) and remembers the receipt photo for upload on save.
  void _applyVerified(
    VerifiedExpenseFields confirmed, {
    XFile? receiptImage,
    String? receiptNote,
  }) {
    setState(() {
      _title.text = confirmed.title;
      _amount.text = confirmed.amount;
      _category = confirmed.category;
      _date = DateTime.tryParse(confirmed.date) ?? _date;
      _receiptImage = receiptImage ?? _receiptImage;
      _receiptNote = receiptNote;
      _titleError = null;
      _amountError = null;
    });
  }

  /// Receipt photo (camera or gallery) → on-device OCR → the
  /// verify-before-save sheet. When OCR could not run, the sheet
  /// says so and the fields start empty for manual entry.
  Future<void> _scanReceipt(ImageSource source) async {
    final capture = await state.receiptService.pickAndRecognize(source);
    if (capture == null || !mounted) return;
    final parsed = capture.ocrText == null
        ? null
        : parseReceipt(capture.ocrText!);
    final confirmed = await showExpenseVerifySheet(
      context: context,
      sourceLabel: !capture.ocrAvailable
          ? 'Photo picked — text recognition is not available here.'
          : parsed == null
              ? 'The receipt photo was read, but no title or amount '
                  'could be found in it. Check the details below.'
              : 'Read from your receipt photo — check the details '
                  'before saving.',
      ocrText: capture.ocrText,
      ocrAvailable: capture.ocrAvailable,
      initialTitle: parsed?.title,
      initialAmount: parsed?.amount.toStringAsFixed(2),
      initialCategory: _category,
      initialDate: parsed?.date,
    );
    if (confirmed == null || !mounted) return;
    _applyVerified(
      confirmed,
      receiptImage: capture.file,
      receiptNote:
          'Receipt photo attached — it uploads when you save.',
    );
  }

  /// QR code → parse → the same verify-before-save sheet as OCR.
  Future<void> _scanQr() async {
    final payload = await Navigator.of(context).push<QrExpensePayload>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (payload == null || !mounted) return;
    final confirmed = await showExpenseVerifySheet(
      context: context,
      sourceLabel:
          'Read from a SplitNest QR code — check the details before saving.',
      initialTitle: payload.title,
      initialAmount: formatPaisa(payload.amountPaisa),
      initialCategory: payload.category,
      initialDate: payload.date == null
          ? null
          : DateTime.tryParse(payload.date!),
    );
    if (confirmed == null || !mounted) return;
    _applyVerified(confirmed);
  }

  Future<void> _submit() async {
    final amountPaisa = parsePaisa(_amount.text.trim());
    setState(() {
      _titleError =
          _title.text.trim().isEmpty ? 'Enter an expense title.' : null;
      _amountError = amountPaisa == null || amountPaisa <= 0
          ? 'Enter a positive amount, e.g. 1500.00.'
          : null;
      _formError = null;
    });
    if (_titleError != null || _amountError != null) return;
    List<Map<String, String>>? splits;
    List<String>? splitMembers;
    List<Map<String, String>>? percentageSplits;
    if (_splitType == 'custom') {
      // Custom = exact per-member amounts; must sum exactly to the total.
      splits = [];
      var sum = 0;
      for (final m in state.members) {
        final p = parsePaisa(_exactCtrl(m.id).text.trim());
        if (p == null || p < 0) {
          setState(() => _formError =
              'Each custom share must be a non-negative amount.');
          return;
        }
        sum += p;
        splits.add({'member_id': m.id, 'amount': formatPaisa(p)});
      }
      if (sum != amountPaisa) {
        setState(() => _formError =
            'Custom shares sum to PKR ${formatPaisa(sum)} but the amount is PKR ${formatPaisa(amountPaisa!)}.');
        return;
      }
    } else if (_splitType == 'percentage') {
      // Percentage = per-member percents; must sum to exactly 100.
      final parsed = <({String memberId, int percentHundredths})>[];
      for (final m in state.members) {
        final pct =
            parsePercentHundredths(_percentCtrl(m.id).text.trim());
        if (pct == null) {
          setState(() => _formError =
              'Each percentage must be a number between 0 and 100.');
          return;
        }
        parsed.add((memberId: m.id, percentHundredths: pct));
      }
      final error = percentageSplitError(
        amountPaisa: amountPaisa,
        shares: parsed,
        knownMembers: state.members.map((m) => m.id).toList(),
      );
      if (error != null) {
        setState(() => _formError = error);
        return;
      }
      percentageSplits = parsed
          .map((p) => {
                'member_id': p.memberId,
                'percent': formatPercentHundredths(p.percentHundredths),
              })
          .toList();
    } else {
      // Equal = split evenly among the picked members.
      if (_splitMembers.isEmpty) {
        setState(
            () => _formError = 'Pick at least one member to share with.');
        return;
      }
      splitMembers = _splitMembers.toList()..sort();
    }
    final date =
        '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
    final existing = widget.existing;
    bool ok;
    if (existing != null) {
      ok = await state.updateExpense(
        id: existing.id,
        title: _title.text.trim(),
        category: _category,
        date: date,
        amount: formatPaisa(amountPaisa!),
        payerId: _payerId,
        splitType: _splitType,
        splits: splits,
        splitMembers: splitMembers,
        percentageSplits: percentageSplits,
      );
    } else if (_receiptImage != null) {
      ok = await state.addExpenseWithReceipt(
        title: _title.text.trim(),
        category: _category,
        date: date,
        amount: formatPaisa(amountPaisa!),
        payerId: _payerId,
        splitType: _splitType,
        splits: splits,
        splitMembers: splitMembers,
        percentageSplits: percentageSplits,
        receiptImage: _receiptImage!,
      );
    } else {
      ok = await state.addExpense(
        title: _title.text.trim(),
        category: _category,
        date: date,
        amount: formatPaisa(amountPaisa!),
        payerId: _payerId,
        splitType: _splitType,
        splits: splits,
        splitMembers: splitMembers,
        percentageSplits: percentageSplits,
        repeatMonthly: _repeatMonthly,
      );
    }
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final amountPaisa = parsePaisa(_amount.text.trim());
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
            Text(
              widget.existing == null ? 'Add New Expense' : 'Edit Expense',
              style: SplitNestTheme.titleStyle,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _receipt,
              maxLines: 4,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Paste receipt',
                hintText: 'Paste a receipt (WhatsApp / SMS)…',
                errorText: _receiptError,
                prefixIcon: const Icon(Icons.paste_outlined),
              ),
              onChanged: (_) {
                // Rebuild so the Parse button enables/disables with
                // the text, and clear a previous parse error.
                setState(() => _receiptError = null);
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed:
                    _receipt.text.trim().isEmpty ? null : _parseReceipt,
                icon: const Icon(Icons.text_snippet_outlined),
                label: const Text('Parse receipt'),
              ),
            ),
            const SizedBox(height: 8),
            // Receipt photo (OCR) + QR scan: both feed the same
            // verify-before-save sheet — nothing is saved straight
            // from a scan.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: state.isBusy
                      ? null
                      : () => _scanReceipt(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Scan receipt'),
                ),
                OutlinedButton.icon(
                  onPressed: state.isBusy
                      ? null
                      : () => _scanReceipt(ImageSource.gallery),
                  icon: const Icon(Icons.photo_outlined),
                  label: const Text('Upload receipt photo'),
                ),
                OutlinedButton.icon(
                  onPressed: state.isBusy ? null : _scanQr,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR'),
                ),
              ],
            ),
            if (_receiptNote != null) ...[
              const SizedBox(height: 8),
              Text(_receiptNote!,
                  style: SplitNestTheme.supportingStyle.copyWith(
                    color: StatusColors.of(context).success,
                  )),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Title (e.g. Internet Bill)',
                errorText: _titleError,
                prefixIcon: const Icon(Icons.receipt_long_outlined),
              ),
              onChanged: (_) {
                if (_titleError != null) setState(() => _titleError = null);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount (PKR)',
                hintText: 'e.g. 1500.00',
                errorText: _amountError,
                prefixIcon: const Icon(Icons.payments_outlined),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            const Text('Category', style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: categories
                  .map((c) => ChoiceChip(
                        avatar: Icon(categoryIcons[c], size: 18),
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
                  child: DropdownButtonFormField<String>(
                     isExpanded: true,
                    initialValue: _payerId,
                    decoration: const InputDecoration(
                      labelText: 'Payer',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    items: state.members
                        .map((m) => DropdownMenuItem(
                            value: m.id, child: Text(m.name)))
                        .toList(),
                    onChanged: (v) => setState(() => _payerId = v!),
                  ),
                ),
                const SizedBox(width: 12),
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
            const SizedBox(height: 12),
            const Text('Split Strategy', style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'equal', label: Text('Equal')),
                ButtonSegment(value: 'custom', label: Text('Custom')),
                ButtonSegment(
                    value: 'percentage', label: Text('Percentage')),
              ],
              selected: {_splitType},
              onSelectionChanged: (s) => setState(() => _splitType = s.first),
            ),
            const SizedBox(height: 12),
            if (_splitType == 'equal')
              _EqualSplit(
                amountPaisa: amountPaisa,
                members: state.members,
                selected: _splitMembers,
                onToggle: (id, selected) => setState(() {
                  if (selected) {
                    _splitMembers.add(id);
                  } else {
                    _splitMembers.remove(id);
                  }
                }),
              )
            else if (_splitType == 'percentage')
              _PercentageSplit(
                amountPaisa: amountPaisa,
                members: state.members,
                percentCtrl: _percentCtrl,
                onChanged: () => setState(() {}),
              )
            else
              _CustomAmounts(
                amountPaisa: amountPaisa,
                members: state.members,
                exactCtrl: _exactCtrl,
                exactSum: _exactSum(),
                onChanged: () => setState(() {}),
              ),
            // Repeat-monthly only when adding: editing an expense
            // must not silently create a second template.
            if (widget.existing == null)
              SwitchListTile(
                title: const Text('Repeat monthly'),
                value: _repeatMonthly,
                onChanged: (v) => setState(() => _repeatMonthly = v),
              ),
            if (_formError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_formError!,
                    style: TextStyle(color: colors.error)),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: state.isBusy ? null : _submit,
                icon: state.isBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(widget.existing == null
                        ? Icons.add
                        : Icons.save_outlined),
                label: Text(state.isBusy
                    ? 'Saving…'
                    : widget.existing == null
                        ? 'Add expense'
                        : 'Save changes'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EqualPreview extends StatelessWidget {
  const _EqualPreview({required this.amountPaisa, required this.members});
  final int? amountPaisa;
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    if (amountPaisa == null || amountPaisa! <= 0 || members.isEmpty) {
      return const SizedBox.shrink();
    }
    final shares =
        equalSplit(amountPaisa!, members.map((m) => m.id).toList());
    return _PreviewBox(
      title:
          'Equal split — PKR ${formatPaisa(amountPaisa!)} between ${members.length}',
      lines: shares
          .map((s) =>
              '${memberName(members, s.memberId)} pays PKR ${formatPaisa(s.amountPaisa)}')
          .toList(),
    );
  }
}

/// Percentage split: a percent per member; the percents must add
/// up to exactly 100. Shares are integer paisa with the same
/// remainder 1-by-1 rule as equal splits, shown live.
class _PercentageSplit extends StatelessWidget {
  const _PercentageSplit({
    required this.amountPaisa,
    required this.members,
    required this.percentCtrl,
    required this.onChanged,
  });
  final int? amountPaisa;
  final List<Member> members;
  final TextEditingController Function(String id) percentCtrl;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final amount = amountPaisa ?? 0;
    var sumHundredths = 0;
    var allValid = true;
    final parsed = <({String memberId, int percentHundredths})>[];
    for (final m in members) {
      final pct = parsePercentHundredths(percentCtrl(m.id).text.trim());
      if (pct == null) {
        allValid = false;
      } else {
        sumHundredths += pct;
        parsed.add((memberId: m.id, percentHundredths: pct));
      }
    }
    final balanced = allValid && sumHundredths == 10000;
    final statusText = amount <= 0
        ? 'Enter an amount first.'
        : !allValid
            ? 'Each percentage must be a number between 0 and 100.'
            : balanced
                ? 'Balanced — percentages add up to 100%.'
                : 'Percentages add up to ${formatPercentHundredths(sumHundredths)}% — they must add up to 100%.';
    final statusColor = balanced
        ? colors.success
        : amount <= 0
            ? colors.warning
            : colors.error;
    final preview = balanced && amount > 0
        ? percentageSplit(amount, parsed)
        : const <({String memberId, int amountPaisa})>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Percentage shares:'),
        const SizedBox(height: 8),
        ...members.map((m) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: percentCtrl(m.id),
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: InputDecoration(
                  labelText: '${m.name} share (%)',
                  suffixText: '%',
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(10),
                    child: MemberAvatar(
                        memberId: m.id, name: m.name, radius: 13),
                  ),
                ),
                onChanged: (_) => onChanged(),
              ),
            )),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Percentages total ${formatPercentHundredths(sumHundredths)}% of 100%',
                style: SplitNestTheme.bodyStyle
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    balanced
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    size: 18,
                    color: statusColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(statusText,
                        style: SplitNestTheme.supportingStyle
                            .copyWith(color: statusColor)),
                  ),
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...preview.map((s) => Text(
                      '${memberName(members, s.memberId)} pays PKR ${formatPaisa(s.amountPaisa)}',
                      style: SplitNestTheme.supportingStyle,
                    )),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CustomAmounts extends StatelessWidget {
  const _CustomAmounts({
    required this.amountPaisa,
    required this.members,
    required this.exactCtrl,
    required this.exactSum,
    required this.onChanged,
  });
  final int? amountPaisa;
  final List<Member> members;
  final TextEditingController Function(String id) exactCtrl;
  final int exactSum;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final amount = amountPaisa ?? 0;
    final remaining = amount - exactSum;
    final balanced = amount > 0 && remaining == 0;
    final statusText = amount <= 0
        ? 'Enter an amount first.'
        : balanced
            ? 'Balanced — shares match the amount exactly.'
            : remaining > 0
                ? 'PKR ${formatPaisa(remaining)} still to assign.'
                : 'Over by PKR ${formatPaisa(-remaining)} — reduce a share.';
    final statusColor = balanced
        ? colors.success
        : remaining > 0
            ? colors.warning
            : colors.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Custom shares:'),
        const SizedBox(height: 8),
        ...members.map((m) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: exactCtrl(m.id),
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: InputDecoration(
                  labelText: '${m.name} share (PKR)',
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(10),
                    child: MemberAvatar(
                        memberId: m.id, name: m.name, radius: 13),
                  ),
                ),
                onChanged: (_) => onChanged(),
              ),
            )),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Shares total PKR ${formatPaisa(exactSum)} of PKR ${formatPaisa(amount)}',
                style: SplitNestTheme.bodyStyle
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    balanced
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    size: 18,
                    color: statusColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(statusText,
                        style: SplitNestTheme.supportingStyle
                            .copyWith(color: statusColor)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Equal split: pick who shares, split evenly among the chosen.
class _EqualSplit extends StatelessWidget {
  const _EqualSplit({
    required this.amountPaisa,
    required this.members,
    required this.selected,
    required this.onToggle,
  });
  final int? amountPaisa;
  final List<Member> members;
  final Set<String> selected;
  final void Function(String id, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    final chosen =
        members.where((m) => selected.contains(m.id)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
            'Split with:'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: members.map((m) {
            final isSelected = selected.contains(m.id);
            return FilterChip(
              avatar: MemberAvatar(memberId: m.id, name: m.name, radius: 13),
              label: Text(m.name),
              selected: isSelected,
              onSelected: (v) => onToggle(m.id, v),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        if (amountPaisa == null || amountPaisa! <= 0 || chosen.isEmpty)
          const SizedBox.shrink()
        else
          _EqualPreview(
            amountPaisa: amountPaisa,
            members: chosen,
          ),
      ],
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.title, required this.lines});
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: SplitNestTheme.bodyStyle
                  .copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          ...lines.map((l) => Text(l, style: SplitNestTheme.supportingStyle)),
        ],
      ),
    );
  }
}

/// Fixed-amount edit dialog. Owns its TextEditingController and
/// disposes it in its own dispose() — disposing a controller right
/// after showDialog returns crashes, because the dialog is still
/// animating out and its TextField is rebuilt with the disposed
/// controller. Returns the new amount in paisa, or null on Cancel.
class _FixedAmountDialog extends StatefulWidget {
  const _FixedAmountDialog(
      {required this.title, required this.currentAmount});
  final String title;
  final String currentAmount;

  @override
  State<_FixedAmountDialog> createState() => _FixedAmountDialogState();
}

class _FixedAmountDialogState extends State<_FixedAmountDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentAmount);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit ${widget.title}'),
      content: TextField(
        controller: _controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Amount (PKR)'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final paisa = parsePaisa(_controller.text.trim());
            if (paisa == null || paisa <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Enter a positive amount.')));
              return;
            }
            Navigator.of(context).pop(paisa);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
