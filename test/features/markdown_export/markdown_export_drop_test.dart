// A desktop tab is built and laid out even when it is not the one on screen,
// and desktop_drop hands every drop to every registered target without asking
// whether it is visible. The guard is the mount: a hidden tab does not register
// a drop target at all.
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/desktop/desktop_tab.dart';
import 'package:Cuplivo/features/markdown_export/pages/markdown_export_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';

const MethodChannel _channel = MethodChannel('desktop_drop');
const MethodCodec _codec = StandardMethodCodec();

Future<void> _send(String method, Object? arguments) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        _codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );
}

/// Runs [body] as a Windows desktop, which is the shell that keeps every tab
/// built. The override has to be cleared before the test ends — flutter_test
/// checks that no foundation debug variable outlived the test.
Future<void> _onWindows(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  late SettingsProvider settings;

  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });
  tearDown(() => settings.dispose());

  Widget host(Widget child) {
    return ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }

  /// The shell's shape: the chat page first, the tool second, one of them on
  /// screen. Both are laid out at the same rect by `IndexedStack`.
  Widget shell({required bool toolVisible}) {
    return IndexedStack(
      index: toolVisible ? 1 : 0,
      children: [
        const SizedBox.expand(),
        DesktopTabVisibility(
          visible: toolVisible,
          child: const MarkdownExportPage(),
        ),
      ],
    );
  }

  testWidgets('a hidden tab registers no drop target and takes no file', (
    tester,
  ) async {
    await _onWindows(() async {
      await tester.pumpWidget(host(shell(toolVisible: false)));
      await tester.pumpAndSettle();
      // `skipOffstage: false` is the whole point: the shell keeps the hidden
      // tab in the tree, so a finder that skips offstage would prove nothing.
      expect(find.byType(DropTarget, skipOffstage: false), findsNothing);

      // The event that used to reach the hidden tool.
      await _send('entered', <double>[100, 100]);
      await _send('performOperation', <String>['C:/notes.md']);
      await tester.pumpAndSettle();

      final editor = tester.widget<TextField>(
        find.byType(TextField, skipOffstage: false),
      );
      expect(editor.controller!.text, isEmpty);
    });
  });

  testWidgets('the tab on screen does register one', (tester) async {
    await _onWindows(() async {
      await tester.pumpWidget(host(shell(toolVisible: true)));
      await tester.pumpAndSettle();

      expect(find.byType(DropTarget, skipOffstage: false), findsOneWidget);
    });
  });

  testWidgets('switching away removes it, switching back restores it', (
    tester,
  ) async {
    await _onWindows(() async {
      await tester.pumpWidget(host(shell(toolVisible: true)));
      await tester.pumpAndSettle();
      expect(find.byType(DropTarget, skipOffstage: false), findsOneWidget);

      // Rebuilding with the tool hidden is what the shell does on every tab
      // change: the same subtree, a different visibility.
      await tester.pumpWidget(host(shell(toolVisible: false)));
      await tester.pumpAndSettle();
      expect(find.byType(DropTarget, skipOffstage: false), findsNothing);

      await tester.pumpWidget(host(shell(toolVisible: true)));
      await tester.pumpAndSettle();
      expect(find.byType(DropTarget, skipOffstage: false), findsOneWidget);
    });
  });
}
