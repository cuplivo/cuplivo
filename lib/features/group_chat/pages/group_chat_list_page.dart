import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/group_chat.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../group_chat_navigation.dart';
import '../widgets/group_avatar.dart';
import '../widgets/group_member_picker.dart';

/// List of multi-assistant group chats.
class GroupChatListPage extends StatefulWidget {
  const GroupChatListPage({super.key});

  @override
  State<GroupChatListPage> createState() => _GroupChatListPageState();
}

class _GroupChatListPageState extends State<GroupChatListPage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensure());
  }

  Future<void> _ensure() async {
    final svc = context.read<GroupChatService>();
    await svc.ensureLoaded();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _createGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final name = await _promptGroupName(context);
    if (!mounted || name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      showAppSnackBar(
        context,
        message: l10n.groupChatCreateNameRequired,
        type: NotificationType.warning,
      );
      return;
    }

    final selected = await showGroupMemberPicker(context, minSelection: 2);
    if (!mounted || selected == null) return;
    if (selected.length < 2) {
      showAppSnackBar(
        context,
        message: l10n.groupChatMembersMinError,
        type: NotificationType.warning,
      );
      return;
    }

    try {
      final svc = context.read<GroupChatService>();
      final group = await svc.createGroup(
        title: trimmed,
        assistantIds: selected,
      );
      if (!mounted) return;
      await openGroupChatPage(context, group.id);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.groupChatCreateFailed,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _openGroup(GroupChat group) async {
    context.read<GroupChatService>().setCurrentGroup(group.id);
    await openGroupChatPage(context, group.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final svc = context.watch<GroupChatService>();
    final groups = svc.getAllGroups();

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
        title: Text(l10n.groupChatListTitle),
        actions: [
          Tooltip(
            message: l10n.groupChatCreateTitle,
            child: IosIconButton(
              icon: Lucide.Plus,
              size: 22,
              minSize: 44,
              onTap: _createGroup,
              semanticLabel: l10n.groupChatCreateTitle,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : groups.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Lucide.MessagesSquare,
                      size: 40,
                      color: cs.onSurface.withValues(alpha: 0.35),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.groupChatListEmpty,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.groupChatListEmptyHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _createGroup,
                      icon: const Icon(Lucide.Plus, size: 18),
                      label: Text(l10n.groupChatCreateButton),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final g = groups[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _GroupCard(
                    group: g,
                    onTap: () => _openGroup(g),
                    onLongPress: () => openGroupSettings(context, g.id),
                  ),
                );
              },
            ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.onTap,
    required this.onLongPress,
  });

  final GroupChat group;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = isDark
        ? Colors.white10
        : Colors.white.withValues(alpha: 0.96);
    final memberCount = group.memberIds.isNotEmpty
        ? group.memberIds.length
        : null;
    final l10n = AppLocalizations.of(context)!;

    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: baseBg,
      onTap: onTap,
      onLongPress: onLongPress,
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            GroupAvatar(title: group.title, avatar: group.avatar, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                  if (memberCount != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.groupChatMembersCount(memberCount),
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> _promptGroupName(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(l10n.groupChatCreateTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.groupChatCreateNameLabel,
            hintText: l10n.groupChatCreateNameHint,
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.groupChatSettingsCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(
              l10n.groupChatCreateButton,
              style: TextStyle(color: cs.primary),
            ),
          ),
        ],
      );
    },
  );
  controller.dispose();
  if (result == null) return null;
  final t = result.trim();
  return t.isEmpty ? null : t;
}
