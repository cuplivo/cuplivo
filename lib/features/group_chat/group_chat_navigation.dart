import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../desktop/desktop_chat_pane_controller.dart';
import 'pages/group_advanced_settings_page.dart';
import 'pages/group_chat_list_page.dart';
import 'pages/group_chat_page.dart';
import 'pages/group_director_log_page.dart';
import 'pages/group_settings_page.dart';

bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Open the group chat list in the platform's native navigation shell.
Future<void> openGroupChatList(BuildContext context) async {
  if (_isDesktopPlatform) {
    context.read<DesktopChatPaneController>().push(
      const DesktopChatPaneDestination(DesktopChatPaneKind.groupList),
    );
    return;
  }
  await Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => const GroupChatListPage()));
}

Future<void> openGroupChatPage(BuildContext context, String groupId) async {
  if (_isDesktopPlatform) {
    context.read<DesktopChatPaneController>().push(
      DesktopChatPaneDestination(
        DesktopChatPaneKind.groupChat,
        groupId: groupId,
      ),
    );
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => GroupChatPage(groupId: groupId)),
  );
}

Future<void> openGroupSettings(BuildContext context, String groupId) async {
  if (_isDesktopPlatform) {
    context.read<DesktopChatPaneController>().push(
      DesktopChatPaneDestination(
        DesktopChatPaneKind.groupSettings,
        groupId: groupId,
      ),
    );
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => GroupSettingsPage(groupId: groupId)),
  );
}

Future<void> openGroupAdvancedSettings(
  BuildContext context,
  String groupId,
) async {
  if (_isDesktopPlatform) {
    context.read<DesktopChatPaneController>().push(
      DesktopChatPaneDestination(
        DesktopChatPaneKind.groupAdvancedSettings,
        groupId: groupId,
      ),
    );
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => GroupAdvancedSettingsPage(groupId: groupId),
    ),
  );
}

Future<void> openGroupDirectorLog(BuildContext context, String groupId) async {
  if (_isDesktopPlatform) {
    context.read<DesktopChatPaneController>().push(
      DesktopChatPaneDestination(
        DesktopChatPaneKind.groupDirectorLog,
        groupId: groupId,
      ),
    );
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => GroupDirectorLogPage(groupId: groupId)),
  );
}

void closeGroupPage(BuildContext context, {int count = 1}) {
  if (_isDesktopPlatform) {
    context.read<DesktopChatPaneController>().pop(count);
    return;
  }
  final navigator = Navigator.of(context);
  for (var i = 0; i < count && navigator.canPop(); i++) {
    navigator.pop();
  }
}
