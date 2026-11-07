import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../domain/payment_tracking.dart';
import '../../domain/settle_plan.dart';
import '../../state/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/illustrations.dart';
import '../../core/widgets/member_avatar.dart';
import '../../core/widgets/money_text.dart';

/// Settle Up & Balances tab: balances table (Paid / Share / Net with
/// owed/owe label), a Smart Settle suggestion card computed from LIVE
/// balances (greedy largest-debtor → largest-creditor), and the
/// Settle Debt dialog.
class SettleScreen extends StatelessWidget {
  const SettleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final b = state.balances;
    final colors = StatusColors.of(context);
    final plan = b == null
        ? const <({String senderId, String recipientId, int amountPaisa})>[]
        : computeSettlePlan([
            for (final r in b.rows)
              (memberId: r.memberId, netPaisa: parsePaisa(r.net) ?? 0),
          ]);

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
              const Text('Balances', style: SplitNestTheme.sectionStyle),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: state.isBusy || b == null
                      ? null
                      : () => _openSettle(context, state),
                  icon: const Icon(Icons.handshake),
                  label: const Text('Settle Debt'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (b == null && state.isLoading)
            const Center(child: CircularProgressIndicator())
          else if (b != null)
            Entrance(
              child: Card(
                child: Column(
                  children: [
                    ...b.rows.map((r) {
                      final net = double.tryParse(r.net) ?? 0;
                      final color = net > 0
                          ? colors.success
                          : net < 0
                              ? colors.error
                              : null;
                      return ListTile(
                        leading: MemberAvatar(
                            memberId: r.memberId, name: r.name),
                        title: Text(r.name),
                        subtitle: Text(
                            'Paid PKR ${r.paid} · Share PKR ${r.share}'),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            MoneyText(r.net,
                                style: SplitNestTheme.bodyStyle.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: color,
                                )),
                            Text(
                              net > 0
                                  ? 'is owed'
                                  : net < 0
                                      ? 'owes'
                                      : 'settled up',
                              style: SplitNestTheme.supportingStyle,
                            ),
                          ],
                        ),
                      );
                    }),
                    const Divider(height: 1),
                    ListTile(
                      title: const Text('Total spending'),
                      trailing: MoneyText(b.totalSpending,
                          style: SplitNestTheme.bodyStyle
                              .copyWith(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text('Smart Settle', style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          Entrance(
            delay: const Duration(milliseconds: 80),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (plan.isEmpty)
                      const Column(
                        children: [
                          EmptyStateIllustration(
                              kind: EmptyArtKind.settled, size: 72),
                          SizedBox(height: 8),
                          Text(
                            'Everyone is settled up — no payments needed.',
                            style: SplitNestTheme.bodyStyle,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      )
                    else
                      ...plan.map((step) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${memberName(state.members, step.senderId)} pays ${memberName(state.members, step.recipientId)} PKR ${formatPaisa(step.amountPaisa)}',
                                    style: SplitNestTheme.bodyStyle.copyWith(
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                // Prefills the settlement form only —
                                // nothing is recorded until the form's
                                // own "Record settlement" is confirmed.
                                TextButton(
                                  onPressed: state.isBusy
                                      ? null
                                      : () => _openSettle(
                                            context,
                                            state,
                                            prefill: step,
                                          ),
                                  child: const Text('Use this'),
                                ),
                              ],
                            ),
                          )),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Per-member payment tracking (Phase 5): total owed / paid,
          // remaining settled balance and status, monthly
          // contribution, and each member's payment history. The
          // settled balance counts VERIFIED payments only; recorded
          // payments are shown as pending below and never as settled.
          const Text('Payment tracking',
              style: SplitNestTheme.sectionStyle),
          const SizedBox(height: 8),
          ...state.paymentSummaries.map(
            (s) => _MemberPaymentCard(summary: s, state: state),
          ),
          const SizedBox(height: 16),
          // Payments recorded but not yet verified. A recorded
          // payment is shown as pending — it counts in the balances
          // above only as a ledger preview, never as confirmed.
          // Verify / Reject are owner/admin only (the buttons are
          // hidden for plain members; the repository enforces it
          // again — and the rules enforce Verify; the Reject branch
          // is a pending rules change, see the report).
          if (state.pendingPayments.isNotEmpty) ...[
            const Text('Pending verification',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Entrance(
              delay: const Duration(milliseconds: 120),
              child: Card(
                child: Column(
                  children: [
                    if (!state.canVerifyPayments)
                      const ListTile(
                        leading: Icon(Icons.info_outline),
                        title: Text(
                          'Only the household owner or an admin can '
                          'verify or reject a payment.',
                        ),
                      ),
                    ...state.pendingPayments.map((p) => ListTile(
                          leading: const Icon(Icons.hourglass_top),
                          title: Text(
                            '${memberName(state.members, p.senderId)} → '
                            '${memberName(state.members, p.recipientId)}',
                          ),
                          subtitle: Text(paymentStatusLabel(p.status)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              MoneyText(p.amount,
                                  style: SplitNestTheme.bodyStyle
                                      .copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(width: 8),
                              if (state.canVerifyPayments) ...[
                                TextButton(
                                  onPressed: state.isBusy
                                      ? null
                                      : () => state.verifyPayment(p.id),
                                  child: const Text('Verify'),
                                ),
                                TextButton(
                                  onPressed: state.isBusy
                                      ? null
                                      : () => _rejectPayment(context, state, p),
                                  child: const Text('Reject'),
                                ),
                              ],
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          // Verified payments: confirmed, with who verified them.
          // Rejected payments: visible, explicitly NOT counted as
          // settled — the sender records a new payment to correct
          // one. Neither list is ever shown as the other.
          if (state.verifiedPayments.isNotEmpty) ...[
            const Text('Verified payments',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ...state.verifiedPayments.map((p) => ListTile(
                        leading: const Icon(Icons.verified_outlined),
                        title: Text(
                          '${memberName(state.members, p.senderId)} → '
                          '${memberName(state.members, p.recipientId)}',
                        ),
                        subtitle: Text(
                          p.verifiedAt == null
                              ? 'Verified'
                              : 'Verified on ${formatDate(p.verifiedAt!)}',
                        ),
                        trailing: MoneyText(p.amount,
                            style: SplitNestTheme.bodyStyle.copyWith(
                                fontWeight: FontWeight.w700,
                                color: colors.success)),
                      )),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (state.rejectedPayments.isNotEmpty) ...[
            const Text('Rejected payments',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ...state.rejectedPayments.map((p) => ListTile(
                        leading: const Icon(Icons.cancel_outlined),
                        title: Text(
                          '${memberName(state.members, p.senderId)} → '
                          '${memberName(state.members, p.recipientId)}',
                        ),
                        subtitle:
                            Text(paymentStatusLabel(p.status)),
                        trailing: MoneyText(p.amount,
                            style: SplitNestTheme.bodyStyle.copyWith(
                                fontWeight: FontWeight.w700,
                                color: colors.error)),
                      )),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

/// Confirms a rejection: a rejected payment counts nowhere, and the
/// sender's way to correct it is to record a new payment.
Future<void> _rejectPayment(
    BuildContext context, AppState state, PaymentRecord p) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Reject this payment?'),
      content: Text(
        '${memberName(state.members, p.senderId)} → '
        '${memberName(state.members, p.recipientId)} · PKR ${p.amount}\n\n'
        'A rejected payment is not counted as settled. The sender '
        'can record a new, corrected payment.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Reject'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    await state.rejectPayment(p.id);
  }
}

/// One member's payment tracking: owed / paid / remaining (verified
/// only) / status / monthly contribution / pending amount, plus
/// their payment history with honest status labels.
class _MemberPaymentCard extends StatelessWidget {
  const _MemberPaymentCard({required this.summary, required this.state});
  final MemberPaymentSummary summary;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final s = summary;
    final statusColor = s.status == 'settled'
        ? colors.success
        : s.status == 'owes'
            ? colors.error
            : colors.success;
    final statusLabel = s.status == 'settled'
        ? 'Settled'
        : s.status == 'owes'
            ? 'Owes'
            : 'Is owed';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MemberAvatar(
                    memberId: s.member.id, name: s.member.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    s.member.name,
                    style: SplitNestTheme.sectionStyle,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    statusLabel,
                    style: SplitNestTheme.bodyStyle.copyWith(
                      fontWeight: FontWeight.w700,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _PayRow(
                label: 'Total owed (share)',
                value: 'PKR ${formatPaisa(s.totalOwedPaisa)}'),
            _PayRow(
                label: 'Total paid (expenses)',
                value: 'PKR ${formatPaisa(s.totalPaidPaisa)}'),
            _PayRow(
                label: 'Remaining (verified only)',
                value: 'PKR ${formatPaisa(s.remainingPaisa)}'),
            _PayRow(
                label: 'Monthly contribution',
                value:
                    'PKR ${formatPaisa(s.monthlyContributionPaisa)}'),
            if (s.hasPending)
              _PayRow(
                label: 'Pending (recorded, not verified)',
                value:
                    'Sent PKR ${formatPaisa(s.sentPendingPaisa)} · '
                    'Received PKR ${formatPaisa(s.receivedPendingPaisa)}',
              ),
            if (s.payments.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'No payments recorded yet',
                  style: SplitNestTheme.supportingStyle,
                ),
              )
            else
              ...s.payments.map((p) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.senderId == s.member.id
                                ? 'Sent to ${memberName(state.members, p.recipientId)}'
                                : 'Received from ${memberName(state.members, p.senderId)}',
                            style: SplitNestTheme.bodyStyle,
                          ),
                        ),
                        MoneyText(p.amount,
                            style: SplitNestTheme.bodyStyle.copyWith(
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        Text(
                          paymentStatusLabel(p.status),
                          style: SplitNestTheme.supportingStyle,
                        ),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

class _PayRow extends StatelessWidget {
  const _PayRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
              child: Text(label, style: SplitNestTheme.supportingStyle)),
          Text(value,
              style: SplitNestTheme.bodyStyle
                  .copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

Future<void> _openSettle(
  BuildContext context,
  AppState state, {
  ({String senderId, String recipientId, int amountPaisa})? prefill,
}) async {
  final b = state.balances;
  if (b == null) return;
  final debtors =
      b.rows.where((r) => (double.tryParse(r.net) ?? 0) < 0).toList();
  final creditors =
      b.rows.where((r) => (double.tryParse(r.net) ?? 0) > 0).toList();
  final amountCtrl = TextEditingController(
      text: prefill == null ? '' : formatPaisa(prefill.amountPaisa));
  String senderId = prefill?.senderId ??
      (debtors.isNotEmpty ? debtors.first.memberId : state.members.first.id);
  String recipientId = prefill?.recipientId ??
      (creditors.isNotEmpty
          ? creditors.first.memberId
          : state.members.last.id);
  String? error;

  // Exact paisa max, from the string nets (avoids double rounding).
  int? maxPaisa() {
    final sender = b.rows.where((r) => r.memberId == senderId).firstOrNull;
    final recipient =
        b.rows.where((r) => r.memberId == recipientId).firstOrNull;
    if (sender == null || recipient == null) return null;
    final senderNet = parsePaisa(sender.net) ?? 0;
    final recipientNet = parsePaisa(recipient.net) ?? 0;
    if (senderNet >= 0 || recipientNet <= 0) return null;
    return -senderNet < recipientNet ? -senderNet : recipientNet;
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) {
        final max = maxPaisa();
        return AlertDialog(
          title: const Text('Settle Debt'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (debtors.isEmpty || creditors.isEmpty)
                  const Text(
                    'Everyone is settled up — no outstanding debts.',
                    style: SplitNestTheme.supportingStyle,
                  )
                else ...[
                  const Text(
                    'Who owes whom',
                    style: SplitNestTheme.sectionStyle,
                  ),
                  const SizedBox(height: 8),
                  ...[
                    for (final d in debtors)
                      for (final c in creditors)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ActionChip(
                            avatar:
                                const Icon(Icons.handshake, size: 18),
                            label: Text(
                              '${d.name} → ${c.name} · up to PKR ${formatPaisa((-(parsePaisa(d.net) ?? 0) < (parsePaisa(c.net) ?? 0) ? -(parsePaisa(d.net) ?? 0) : (parsePaisa(c.net) ?? 0)))}',
                            ),
                            onPressed: () {
                              setDialog(() {
                                senderId = d.memberId;
                                recipientId = c.memberId;
                                amountCtrl.text = formatPaisa(
                                    (-(parsePaisa(d.net) ?? 0) <
                                                (parsePaisa(c.net) ?? 0)
                                            ? -(parsePaisa(d.net) ?? 0)
                                            : (parsePaisa(c.net) ?? 0)));
                              });
                            },
                          ),
                        ),
                  ],
                  const SizedBox(height: 8),
                ],
                DropdownButtonFormField<String>(
                                  isExpanded: true,
                  initialValue: senderId,
                  decoration: const InputDecoration(
                      labelText: 'Sender (debtor)'),
                  items: state.members
                      .map((m) => DropdownMenuItem(
                          value: m.id, child: Text(m.name)))
                      .toList(),
                  onChanged: (v) => setDialog(() => senderId = v!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                                  isExpanded: true,
                  initialValue: recipientId,
                  decoration: const InputDecoration(
                      labelText: 'Recipient (creditor)'),
                  items: state.members
                      .map((m) => DropdownMenuItem(
                          value: m.id, child: Text(m.name)))
                      .toList(),
                  onChanged: (v) => setDialog(() => recipientId = v!),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Amount (PKR, e.g. 250.00)',
                    helperText: max == null
                        ? null
                        : 'Max settleable: PKR ${formatPaisa(max)}',
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: state.isBusy || debtors.isEmpty
                  ? null
                  : () async {
                      final amount = amountCtrl.text.trim();
                      if (amount.isEmpty) {
                        setDialog(() => error = 'Enter an amount.');
                        return;
                      }
                      // Explicit confirmation before recording money movement.
                      final confirmed = await showDialog<bool>(
                        context: ctx,
                        builder: (confirmCtx) => AlertDialog(
                          title: const Text('Confirm settlement'),
                          content: Text(
                            '${memberName(state.members, senderId)} pays '
                            '${memberName(state.members, recipientId)} '
                            'PKR $amount.\n\nTotal spending stays unchanged.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(confirmCtx).pop(false),
                              child: const Text('Go back'),
                            ),
                            ElevatedButton(
                              onPressed: () =>
                                  Navigator.of(confirmCtx).pop(true),
                              child: const Text('Confirm payment'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      final done = await state.settle(
                        senderId: senderId,
                        recipientId: recipientId,
                        amount: amount,
                      );
                      if (done) {
                        if (ctx.mounted) Navigator.of(ctx).pop(true);
                      } else {
                        setDialog(() => error = state.errorMessage);
                      }
                    },
              child: state.isBusy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Record settlement'),
            ),
          ],
        );
      },
    ),
  );
  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settlement recorded.')));
  }
}
