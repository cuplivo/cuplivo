// Prints the official-WebUI DOM recipes as JSON.
//
// The CI DOM-contract job runs exactly these strings in a desktop Chrome
// against the live DeepSeek Harness Host, so the recipes the acceptance proves
// are the recipes the app ships (no second copy in a test tool). Labels and
// kinds are placeholders the Node runner fills from the harvest result:
//   "__SIDEBAR_LABEL__", "__RAIL_LABEL__", "__RAIL_KIND__", "__SETTINGS_SECTION__"
//
// Usage (from the package root, after `flutter pub get`):
//   dart run tool/e2e/print_dsh_surface_scripts.dart
import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/features/harness/services/dsh_surface_scripts.dart';

void main() {
  final payload = <String, Object?>{
    'channel': DshSurfaceScripts.channelName,
    'harvest': DshSurfaceScripts.harvest,
    'settings': DshSurfaceScripts.settings(),
    'settingsLand': DshSurfaceScripts.settings(
      landLabel: '__SETTINGS_SECTION__',
    ),
    'sidebarLanding': DshSurfaceScripts.sidebarLanding('__SIDEBAR_LABEL__'),
    'moreMenuLanding': DshSurfaceScripts.moreMenuLanding,
    'railLanding': DshSurfaceScripts.railLanding(
      '__RAIL_LABEL__',
      kind: '__RAIL_KIND__',
    ),
  };
  stdout.writeln(jsonEncode(payload));
}
