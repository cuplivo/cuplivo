import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/group_chat_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../widgets/group_chat_view.dart';
import 'group_chat_settings_page.dart';

/// Mobile group chat route: a thin Scaffold + AppBar wrapper around the
/// shell-agnostic [GroupChatView].
///
/// On desktop the view is instead embedded into the Chat tab content slot
/// (see HomePage._buildTabletLayout); this page is only pushed as a route on
/// mobile platforms.
class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.groupChatId});

  final String groupChatId;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final group = context.watch<GroupChatProvider>().getById(
      widget.groupChatId,
    );

    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.groupChatMyGroupChats)),
        body: Center(child: Text(l10n.groupChatNotFound)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(group.name),
        actions: [
          IosIconButton(
            icon: Lucide.Menu,
            color: cs.onSurface,
            size: 22,
            semanticLabel: l10n.groupChatSettingsTitle,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupChatSettingsPage(groupChatId: group.id),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: GroupChatView(groupChatId: widget.groupChatId),
    );
  }
}
