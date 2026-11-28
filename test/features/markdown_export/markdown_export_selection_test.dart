// The sheet is a document, not a message: it selects and translates the same
// way a message does, except that there is nothing to quote.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show kSecondaryMouseButton, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/selection_quick_toolbar.dart';
import 'package:Cuplivo/features/markdown_export/widgets/markdown_export_preview.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';
import '../../support/markdown_render_helpers.dart';

const _source = '''
# Release notes

The export splits preview from capture, and the preview reflows at the width of
its pane instead of scaling the whole sheet down.
''';

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
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }

  Widget preview() => host(
    const MarkdownExportPreview(
      source: _source,
      maxDocumentWidth: 720,
      emptyHint: 'Nothing to preview yet',
    ),
  );

  Future<void> selectAll(WidgetTester tester) async {
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.keyboard);
    await tester.pumpAndSettle();
  }

  testWidgets('a selection floats only Translate, never Quote', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(preview());
      await tester.pumpAndSettle();
      await selectAll(tester);

      expect(find.byType(SelectionQuickToolbar), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);
      expect(find.text('Quote'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the right-click menu is the message menu without Quote', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(preview());
      await tester.pumpAndSettle();

      final paragraph = renderedParagraphsWith(
        'The export splits preview',
      ).first;
      // A mouse drag, like a reader selecting the paragraph: the region takes
      // focus, which is what a right-click then reopens its menu over.
      final origin = paragraph.localToGlobal(Offset.zero);
      final drag = await tester.startGesture(
        origin + const Offset(2, 2),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(
        origin + Offset(paragraph.size.width - 2, paragraph.size.height - 2),
      );
      await tester.pump();
      await drag.up();
      await drag.removePointer();
      await tester.pumpAndSettle();

      final index = paragraph.text.toPlainText().indexOf('The export');
      final glyph = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: index, extentOffset: index + 1),
          )
          .first
          .toRect();
      final click = paragraph.localToGlobal(glyph.center) + const Offset(2, 0);
      final right = await tester.startGesture(
        click,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await right.removePointer();
      await tester.pumpAndSettle();

      expect(find.text('Copy as Markdown'), findsOneWidget);
      expect(find.text('Copy rich text'), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);
      expect(find.text('Quote'), findsNothing);
      expect(find.text('Select all'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
