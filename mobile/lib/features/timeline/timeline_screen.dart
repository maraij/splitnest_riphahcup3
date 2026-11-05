/// Timeline: a read-only activity feed, SEPARATE from Home (Home
/// stays free of any activity feed). Every checkout, expense post
/// and settlement this session, newest first, with who/when/amount.
/// Reads only AppState.activityLog; session-only, resets on reload.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/widgets/illustrations.dart';
import '../../state/app_state.dart';

class TimelineScreen extends StatelessWidget {
  const TimelineScreen({super.key});

  static IconData _iconFor(String type) => switch (type) {
        'checkout' => Icons.shopping_cart_checkout,
        'settle' => Icons.handshake,
        _ => Icons.receipt_long,
      };

  String _time(DateTime d) =>
      '${formatDate(d)} · ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entries = state.activityLog.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Timeline')),
      body: entries.isEmpty
          ? ListView(
              padding:
                  const EdgeInsets.all(SplitNestTheme.screenPadding),
              children: const [
                SizedBox(height: 32),
                EmptyStateIllustration(kind: EmptyArtKind.receipt),
                SizedBox(height: 8),
                Text('No activity yet in this session',
                    style: SplitNestTheme.sectionStyle,
                    textAlign: TextAlign.center),
              ],
            )
          : ListView.builder(
              padding:
                  const EdgeInsets.all(SplitNestTheme.screenPadding),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                return Card(
                  child: ListTile(
                    leading: Icon(
                      _iconFor(e.type),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(e.title),
                    subtitle: Text(
                      '${memberName(state.members, e.memberId)} · ${e.detail.isEmpty ? '' : '${e.detail} · '}${_time(e.timestamp)}',
                    ),
                    trailing: Text(
                      'PKR ${e.amount}',
                      style: SplitNestTheme.bodyStyle
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
