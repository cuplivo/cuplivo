// The intent "closing the window hides it, it does not quit" reaches the app
// through two different OS messages, and only one of them is a close on every
// platform. This is the rule that says which — the table #1036 was broken on:
// answering a close-to-tray close as an exit flushed the app's queues and
// stopped its LAN sync listener while the process kept running.

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/desktop/desktop_tray_controller.dart';

void main() {
  bool hides({
    TargetPlatform platform = TargetPlatform.windows,
    bool showTray = true,
    bool minimizeToTrayOnClose = true,
    bool quitting = false,
  }) => exitRequestHidesToTray(
    platform: platform,
    showTray: showTray,
    minimizeToTrayOnClose: minimizeToTrayOnClose,
    quitting: quitting,
  );

  test('a Windows close with close-to-tray on is a hide', () {
    expect(hides(), isTrue);
  });

  // Linux reaches the hide through `onWindowClose`, never through an exit
  // request: window_manager installs its own `delete-event` handler whose return
  // value is `preventClose` (0.5.2, `linux/window_manager_plugin.cc`), and it
  // runs before the engine's handler, which is attached at realize — a handled
  // delete-event stops the emission, so the engine never asks the framework.
  // The rule must say so: an arm no close can reach is a path no test proves.
  test(
    'Linux is not a hide on an exit request: its close never gets there',
    () {
      expect(hides(platform: TargetPlatform.linux), isFalse);
    },
  );

  test('macOS is never a hide: its exit request is a terminate', () {
    expect(hides(platform: TargetPlatform.macOS), isFalse);
  });

  test('the tray Exit item always quits', () {
    for (final platform in TargetPlatform.values) {
      expect(
        hides(platform: platform, quitting: true),
        isFalse,
        reason: 'tray Exit must quit on $platform',
      );
    }
  });

  test('close-to-tray needs both switches', () {
    expect(hides(showTray: false), isFalse);
    expect(hides(minimizeToTrayOnClose: false), isFalse);
    // The settings layer already enforces "minimize implies tray"; the rule
    // must not depend on that invariant holding, so it reads both.
    expect(hides(showTray: false, minimizeToTrayOnClose: true), isFalse);
  });

  test('mobile platforms never see a hide rule', () {
    expect(hides(platform: TargetPlatform.android), isFalse);
    expect(hides(platform: TargetPlatform.iOS), isFalse);
    expect(hides(platform: TargetPlatform.fuchsia), isFalse);
  });
}
