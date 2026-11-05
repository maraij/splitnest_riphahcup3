/// Profile: the logged-in member's name, member ID, total paid this
/// month and net balance — all from real state. There is no email or
/// role in the backend (members have only name + ID), so those fields
/// are omitted, never invented. The photo is picked by the user with
/// image_picker and stored locally (see AppState.setProfileImage).
library;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../core/widgets/member_avatar.dart';
import '../../state/app_state.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _pickPhoto(BuildContext context, AppState state) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        imageQuality: 80,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await state.setProfileImage(bytes);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not pick a photo.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final member = state.loggedInMember;
    final active = state.activeBalance;
    final mine = member == null
        ? 0.0
        : state.recentExpenses
            .where((e) => e.payerId == member.id)
            .fold(0.0, (s, e) => s + (double.tryParse(e.amount) ?? 0));
    final net = active == null ? null : double.tryParse(active.net) ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(SplitNestTheme.screenPadding),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Avatar with a VISIBLE camera badge (tappable) plus
                  // the labelled "Change photo" button below — the edit
                  // control is obvious, not a hidden tap. MemberAvatar
                  // already shows the stored photo when one exists.
                  if (member != null)
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        MemberAvatar(
                            memberId: member.id,
                            name: member.name,
                            radius: 48),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Material(
                            color: Theme.of(context).colorScheme.primary,
                            shape: const CircleBorder(
                              side: BorderSide(color: Colors.white, width: 2),
                            ),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => _pickPhoto(context, state),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Icon(
                                  Icons.photo_camera,
                                  size: 18,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    const Text('Not logged in',
                        style: SplitNestTheme.titleStyle),
                  const SizedBox(height: 16),
                  if (member != null) ...[
                    Text(member.name, style: SplitNestTheme.titleStyle),
                    const SizedBox(height: 4),
                    Text(member.id, style: SplitNestTheme.supportingStyle),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: member == null
                        ? null
                        : () => _pickPhoto(context, state),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Change photo'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('This month',
                      style: SplitNestTheme.sectionStyle),
                  const SizedBox(height: 12),
                  _Row(
                      label: 'Total paid',
                      value: 'PKR ${mine.toStringAsFixed(2)}'),
                  const SizedBox(height: 8),
                  _Row(
                    label: 'Net balance',
                    value: active == null
                        ? '—'
                        : net == 0
                            ? 'Settled up — PKR 0.00'
                            : net! > 0
                                ? 'You are owed PKR ${active.net}'
                                : 'You owe PKR ${active.net.replaceFirst('-', '')}',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: Text(label, style: SplitNestTheme.supportingStyle)),
        Text(value,
            style: SplitNestTheme.bodyStyle
                .copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}
