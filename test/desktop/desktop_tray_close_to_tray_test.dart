// The close-to-tray decision, through the real controller rather than the pure
// rule: which close hides, which one quits, and — the half #1036 got wrong —
// that a hide leaves the close-to-tray gate alone while a quit always clears it.
//
// The gate is `preventClose`. Answering an exit request with `exit` makes the
// engine re-dispatch the OS close, and window_manager consumes that message
// while `preventClose` is set: a quit that forgot to clear it would leave the
// process up with its writes flushed and its shutdown already run. That is only
// observable at the channel, so this file mocks `window_manager` the way
// `desktop_window_controller_test.dart` already does.

import 'package:Cuplivo/core/services/app_exit_flush.dart';
import 'package:Cuplivo/desktop/desktop_tray_controller.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  bool failHide = false;

  late AppLocalizations l10n;
  late DesktopTrayController controller;

  setUp(() async {
    calls.clear();
    failHide = false;
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    controller = DesktopTrayController.instance..debugReset();
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call);
      if (call.method == 'hide' && failHide) {
        throw PlatformException(code: 'window_gone');
      }
      return switch (call.method) {
        'isPreventClose' => true,
        _ => true,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(windowChannel, null);
    debugDefaultTargetPlatformOverride = null;
    AppExitFlush.debugReset();
    AppShutdown.debugReset();
    controller.debugReset();
  });

  /// Puts the controller in the given close-to-tray state and forgets the calls
  /// that state itself made, so an assertion only sees the tested decision.
  Future<void> configure({required bool minimizeToTrayOnClose}) async {
    await controller.syncFromSettings(
      l10n,
      showTray: true,
      minimizeToTrayOnClose: minimizeToTrayOnClose,
    );
    calls.clear();
  }

  List<String> methods() => [for (final call in calls) call.method];

  /// Every `setPreventClose` argument, so "the gate was cleared" and "the gate
  /// was left alone" are the same assertion shape.
  List<Object?> preventCloseArgs() => [
    for (final call in calls)
      if (call.method == 'setPreventClose') call.arguments,
  ];

  test('a close that hides hides and leaves the gate alone', () async {
    await configure(minimizeToTrayOnClose: true);

    expect(await controller.hideForExitRequest(), isTrue);

    expect(methods(), contains('hide'));
    expect(
      preventCloseArgs(),
      isEmpty,
      reason: 'the app keeps running, so the close-to-tray gate must stay set',
    );
  });

  test('a close that quits clears the gate and reports a quit', () async {
    await configure(minimizeToTrayOnClose: false);

    expect(await controller.hideForExitRequest(), isFalse);

    expect(methods(), isNot(contains('hide')));
    expect(
      preventCloseArgs(),
      <Object?>[
        <String, Object?>{'isPreventClose': false},
      ],
      reason: 'without this the engine re-dispatches a close nobody lets land',
    );
  });

  test('a hide that fails still lets the quit land', () async {
    await configure(minimizeToTrayOnClose: true);
    failHide = true;

    expect(await controller.hideForExitRequest(), isFalse);

    expect(methods(), contains('hide'));
    expect(preventCloseArgs(), <Object?>[
      <String, Object?>{'isPreventClose': false},
    ], reason: 'a close button that cannot hide must not become a dead button');
  });

  test(
    'macOS exit requests are quits: its red button never arrives here',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await configure(minimizeToTrayOnClose: true);

      expect(await controller.hideForExitRequest(), isFalse);
      expect(methods(), isNot(contains('hide')));
      expect(preventCloseArgs(), <Object?>[
        <String, Object?>{'isPreventClose': false},
      ]);
    },
  );

  test('the tray Exit item clears the gate before closing', () async {
    await configure(minimizeToTrayOnClose: true);
    var shutdowns = 0;
    AppShutdown.register(() async => shutdowns++);

    await controller.exitApp();

    expect(
      shutdowns,
      1,
      reason: 'the tray exit is the place process-owned resources are given up',
    );
    expect(
      methods(),
      containsAllInOrder(<String>['setPreventClose', 'close']),
      reason: 'the close this asks for is the quit the user asked for',
    );
    expect(
      calls.firstWhere((call) => call.method == 'setPreventClose').arguments,
      <String, Object?>{'isPreventClose': false},
    );
  });
}
