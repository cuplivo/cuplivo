import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/group_chat/pages/group_advanced_settings_page.dart';
import '../features/group_chat/pages/group_chat_list_page.dart';
import '../features/group_chat/pages/group_chat_page.dart';
import '../features/group_chat/pages/group_director_log_page.dart';
import '../features/group_chat/pages/group_settings_page.dart';
import '../features/home/pages/home_page.dart';
import 'desktop_chat_pane_controller.dart';

/// Desktop chat page entry.
/// For phase 1, reuse the tablet layout that already exists in HomePage when the width is large.
/// Later we can extract the tablet branch into a dedicated desktop layout under this folder.
class DesktopChatPage extends StatelessWidget {
  const DesktopChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final destinations = context.watch<DesktopChatPaneController>().stack;
    return IndexedStack(
      index: destinations.length,
      children: [
        const HomePage(),
        for (final destination in destinations)
          KeyedSubtree(
            key: ValueKey(destination.key),
            child: _buildDestination(destination),
          ),
      ],
    );
  }

  Widget _buildDestination(DesktopChatPaneDestination destination) {
    final groupId = destination.groupId;
    return switch (destination.kind) {
      DesktopChatPaneKind.groupList => const GroupChatListPage(),
      DesktopChatPaneKind.groupChat => GroupChatPage(groupId: groupId!),
      DesktopChatPaneKind.groupSettings => GroupSettingsPage(groupId: groupId!),
      DesktopChatPaneKind.groupAdvancedSettings => GroupAdvancedSettingsPage(
        groupId: groupId!,
      ),
      DesktopChatPaneKind.groupDirectorLog => GroupDirectorLogPage(
        groupId: groupId!,
      ),
    };
  }
}
