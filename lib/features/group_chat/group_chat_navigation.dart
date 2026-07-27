import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'pages/group_advanced_settings_page.dart';
import 'pages/group_chat_list_page.dart';
import 'pages/group_chat_page.dart';
import 'pages/group_director_log_page.dart';
import 'pages/group_settings_page.dart';

bool get _isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Open the group chat list (mobile: push; desktop: centered dialog shell).
Future<void> openGroupChatList(BuildContext context) async {
  if (_isDesktopPlatform) {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'group-chat-list',
      barrierColor: Colors.black.withValues(alpha: 0.18),
      pageBuilder: (ctx, _, __) {
        final size = MediaQuery.sizeOf(ctx);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 520,
              maxHeight: size.height * 0.86,
              minWidth: 400,
              minHeight: 360,
            ),
            child: Material(
              color: Theme.of(ctx).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: const GroupChatListPage(embeddedDialog: true),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
    return;
  }
  await Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => const GroupChatListPage()));
}

Future<void> openGroupChatPage(BuildContext context, String groupId) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => GroupChatPage(groupId: groupId)),
  );
}

Future<void> openGroupSettings(BuildContext context, String groupId) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => GroupSettingsPage(groupId: groupId)),
  );
}

Future<void> openGroupAdvancedSettings(
  BuildContext context,
  String groupId,
) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => GroupAdvancedSettingsPage(groupId: groupId),
    ),
  );
}

Future<void> openGroupDirectorLog(BuildContext context, String groupId) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => GroupDirectorLogPage(groupId: groupId)),
  );
}
