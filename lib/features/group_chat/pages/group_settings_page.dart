import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../widgets/group_settings_view.dart';

/// Mobile settings route. Desktop shows the same [GroupSettingsView] in a
/// dialog instead ([showGroupSettings]).
class GroupSettingsPage extends StatelessWidget {
  const GroupSettingsPage({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.groupChatBack,
          icon: const Icon(Lucide.ArrowLeft, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.groupChatSettingsTitle),
      ),
      body: GroupSettingsView(
        groupId: groupId,
        onDeleted: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
