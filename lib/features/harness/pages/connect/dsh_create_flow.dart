import 'package:flutter/material.dart';

import '../assistant/dsh_assistant_settings_page.dart';
import 'dsh_connect_mode_sheet.dart';

/// Starts the DeepSeek Harness creation flow from either create menu
/// (助手与群聊 on mobile/tablet and the desktop assistants pane).
///
/// Step 1 is the engine sheet ("连接到一个新的DeepSeek Harness", only 直接连接 in
/// phase 1); step 2 is the assistant page in create mode, which persists the
/// record and connects on `确认`. The flow lives in the connect folder so both
/// create menus share one path instead of each assembling it.
Future<void> startDshAssistantCreation(BuildContext context) async {
  final navigator = Navigator.of(context);
  final mode = await showDshConnectModeSheet(context);
  if (mode == null || !context.mounted) return;
  await navigator.push<void>(
    MaterialPageRoute(builder: (_) => const DshAssistantSettingsPage.create()),
  );
}
