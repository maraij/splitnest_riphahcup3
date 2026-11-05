import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/money.dart';
import '../../state/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/member_avatar.dart';

const List<String> units = ['pack', 'dozen', 'bottle', 'bag'];

/// Daily-basis needs beyond the quick-add favourites — tapping one
/// adds it to the Shopping list as Pending (default unit pack, qty 1).
/// NO prices: these are shopping items, priced only at checkout.
const List<String> otherDailyItems = [
  'Eggs',
  'Bread',
  'Sugar',
  'Tea',
  'Cooking Oil',
  'Vegetables',
  'Fruits',
  'Detergent',
  'Shampoo',
  'Toothpaste',
  'Tissue',
  'Gas refill',
];

/// Shopping List tab: Current List / History tabs (Current = pending
/// items, History = bought items). Item rows with checkboxes for
/// multi-select checkout, unit + quantity, status pills. Add-item form
/// on top; checkout is a bottom sheet.
class ShoppingScreen extends StatefulWidget {
  const ShoppingScreen({super.key});
  @override
  State<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends State<ShoppingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _title = TextEditingController();
  final _qty = TextEditingController(text: '1');
  String _unit = 'pack';
  String? _titleError;
  String? _qtyError;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _title.dispose();
    _qty.dispose();
    super.dispose();
  }

  void _stepQty(int delta) {
    final current = int.tryParse(_qty.text.trim()) ?? 1;
    final next = (current + delta).clamp(1, 99);
    setState(() {
      _qty.text = '$next';
      _qtyError = null;
    });
  }

  Future<void> _addItem(AppState state) async {
    final qty = int.tryParse(_qty.text.trim());
    var valid = true;
    setState(() {
      _titleError =
          _title.text.trim().isEmpty ? 'Enter an item title.' : null;
      _qtyError = qty == null || qty <= 0
          ? 'Quantity must be a positive whole number.'
          : null;
      valid = _titleError == null && _qtyError == null;
    });
    if (!valid) return;
    final ok = await state.addShoppingItem(
        title: _title.text.trim(), unit: _unit, qty: qty!);
    if (ok && mounted) {
      _title.clear();
      _qty.text = '1';
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Item added to the shopping list.')));
    }
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  /// "Others" quick-add: a scrollable list of daily-basis needs.
  /// Tapping one adds it to the Shopping list as Pending (unit pack,
  /// qty 1) with a confirmation snackbar. No prices are invented.
  Future<void> _openOthers(AppState state) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.6,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Others', style: SplitNestTheme.titleStyle),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final item in otherDailyItems)
                    ListTile(
                      leading: const Icon(Icons.shopping_basket_outlined),
                      title: Text(item),
                      trailing: const Icon(Icons.add),
                      onTap: () => Navigator.of(ctx).pop(item),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final ok =
        await state.addShoppingItem(title: picked, unit: 'pack', qty: 1);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$picked added to the shopping list.')));
    }
  }

  Future<void> _openCheckout(AppState state) async {
    final selectedItems =
        state.shopping.where((i) => _selected.contains(i.id)).toList();
    if (selectedItems.isEmpty) return;
    final totalCtrl = TextEditingController();
    String payerId = state.activeMemberId;
    final split = state.members.map((m) => m.id).toSet();
    String? error;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // Bound the sheet to 90% of the screen: an unbounded sheet
      // grows taller than a short screen and its scroll view can
      // then never scroll the submit button into view.
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.9,
        child: StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
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
                      color: Theme.of(ctx).colorScheme.outline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Checkout', style: SplitNestTheme.titleStyle),
                const SizedBox(height: 4),
                Text(
                  '${selectedItems.length} item(s)',
                  style: SplitNestTheme.supportingStyle,
                ),
                const SizedBox(height: 12),
                ...selectedItems.map((item) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.shopping_basket_outlined),
                      title: Text(
                          '${item.title} (${item.unit} × ${item.requestedQty})'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Remove ${item.title} from checkout',
                        onPressed: () {
                          setState(() => _selected.remove(item.id));
                          setSheet(() {});
                          if (_selected.isEmpty) Navigator.of(ctx).pop(false);
                        },
                      ),
                    )),
                const Divider(),
                TextField(
                  controller: totalCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Total paid (PKR)',
                    hintText: 'e.g. 780.00',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                  onChanged: (_) => setSheet(() {}),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                                  isExpanded: true,
                  initialValue: payerId,
                  decoration: const InputDecoration(
                    labelText: 'Payer',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  items: state.members
                      .map((m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.name),
                          ))
                      .toList(),
                  onChanged: (v) => setSheet(() => payerId = v!),
                ),
                const SizedBox(height: 12),
                const Text('Split between',
                    style: SplitNestTheme.sectionStyle),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: state.members.map((m) {
                    final selected = split.contains(m.id);
                    return FilterChip(
                      avatar: MemberAvatar(
                          memberId: m.id, name: m.name, radius: 13),
                      label: Text(m.name),
                      selected: selected,
                      onSelected: (v) => setSheet(() {
                        if (v) {
                          split.add(m.id);
                        } else {
                          split.remove(m.id);
                        }
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                // Live per-person preview (same equal-split rule as backend).
                _SplitPreview(
                  totalText: totalCtrl.text,
                  splitMembers: split.toList(),
                  memberName: (id) => state.members
                      .firstWhere((m) => m.id == id,
                          orElse: () => state.members.first)
                      .name,
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error)),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: state.isBusy
                        ? null
                        : () async {
                            if (split.isEmpty) {
                              setSheet(() => error =
                                  'Select at least one member to split between.');
                              return;
                            }
                            final paid = totalCtrl.text.trim();
                            if (paid.isEmpty) {
                              setSheet(
                                  () => error = 'Enter the total paid.');
                              return;
                            }
                            final done = await state.checkout(
                              itemIds: _selected.toList(),
                              totalPaid: paid,
                              payerId: payerId,
                              splitMembers: split.toList(),
                            );
                            if (done) {
                              _selected.clear();
                              if (ctx.mounted) Navigator.of(ctx).pop(true);
                            } else {
                              setSheet(() => error = state.errorMessage);
                            }
                          },
                    icon: state.isBusy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.shopping_cart_checkout),
                    label: Text(
                        state.isBusy ? 'Posting…' : 'Pay & post expense'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Checkout complete — items bought, expense posted.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final pending = state.shopping.where((i) => i.isPending).toList();
    final bought = state.shopping.where((i) => !i.isPending).toList();
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(SplitNestTheme.screenPadding),
      child: Column(
        children: [
          if (state.errorMessage != null) ...[
            ErrorBanner(
              message: state.errorMessage!,
              onDismiss: state.clearError,
              onRetry: state.refresh,
            ),
            const SizedBox(height: 12),
          ],
          Entrance(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Add item',
                            style: SplitNestTheme.sectionStyle),
                        if (_selected.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => setState(_selected.clear),
                            icon: const Icon(Icons.clear),
                            label: Text('Clear (${_selected.length})'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _title,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: 'Title (e.g. Milk)',
                        errorText: _titleError,
                        prefixIcon: const Icon(Icons.add_shopping_cart),
                      ),
                      onChanged: (_) {
                        if (_titleError != null) {
                          setState(() => _titleError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                             isExpanded: true,
                            initialValue: _unit,
                            decoration:
                                const InputDecoration(labelText: 'Unit'),
                            items: units
                                .map((u) => DropdownMenuItem(
                                    value: u, child: Text(u)))
                                .toList(),
                            onChanged: (v) => setState(() => _unit = v!),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                tooltip: 'Decrease quantity',
                                onPressed: () => _stepQty(-1),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: _qty,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  decoration: InputDecoration(
                                    labelText: 'Quantity',
                                    errorText: _qtyError,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline),
                                tooltip: 'Increase quantity',
                                onPressed: () => _stepQty(1),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Add + Others side by side: stacking two full-width
                    // 48pt buttons made the card too tall for short
                    // screens (the tab list below got ~0 height).
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: state.isBusy
                                ? null
                                : () => _addItem(state),
                            icon: state.isBusy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.add),
                            label:
                                Text(state.isBusy ? 'Adding…' : 'Add item'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: state.isBusy
                                ? null
                                : () => _openOthers(state),
                            icon: const Icon(Icons.more_horiz),
                            label: const Text('Others'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TabBar(
            controller: _tabs,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: theme.colorScheme.primary,
            tabs: [
              Tab(text: 'Current List (${pending.length})'),
              Tab(text: 'History (${bought.length})'),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                // Current List — pending items, tap to select for checkout.
                RefreshIndicator(
                  onRefresh: state.refresh,
                  child: state.isLoading && state.shopping.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : pending.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 16),
                                EmptyStateIllustration(
                                    kind: EmptyArtKind.basket, size: 72),
                                SizedBox(height: 8),
                                Text('No pending items',
                                    style: SplitNestTheme.sectionStyle,
                                    textAlign: TextAlign.center),
                              ],
                            )
                          : ListView(
                              children: [
                                ...pending.map((item) {
                                  final selected =
                                      _selected.contains(item.id);
                                  return Card(
                                    color: selected
                                        ? theme.colorScheme.primary
                                            .withValues(alpha: 0.08)
                                        : null,
                                    child: ListTile(
                                      leading: Checkbox(
                                        value: selected,
                                        onChanged: (_) =>
                                            _toggleSelect(item.id),
                                      ),
                                      title: Text(
                                          '${item.title} (${item.unit} × ${item.requestedQty})'),
                                      trailing: Chip(
                                        label: const Text('Pending'),
                                        backgroundColor: colors.warning
                                            .withValues(alpha: 0.15),
                                        labelStyle: TextStyle(
                                          color: colors.warning,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      onTap: () => _toggleSelect(item.id),
                                    ),
                                  );
                                }),
                              ],
                            ),
                ),
                // History — bought items.
                RefreshIndicator(
                  onRefresh: state.refresh,
                  child: bought.isEmpty
                      ? ListView(
                          children: const [
                            SizedBox(height: 16),
                            EmptyStateIllustration(
                                kind: EmptyArtKind.receipt, size: 72),
                            SizedBox(height: 8),
                            Text('Nothing bought yet',
                                style: SplitNestTheme.sectionStyle,
                                textAlign: TextAlign.center),
                          ],
                        )
                      : ListView(
                          children: bought
                              .map((item) => Card(
                                    child: ListTile(
                                      leading: const Icon(
                                          Icons.check_circle_outline),
                                      title: Text(
                                          '${item.title} (${item.unit} × ${item.requestedQty})'),
                                      trailing:
                                          const Chip(label: Text('Bought')),
                                    ),
                                  ))
                              .toList(),
                        ),
                ),
              ],
            ),
          ),
          if (_selected.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed:
                    state.isBusy ? null : () => _openCheckout(state),
                icon: const Icon(Icons.shopping_cart_checkout),
                label: Text('Checkout · ${_selected.length} selected'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Live equal-split preview inside the checkout sheet.
class _SplitPreview extends StatelessWidget {
  const _SplitPreview({
    required this.totalText,
    required this.splitMembers,
    required this.memberName,
  });
  final String totalText;
  final List<String> splitMembers;
  final String Function(String id) memberName;

  @override
  Widget build(BuildContext context) {
    final total = parsePaisa(totalText.trim());
    if (total == null || total <= 0) {
      return const SizedBox.shrink();
    }
    if (splitMembers.isEmpty) {
      return const Text(
        'Select at least one member to split between.',
        style: SplitNestTheme.supportingStyle,
      );
    }
    final shares = equalSplit(total, splitMembers);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(SplitNestTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Split preview — total PKR ${formatPaisa(total)} between ${splitMembers.length}',
            style: SplitNestTheme.bodyStyle
                .copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          ...shares.map((s) => Text(
                '${memberName(s.memberId)} pays PKR ${formatPaisa(s.amountPaisa)}',
                style: SplitNestTheme.supportingStyle,
              )),
        ],
      ),
    );
  }
}
