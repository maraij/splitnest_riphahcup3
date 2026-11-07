/// Invite & households (Phase 4): send invitations, share the
/// invite code/link, revoke pending invitations, accept invitations
/// addressed to the signed-in user (from the list, or by entering a
/// code / pasting a `splitnest.app/join?code=...` link), and switch
/// between the households the user belongs to.
///
/// The shareable link is plain text — there is no App Links /
/// deep-link wiring and no hosting behind `splitnest.app`, so the
/// working mechanism is the code itself (see docs/INVITATIONS.md).
/// WhatsApp sharing degrades gracefully: when WhatsApp is not
/// installed the user gets a plain message instead of a crash.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../core/widgets/error_banner.dart';
import '../../domain/models.dart';
import '../../state/app_state.dart';

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  String _selectedRole = 'member';

  /// The invitation created by the last successful send on this
  /// screen, shown with its code/link and share actions until the
  /// next send (or leaving the screen).
  Invitation? _justCreated;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _shareText(Invitation invite) =>
      'Join my SplitNest household "${invite.groupName}"! Open '
      'SplitNest, go to Invite & households, and enter code '
      '${invite.displayCode} — or use this link: ${invite.link}';

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _share(Invitation invite) async {
    try {
      await SharePlus.instance
          .share(ShareParams(text: _shareText(invite), subject: 'SplitNest invite'));
    } catch (_) {
      _snack('Sharing is not available on this device. Copy the link '
          'instead.');
    }
  }

  Future<void> _shareWhatsApp(Invitation invite) async {
    final uri = Uri.parse(
        'https://wa.me/?text=${Uri.encodeComponent(_shareText(invite))}');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        _snack('WhatsApp is not installed on this device. Copy the '
            'link instead.');
      }
    } catch (_) {
      _snack('WhatsApp is not installed on this device. Copy the link '
          'instead.');
    }
  }

  Future<void> _copy(String text, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _snack('$label copied.');
    } catch (_) {
      _snack('Could not copy the $label.');
    }
  }

  Future<void> _send(AppState state) async {
    final invite = await state.sendInvitation(
      email: _emailController.text,
      role: _selectedRole,
    );
    if (!mounted) return;
    if (invite != null) {
      setState(() => _justCreated = invite);
      _emailController.clear();
      _snack('Invitation sent to ${invite.invitedEmail}.');
    }
  }

  Future<void> _revoke(AppState state, Invitation invite) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke invitation?'),
        content: Text(
          'The invitation to ${invite.invitedEmail} will stop '
          'working. You can send a new one later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final ok = await state.revokeInvitation(invite.id);
    if (mounted && ok) {
      if (_justCreated?.id == invite.id) {
        setState(() => _justCreated = null);
      }
      _snack('Invitation revoked.');
    }
  }

  Future<void> _accept(AppState state, Invitation invite) async {
    final accepted = await state.acceptInvitation(invite.id);
    if (!mounted) return;
    if (accepted != null) {
      _snack('You joined ${accepted.groupName}.');
    }
  }

  Future<void> _acceptCode(AppState state) async {
    final accepted =
        await state.acceptInvitationByCode(_codeController.text);
    if (!mounted) return;
    if (accepted != null) {
      _codeController.clear();
      _snack('You joined ${accepted.groupName}.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final pendingInvites =
        state.groupInvitations.where((i) => i.isPending).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Invite & households')),
      body: RefreshIndicator(
        onRefresh: () async {
          await state.refresh();
        },
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
            // ---- Households + member counts ----
            const Text('Your households',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (final group in state.userGroups)
                    ListTile(
                      leading: Icon(
                        group.groupId == state.groupId
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(group.name),
                      subtitle: Text(
                        [
                          if (group.role != null) 'You are ${group.role}',
                          if (group.groupId == state.groupId)
                            'Current household',
                        ].join(' · '),
                      ),
                      onTap: state.isBusy ||
                              group.groupId == state.groupId
                          ? null
                          : () => state.switchGroup(group.groupId),
                    ),
                  if (state.userGroups.isEmpty)
                    const ListTile(
                      title: Text('No households yet'),
                      subtitle: Text(
                          'Your household loads after sign-in.'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: _Count(
                        label: 'Total members',
                        value: '${state.members.length}',
                      ),
                    ),
                    Expanded(
                      child: _Count(
                        label: 'Active members',
                        value: '${state.members.length}',
                      ),
                    ),
                    Expanded(
                      child: _Count(
                        label: 'Pending invites',
                        value: '${state.pendingInviteCount}',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Every roster member counts as active — SplitNest has '
                'no deactivated members.',
                style: SplitNestTheme.supportingStyle,
              ),
            ),
            const SizedBox(height: 16),
            // ---- Invite someone ----
            const Text('Invite someone',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            if (!state.canInvite)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Only the household owner or an admin can invite '
                    'new members. Ask the owner to invite them, or to '
                    'make you an admin.',
                    style: SplitNestTheme.bodyStyle,
                  ),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          hintText: 'name@example.com',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (state.isGroupOwner)
                        DropdownButtonFormField<String>(
                          initialValue: _selectedRole,
                          decoration: const InputDecoration(
                            labelText: 'Role to grant',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'member',
                              child: Text('Member'),
                            ),
                            DropdownMenuItem(
                              value: 'admin',
                              child: Text('Admin'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _selectedRole = value);
                            }
                          },
                        )
                      else
                        const Text(
                          'Role to grant: Member (only the household '
                          'owner can grant admin).',
                          style: SplitNestTheme.supportingStyle,
                        ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: state.isBusy
                              ? null
                              : () => _send(state),
                          icon: const Icon(Icons.mail_outline),
                          label: const Text('Send invitation'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Invitations expire after 7 days. The invitee '
                        'signs in with the invited email and enters '
                        'the code below (or accepts from "Invitations '
                        'for you").',
                        style: SplitNestTheme.supportingStyle,
                      ),
                    ],
                  ),
                ),
              ),
            // ---- The just-created invite: code, link, share ----
            if (_justCreated != null) ...[
              const SizedBox(height: 16),
              _InviteShareCard(
                invite: _justCreated!,
                onShare: () => _share(_justCreated!),
                onWhatsApp: () => _shareWhatsApp(_justCreated!),
                onCopyLink: () => _copy(_justCreated!.link, 'Link'),
                onCopyCode: () =>
                    _copy(_justCreated!.displayCode, 'Code'),
              ),
            ],
            // ---- Pending invitations this group sent ----
            if (state.canInvite) ...[
              const SizedBox(height: 16),
              const Text('Pending invitations',
                  style: SplitNestTheme.sectionStyle),
              const SizedBox(height: 8),
              if (pendingInvites.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No invitations yet. Send one above.',
                      style: SplitNestTheme.bodyStyle,
                    ),
                  ),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < pendingInvites.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _SentInviteTile(
                          invite: pendingInvites[i],
                          dateText: _date,
                          onShare: () => _share(pendingInvites[i]),
                          onWhatsApp: () =>
                              _shareWhatsApp(pendingInvites[i]),
                          onCopyLink: () =>
                              _copy(pendingInvites[i].link, 'Link'),
                          onRevoke: state.isBusy
                              ? null
                              : () =>
                                  _revoke(state, pendingInvites[i]),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
            // ---- Invitations for me ----
            const SizedBox(height: 16),
            const Text('Invitations for you',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            if (state.myInvitations.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No invitations for your email address.',
                    style: SplitNestTheme.bodyStyle,
                  ),
                ),
              )
            else
              Card(
                child: Column(
                  children: [
                    for (var i = 0;
                        i < state.myInvitations.length;
                        i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _MyInviteTile(
                        invite: state.myInvitations[i],
                        dateText: _date,
                        onAccept: state.isBusy
                            ? null
                            : () =>
                                _accept(state, state.myInvitations[i]),
                      ),
                    ],
                  ],
                ),
              ),
            // ---- Enter a code ----
            const SizedBox(height: 16),
            const Text('Enter invite code',
                style: SplitNestTheme.sectionStyle),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _codeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Invite code or link',
                        hintText: 'ABCD-1234-EFGH',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed:
                            state.isBusy ? null : () => _acceptCode(state),
                        icon: const Icon(Icons.group_add_outlined),
                        label: const Text('Join household'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Paste a code or a splitnest.app/join link — '
                      'the code is extracted from it. The link itself '
                      'does not open the app; entering the code is '
                      'the way in.',
                      style: SplitNestTheme.supportingStyle,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: SplitNestTheme.supportingStyle,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// The just-created invitation, with its code, link and share
/// actions.
class _InviteShareCard extends StatelessWidget {
  const _InviteShareCard({
    required this.invite,
    required this.onShare,
    required this.onWhatsApp,
    required this.onCopyLink,
    required this.onCopyCode,
  });
  final Invitation invite;
  final VoidCallback onShare;
  final VoidCallback onWhatsApp;
  final VoidCallback onCopyLink;
  final VoidCallback onCopyCode;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Invitation sent to ${invite.invitedEmail}',
              style: SplitNestTheme.sectionStyle,
            ),
            const SizedBox(height: 8),
            SelectableText(
              invite.displayCode,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              invite.link,
              style: SplitNestTheme.supportingStyle,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share'),
                ),
                OutlinedButton.icon(
                  onPressed: onWhatsApp,
                  icon: const Icon(Icons.chat_outlined),
                  label: const Text('WhatsApp'),
                ),
                OutlinedButton.icon(
                  onPressed: onCopyLink,
                  icon: const Icon(Icons.link_outlined),
                  label: const Text('Copy link'),
                ),
                OutlinedButton.icon(
                  onPressed: onCopyCode,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy code'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SentInviteTile extends StatelessWidget {
  const _SentInviteTile({
    required this.invite,
    required this.dateText,
    required this.onShare,
    required this.onWhatsApp,
    required this.onCopyLink,
    required this.onRevoke,
  });
  final Invitation invite;
  final String Function(DateTime) dateText;
  final VoidCallback onShare;
  final VoidCallback onWhatsApp;
  final VoidCallback onCopyLink;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final status = invite.effectiveStatus;
    return ListTile(
      title: Text(invite.invitedEmail),
      subtitle: Text(
        '${invite.role} · ${status == 'pending' ? 'Expires ${dateText(invite.expiresAt)}' : status[0].toUpperCase() + status.substring(1)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (invite.isPending) ...[
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: 'Share',
              onPressed: onShare,
            ),
            IconButton(
              icon: const Icon(Icons.chat_outlined),
              tooltip: 'Share via WhatsApp',
              onPressed: onWhatsApp,
            ),
            IconButton(
              icon: const Icon(Icons.link_outlined),
              tooltip: 'Copy link',
              onPressed: onCopyLink,
            ),
            IconButton(
              icon: const Icon(Icons.cancel_outlined),
              tooltip: 'Revoke',
              onPressed: onRevoke,
            ),
          ] else
            Icon(
              status == 'accepted'
                  ? Icons.check_circle_outline
                  : Icons.cancel_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }
}

class _MyInviteTile extends StatelessWidget {
  const _MyInviteTile({
    required this.invite,
    required this.dateText,
    required this.onAccept,
  });
  final Invitation invite;
  final String Function(DateTime) dateText;
  final VoidCallback? onAccept;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.mail_outline),
      title: Text(invite.groupName),
      subtitle: Text(
        'Invited by ${invite.inviterName ?? invite.invitedBy} · '
        '${invite.role} · ${invite.isPending ? 'Expires ${dateText(invite.expiresAt)}' : invite.effectiveStatus[0].toUpperCase() + invite.effectiveStatus.substring(1)}',
      ),
      trailing: invite.isPending
          ? ElevatedButton(
              onPressed: onAccept,
              child: const Text('Accept'),
            )
          : Text(
              invite.effectiveStatus[0].toUpperCase() +
                  invite.effectiveStatus.substring(1),
              style: SplitNestTheme.supportingStyle,
            ),
    );
  }
}
