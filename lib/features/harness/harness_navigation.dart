import 'package:flutter/material.dart';

import '../../core/models/assistant.dart';
import 'pages/harness_settings_page.dart';
import 'pages/harness_web_page.dart';

/// Opens the connection settings for a DeepSeek Harness assistant.
Future<void> openHarnessSettings(BuildContext context, String assistantId) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => HarnessSettingsPage(assistantId: assistantId),
    ),
  );
}

/// Opens a connected DeepSeek Harness: its own WebUI, with Cuplivo's return bar
/// on top.
Future<void> openHarnessWebUi(BuildContext context, String assistantId) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => HarnessWebPage(assistantId: assistantId)),
  );
}

/// The one entry point for "go to this harness": a link that was never set
/// opens the page that sets it, instead of an empty view.
Future<void> openHarnessForAssistant(
  BuildContext context,
  Assistant assistant,
) {
  final url = assistant.harnessUrl?.trim() ?? '';
  return url.isEmpty
      ? openHarnessSettings(context, assistant.id)
      : openHarnessWebUi(context, assistant.id);
}
