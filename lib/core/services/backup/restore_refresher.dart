import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../database/business_preferences.dart';
import '../../providers/assistant_provider.dart';

/// Re-reads every provider that mirrors persisted state after a restore /
/// sync rewrote SQLite, so the UI does not keep a pre-restore in-memory
/// snapshot while the restart prompt is up.
///
/// Single shared refresh list for all restore entry points (backup page,
/// desktop pane, LAN sync). A provider that persists state must subscribe
/// here rather than reloading at individual call sites.
Future<void> refreshProvidersAfterRestore(BuildContext context) async {
  // ChatService state stays current through the live apply path (every
  // restore write goes through ChatService methods that notify listeners);
  // the facades below cache independently and must be forced to re-read.
  final preferences = context.read<BusinessPreferences>();
  final assistants = context.read<AssistantProvider>();
  try {
    await preferences.reload();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: BusinessPreferences: $e');
  }
  try {
    await assistants.reload();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: AssistantProvider: $e');
  }
}
