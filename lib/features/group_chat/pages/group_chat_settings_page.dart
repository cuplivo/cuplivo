import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/avatar_picker_sheet.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../widgets/group_avatar.dart';
import 'group_chat_advanced_settings_page.dart';
import 'group_chat_director_logs_page.dart';
import 'group_chat_invite_assistants_sheet.dart';

class GroupChatSettingsPage extends StatefulWidget {
  const GroupChatSettingsPage({super.key, required this.groupChatId});
  final String groupChatId;

  @override
  State<GroupChatSettingsPage> createState() => _GroupChatSettingsPageState();
}

class _GroupChatSettingsPageState extends State<GroupChatSettingsPage> {
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    _nameCtrl = TextEditingController(text: g?.name ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final gp = context.watch<GroupChatProvider>();
    final group = gp.getById(widget.groupChatId);
    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.groupChatSettingsTitle)),
        body: Center(child: Text(l10n.groupChatNotFound)),
      );
    }
    final members = gp.membersOf(group.id);
    final assistants = context.watch<AssistantProvider>().assistants;
    final byId = {for (final a in assistants) a.id: a};
    final user = context.watch<UserProvider>();

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.groupChatSettingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          // Basic info
          Text(
            l10n.groupChatBasicInfo,
            style: TextStyle(
              fontWeight: AppFontWeights.emphasis,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _avatar(group),
              const SizedBox(width: 12),
              Expanded(
                child: IosFormTextField(
                  label: l10n.groupChatNameHint,
                  controller: _nameCtrl,
                  hintText: l10n.groupChatNameHint,
                  onChanged: (v) async {
                    await gp.updateGroup(group.copyWith(name: v.trim()));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Members
          Text(
            l10n.groupChatMembers,
            style: TextStyle(
              fontWeight: AppFontWeights.emphasis,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 10),
          _MemberGrid(
            group: group,
            members: members,
            assistantsById: byId,
            userName: user.name,
            userAvatar: user.avatarType == 'file' ? user.avatarValue : null,
            onInvite: () => _invite(context, group),
            onRemoveAssistant: (id) => gp.removeAssistant(group.id, id),
          ),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Lucide.Settings2, color: cs.primary),
            title: Text(l10n.groupChatAdvancedSettings),
            trailing: const Icon(Lucide.ChevronRight, size: 18),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      GroupChatAdvancedSettingsPage(groupChatId: group.id),
                ),
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Lucide.FileText, color: cs.primary),
            title: Text(l10n.groupChatDirectorLogs),
            trailing: const Icon(Lucide.ChevronRight, size: 18),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      GroupChatDirectorLogsPage(groupChatId: group.id),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: cs.onSurface,
              backgroundColor: cs.surfaceContainerHighest.withValues(
                alpha: 0.6,
              ),
            ),
            onPressed: () => _confirmDuplicate(context, group),
            child: Text(l10n.groupChatDuplicate),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: cs.error,
              backgroundColor: cs.error.withValues(alpha: 0.12),
            ),
            onPressed: () => _confirmDelete(context, group),
            child: Text(l10n.groupChatDelete),
          ),
        ],
      ),
    );
  }

  Widget _avatar(GroupChat group) {
    return IosCardPress(
      borderRadius: BorderRadius.circular(999),
      baseColor: Colors.transparent,
      duration: const Duration(milliseconds: 260),
      onTap: () => _showAvatarPicker(context, group),
      child: GroupAvatar(avatar: group.avatar, name: group.name, size: 56),
    );
  }

  Future<void> _showAvatarPicker(BuildContext context, GroupChat group) async {
    final gp = context.read<GroupChatProvider>();
    await showAvatarPickerSheet(
      context,
      onPick: (v) async {
        if (!context.mounted) return;
        await gp.updateGroup(group.copyWith(avatar: v));
      },
      onReset: () async {
        if (!context.mounted) return;
        await gp.updateGroup(group.copyWith(avatar: null));
      },
    );
  }

  Future<void> _invite(BuildContext context, GroupChat group) async {
    final l10n = AppLocalizations.of(context)!;
    final gp = context.read<GroupChatProvider>();
    final current = gp.assistantIdsOf(group.id);
    if (current.length >= groupChatMemberHardCap) {
      showAppSnackBar(context, message: l10n.groupChatMemberHardCapReached);
      return;
    }
    final selected = await showGroupChatInviteAssistantsSheet(
      context,
      alreadyInGroup: current.toSet(),
      softCap: groupChatMemberSoftCap,
      hardCap: groupChatMemberHardCap,
    );
    if (selected == null || selected.isEmpty || !context.mounted) return;
    try {
      await gp.addAssistants(group.id, selected);
      if (gp.assistantIdsOf(group.id).length >= groupChatMemberSoftCap &&
          context.mounted) {
        showAppSnackBar(context, message: l10n.groupChatMemberSoftCapWarning);
      }
    } on StateError catch (e) {
      if (e.message == 'member_hard_cap' && context.mounted) {
        showAppSnackBar(context, message: l10n.groupChatMemberHardCapReached);
      }
    }
  }

  Future<void> _confirmDuplicate(BuildContext context, GroupChat group) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.groupChatDuplicate),
        content: Text(l10n.groupChatDuplicateConfigOnlyDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.groupChatCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.groupChatDuplicateConfigOnly),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<GroupChatProvider>().duplicateGroup(group);
    if (!context.mounted) return;
    showAppSnackBar(context, message: l10n.groupChatDuplicateDone);
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete(BuildContext context, GroupChat group) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.groupChatDelete),
        content: Text(l10n.groupChatDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.groupChatCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.groupChatConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<GroupChatProvider>().deleteGroup(group.id);
    if (!context.mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == null);
    // Pop settings + maybe chat
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }
}

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({
    required this.group,
    required this.members,
    required this.assistantsById,
    required this.userName,
    required this.userAvatar,
    required this.onInvite,
    required this.onRemoveAssistant,
  });

  final GroupChat group;
  final List members;
  final Map<String, Assistant> assistantsById;
  final String userName;
  final String? userAvatar;
  final VoidCallback onInvite;
  final void Function(String assistantId) onRemoveAssistant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cells = <Widget>[];
    for (final m in members) {
      if (m.isUser) {
        cells.add(
          _MemberCell(
            label: userName.isEmpty ? l10n.groupChatUserLabel : userName,
            avatarPath: userAvatar,
            onLongPress: null,
          ),
        );
      } else if (m.assistantId != null) {
        final a = assistantsById[m.assistantId!];
        cells.add(
          _MemberCell(
            label: a?.name ?? m.assistantId!,
            avatarPath: a?.avatar,
            onLongPress: () => onRemoveAssistant(m.assistantId!),
          ),
        );
      }
    }
    cells.add(
      _MemberCell(label: l10n.groupChatInvite, isAdd: true, onTap: onInvite),
    );

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: cells
          .map(
            (c) => SizedBox(
              width: (MediaQuery.sizeOf(context).width - 32 - 48) / 5,
              child: c,
            ),
          )
          .toList(),
    );
  }
}

class _MemberCell extends StatelessWidget {
  const _MemberCell({
    required this.label,
    this.avatarPath,
    this.isAdd = false,
    this.onTap,
    this.onLongPress,
  });

  final String label;
  final String? avatarPath;
  final bool isAdd;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isAdd)
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Icon(Lucide.Plus, color: cs.primary),
            )
          else
            _smallAvatar(cs),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallAvatar(ColorScheme cs) {
    final a = avatarPath?.trim() ?? '';
    if (a.isNotEmpty && !kIsWeb) {
      final path = SandboxPathResolver.fix(a);
      final f = File(path);
      if (f.existsSync()) {
        return ClipOval(
          child: Image.file(f, width: 48, height: 48, fit: BoxFit.cover),
        );
      }
    }
    return CircleAvatar(
      radius: 24,
      backgroundColor: cs.primary.withValues(alpha: 0.12),
      child: Text(
        label.isNotEmpty ? label.characters.first : '?',
        style: TextStyle(color: cs.primary),
      ),
    );
  }
}
