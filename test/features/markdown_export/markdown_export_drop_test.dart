// A desktop tab is built and laid out even when it is not the one on screen,
// and desktop_drop hands every drop to every registered target without asking
// whether it is visible. Each target therefore asks, per event, whether it is
// the tab being looked at — and it stays mounted, because taking it out of the
// tree would rebuild the page around it on every tab switch.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/desktop/desktop_tab.dart';
import 'package:Cuplivo/features/markdown_export/pages/markdown_export_page.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_drop_target.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_preview.dart';
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

Future<void> _drop(String path) async {
  await _send('entered', <double>[100, 100]);
  await _send('performOperation', <String>[path]);
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

  /// The shell's shape: one page first, the tool second, one of them on screen.
  /// Both are laid out at the same rect by `IndexedStack`.
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

  testWidgets('a hidden tab ignores a drop instead of taking the file', (
    tester,
  ) async {
    await _onWindows(() async {
      await tester.pumpWidget(host(shell(toolVisible: false)));
      await tester.pumpAndSettle();
      // `skipOffstage: false` is the whole point: the shell keeps the hidden
      // tab built, so a finder that skips offstage would prove nothing.
      expect(
        find.byType(MarkdownExportDropTarget, skipOffstage: false),
        findsOneWidget,
      );

      await _drop('C:/notes.md');
      await tester.pumpAndSettle();

      final editor = tester.widget<TextField>(
        find.byType(TextField, skipOffstage: false),
      );
      expect(editor.controller!.text, isEmpty);
    });
  });

  testWidgets('the tab on screen takes the file', (tester) async {
    await _onWindows(() async {
      final dropped = <List<String>>[];
      await tester.pumpWidget(
        host(
          DesktopTabVisibility(
            visible: true,
            child: MarkdownExportDropTarget(
              onPaths: dropped.add,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _drop('C:/notes.md');
      await tester.pumpAndSettle();

      expect(dropped, [
        ['C:/notes.md'],
      ]);
    });
  });

  testWidgets('hiding it afterwards stops the drop, showing it starts again', (
    tester,
  ) async {
    await _onWindows(() async {
      final dropped = <List<String>>[];
      Widget target({required bool visible}) {
        return host(
          DesktopTabVisibility(
            visible: visible,
            child: MarkdownExportDropTarget(
              onPaths: dropped.add,
              child: const SizedBox.expand(),
            ),
          ),
        );
      }

      await tester.pumpWidget(target(visible: true));
      await tester.pumpAndSettle();
      await _drop('C:/first.md');
      await tester.pumpAndSettle();
      expect(dropped, hasLength(1));

      await tester.pumpWidget(target(visible: false));
      await tester.pumpAndSettle();
      await _drop('C:/second.md');
      await tester.pumpAndSettle();
      expect(dropped, hasLength(1), reason: 'a hidden tab must not take it');

      await tester.pumpWidget(target(visible: true));
      await tester.pumpAndSettle();
      await _drop('C:/third.md');
      await tester.pumpAndSettle();
      expect(dropped, hasLength(2));
    });
  });

  testWidgets('a tab keeps its page, and its sheet, while it is hidden', (
    tester,
  ) async {
    await _onWindows(() async {
      await tester.pumpWidget(host(shell(toolVisible: true)));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byType(TextField, skipOffstage: false),
      );
      field.controller!.text = '## kept while hidden';
      await tester.pump(const Duration(milliseconds: 400));
      final sheetBuilds = MarkdownExportPreview.debugSheetBuilds;

      await tester.pumpWidget(host(shell(toolVisible: false)));
      await tester.pumpAndSettle();

      // Hiding a tab must not rebuild the page behind it, and must not tear it
      // down: the editor keeps what was typed and the sheet is not drawn again.
      expect(
        tester
            .widget<TextField>(find.byType(TextField, skipOffstage: false))
            .controller!
            .text,
        '## kept while hidden',
      );
      expect(MarkdownExportPreview.debugSheetBuilds, sheetBuilds);
    });
  });
}
