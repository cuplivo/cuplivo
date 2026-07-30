import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat_member.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../../home/widgets/assistant_entry_actions.dart';
import '../group_chat_navigation.dart';
import '../widgets/group_avatar.dart';
import '../widgets/group_member_picker.dart';

/// Group settings: name/avatar edit, member grid (5 + add), advanced entry.
class GroupSettingsPage extends StatefulWidget {
  const GroupSettingsPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<GroupSettingsPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _avatarController;
  List<GroupChatMember> _members = const [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final g = context.read<GroupChatService>().getGroup(widget.groupId);
    _nameController = TextEditingController(text: g?.title ?? '');
    _avatarController = TextEditingController(text: g?.avatar ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _avatarController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final svc = context.read<GroupChatService>();
    await svc.ensureLoaded();
    final members = await svc.getMembers(widget.groupId);
    final g = svc.getGroup(widget.groupId);
    if (!mounted) return;
    setState(() {
      _members = List.of(members)
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      if (g != null) {
        _nameController.text = g.title;
        _avatarController.text = g.avatar ?? '';
      }
      _loading = false;
    });
  }

  Future<void> _saveBasics() async {
    final l10n = AppLocalizations.of(context)!;
    final svc = context.read<GroupChatService>();
    final g = svc.getGroup(widget.groupId);
    if (g == null) return;
    final title = _nameController.text.trim();
    if (title.isEmpty) {
      showAppSnackBar(
        context,
        message: l10n.groupChatCreateNameRequired,
        type: NotificationType.warning,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final avatar = _avatarController.text.trim();
      await svc.updateGroup(
        g.copyWith(
          title: title,
          avatar: avatar.isEmpty ? null : avatar,
          clearAvatar: avatar.isEmpty,
        ),
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.groupChatSettingsSave,
        type: NotificationType.success,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addMembers() async {
    final l10n = AppLocalizations.of(context)!;
    final existing = _members
        .where((m) => m.isAssistant && m.assistantId != null)
        .map((m) => m.assistantId!)
        .toSet();
    final picked = await showGroupMemberPicker(
      context,
      excludeAssistantIds: existing,
      minSelection: 1,
    );
    if (!mounted || picked == null || picked.isEmpty) return;

    final svc = context.read<GroupChatService>();
    final now = DateTime.now();
    var nextOrder = _members.isEmpty
        ? 0
        : _members.map((m) => m.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
    final next = List<GroupChatMember>.of(_members);
    for (final id in picked) {
      if (existing.contains(id)) continue;
      next.add(
        GroupChatMember(
          groupId: widget.groupId,
          kind: GroupChatMember.kindAssistant,
          assistantId: id,
          sortOrder: nextOrder++,
          createdAt: now,
        ),
      );
    }
    try {
      await svc.setMembers(widget.groupId, next);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.groupChatSettingsNeedTwoAssistants,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _removeMember(GroupChatMember member) async {
    final l10n = AppLocalizations.of(context)!;
    if (member.isUser) {
      showAppSnackBar(
        context,
        message: l10n.groupChatSettingsCannotRemoveUser,
        type: NotificationType.warning,
      );
      return;
    }
    final assistants = _members
        .where((m) => m.isAssistant && m.isEnabled && m.id != member.id)
        .length;
    if (assistants < 2) {
      showAppSnackBar(
        context,
        message: l10n.groupChatSettingsNeedTwoAssistants,
        type: NotificationType.warning,
      );
      return;
    }
    final next = _members.where((m) => m.id != member.id).toList();
    try {
      await context.read<GroupChatService>().setMembers(widget.groupId, next);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.groupChatSettingsNeedTwoAssistants,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _deleteGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(l10n.groupChatSettingsDeleteConfirmTitle),
          content: Text(l10n.groupChatSettingsDeleteConfirmContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.groupChatSettingsCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                l10n.groupChatSettingsDeleteConfirmAction,
                style: TextStyle(color: cs.error),
              ),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    await context.read<GroupChatService>().deleteGroup(widget.groupId);
    if (!mounted) return;
    closeGroupPage(context, count: 2);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ap = context.watch<AssistantProvider>();
    final up = context.watch<UserProvider>();
    final g = context.watch<GroupChatService>().getGroup(widget.groupId);

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.groupChatBackTooltip,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            minSize: 44,
            onTap: () => closeGroupPage(context),
            semanticLabel: l10n.groupChatBackTooltip,
          ),
        ),
        title: Text(l10n.groupChatSettingsTitle),
        actions: [
          Tooltip(
            message: l10n.groupChatSettingsSave,
            child: IosIconButton(
              icon: Lucide.Check,
              size: 22,
              minSize: 44,
              onTap: _saving ? null : _saveBasics,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                Center(
                  child: GroupAvatar(
                    title: _nameController.text.isEmpty
                        ? (g?.title ?? l10n.groupChatDefaultTitle)
                        : _nameController.text,
                    avatar: _avatarController.text.trim().isEmpty
                        ? null
                        : _avatarController.text.trim(),
                    size: 72,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: l10n.groupChatSettingsNameLabel,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _avatarController,
                  decoration: InputDecoration(
                    labelText: l10n.groupChatSettingsAvatarLabel,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.groupChatSettingsMembersSection,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.emphasis,
                    color: cs.onSurface.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 10),
                _MemberGrid(
                  members: _members,
                  resolveAssistant: (id) => ap.getById(id),
                  userName: up.name,
                  meLabel: l10n.groupChatSettingsUserLabel,
                  onTapAssistant: (a) =>
                      AssistantEntryActions.openAssistantSettings(
                        context,
                        a.id,
                      ),
                  onRemove: _removeMember,
                  onAdd: _addMembers,
                  addTooltip: l10n.groupChatSettingsAddMemberTooltip,
                  removeTooltip: l10n.groupChatSettingsRemoveMemberTooltip,
                ),
                const SizedBox(height: 24),
                _SettingsNavTile(
                  icon: Lucide.Settings2,
                  label: l10n.groupChatSettingsAdvanced,
                  onTap: () =>
                      openGroupAdvancedSettings(context, widget.groupId),
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _SettingsNavTile(
                  icon: Lucide.MessagesSquare,
                  label: l10n.groupChatSettingsDirectorLog,
                  onTap: () => openGroupDirectorLog(context, widget.groupId),
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _SettingsNavTile(
                  icon: Lucide.Trash2,
                  label: l10n.groupChatSettingsDelete,
                  danger: true,
                  onTap: _deleteGroup,
                  isDark: isDark,
                ),
              ],
            ),
    );
  }
}

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({
    required this.members,
    required this.resolveAssistant,
    required this.userName,
    required this.meLabel,
    required this.onTapAssistant,
    required this.onRemove,
    required this.onAdd,
    required this.addTooltip,
    required this.removeTooltip,
  });

  final List<GroupChatMember> members;
  final Assistant? Function(String id) resolveAssistant;
  final String userName;
  final String meLabel;
  final ValueChanged<Assistant> onTapAssistant;
  final ValueChanged<GroupChatMember> onRemove;
  final VoidCallback onAdd;
  final String addTooltip;
  final String removeTooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = <Widget>[
      for (final m in members)
        _MemberCell(
          member: m,
          assistant: m.assistantId == null
              ? null
              : resolveAssistant(m.assistantId!),
          userName: userName,
          meLabel: meLabel,
          onTapAssistant: onTapAssistant,
          onRemove: () => onRemove(m),
          removeTooltip: removeTooltip,
        ),
      Tooltip(
        message: addTooltip,
        child: IosCardPress(
          borderRadius: BorderRadius.circular(12),
          baseColor: cs.primary.withValues(alpha: 0.06),
          onTap: () {
            Haptics.soft();
            onAdd();
          },
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.45),
                    width: 1.2,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(Lucide.Plus, size: 22, color: cs.primary),
              ),
              const SizedBox(height: 6),
              Text(
                '+',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    ];

    return GridView.count(
      crossAxisCount: 5,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 6,
      childAspectRatio: 0.72,
      children: items,
    );
  }
}

class _MemberCell extends StatelessWidget {
  const _MemberCell({
    required this.member,
    required this.assistant,
    required this.userName,
    required this.meLabel,
    required this.onTapAssistant,
    required this.onRemove,
    required this.removeTooltip,
  });

  final GroupChatMember member;
  final Assistant? assistant;
  final String userName;
  final String meLabel;
  final ValueChanged<Assistant> onTapAssistant;
  final VoidCallback onRemove;
  final String removeTooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = member.isUser;
    final label = isUser
        ? (userName.trim().isEmpty ? meLabel : userName)
        : (assistant?.name ?? '?');

    return GestureDetector(
      onTap: isUser || assistant == null
          ? null
          : () => onTapAssistant(assistant!),
      onLongPress: isUser
          ? null
          : () {
              Haptics.soft();
              onRemove();
            },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (isUser)
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    label.characters.take(1).toString(),
                    style: TextStyle(
                      color: cs.primary,
                      fontWeight: AppFontWeights.emphasis,
                      fontSize: 18,
                    ),
                  ),
                )
              else
                AssistantAvatar(assistant: assistant, size: 48),
              if (!isUser)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Tooltip(
                    message: removeTooltip,
                    child: IosIconButton(
                      icon: Lucide.X,
                      size: 12,
                      padding: const EdgeInsets.all(4),
                      minSize: 22,
                      color: cs.error,
                      onTap: onRemove,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              color: cs.onSurface.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsNavTile extends StatelessWidget {
  const _SettingsNavTile({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.isDark,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDark;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96);
    final fg = danger ? cs.error : cs.onSurface;
    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: base,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: AppFontWeights.medium,
                color: fg,
              ),
            ),
          ),
          Icon(Lucide.ChevronRight, size: 18, color: fg.withValues(alpha: 0.4)),
        ],
      ),
    );
  }
}
