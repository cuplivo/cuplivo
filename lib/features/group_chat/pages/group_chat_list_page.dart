import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/group_chat.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../widgets/group_avatar.dart';
import 'group_chat_page.dart';
import 'group_chat_settings_page.dart';

class GroupChatListPage extends StatefulWidget {
  const GroupChatListPage({super.key});

  @override
  State<GroupChatListPage> createState() => _GroupChatListPageState();
}

class _GroupChatListPageState extends State<GroupChatListPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<GroupChatProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final groups = context.watch<GroupChatProvider>().groups;

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.groupChatMyGroupChats),
        actions: [
          Tooltip(
            message: l10n.groupChatCreate,
            child: IosIconButton(
              icon: Lucide.Plus,
              color: cs.onSurface,
              size: 22,
              onTap: () => _createGroup(context),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: groups.isEmpty
          ? Center(
              child: Text(
                l10n.groupChatEmptyList,
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final g = groups[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _GroupCard(group: g),
                );
              },
            ),
    );
  }

  Future<void> _createGroup(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(l10n.groupChatCreate),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.groupChatNameHint),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.groupChatCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: Text(l10n.groupChatConfirm),
            ),
          ],
        );
      },
    );
    if (name == null || !context.mounted) return;
    final group = await context.read<GroupChatProvider>().createGroup(
      name: name.trim().isEmpty ? l10n.groupChatDefaultName : name.trim(),
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupChatSettingsPage(groupChatId: group.id),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});
  final GroupChat group;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<GroupChatProvider>();
    final preview = provider.latestMessagePreview(group.id);
    final baseBg = isDark
        ? Colors.white10
        : Colors.white.withValues(alpha: 0.96);

    return IosCardPress(
      baseColor: baseBg,
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.all(12),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GroupChatPage(groupChatId: group.id),
          ),
        );
      },
      child: Row(
        children: [
          GroupAvatar(avatar: group.avatar, name: group.name, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  preview ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          IosIconButton(
            icon: Lucide.Settings,
            size: 18,
            color: cs.onSurface.withValues(alpha: 0.6),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupChatSettingsPage(groupChatId: group.id),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
