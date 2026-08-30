import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/widgets/chat_selection_action_bar.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:provider/provider.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<void> _pumpBar(WidgetTester tester, Widget child) async {
  businessPrefs = BusinessPreferences.memoryForTests({});
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(preferences: businessPrefs),
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(width: 420, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('统一动作台展示导出四格和删除格', (tester) async {
    var markdownDeletes = 0;
    var txtDeletes = 0;
    var imageDeletes = 0;
    var pdfDeletes = 0;
    var deleteTaps = 0;

    await _pumpBar(
      tester,
      ChatSelectionActionBar(
        onExportMarkdown: () => markdownDeletes++,
        onExportTxt: () => txtDeletes++,
        onExportImage: () => imageDeletes++,
        onExportPdf: () => pdfDeletes++,
        onDelete: () => deleteTaps++,
        showThinkingTools: false,
        showThinkingContent: false,
        onToggleThinkingTools: () {},
        onToggleThinkingContent: () {},
      ),
    );

    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('MD'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('TXT'));
    await tester.tap(find.text('MD'));
    await tester.tap(find.text('PDF'));
    await tester.tap(find.text('Image'));
    await tester.tap(find.text('Delete'));

    expect(markdownDeletes, 1);
    expect(txtDeletes, 1);
    expect(imageDeletes, 1);
    expect(pdfDeletes, 1);
    expect(deleteTaps, 1);
  });

  testWidgets('thinking 开关独立作用于导出选项', (tester) async {
    var tools = false;
    var content = false;

    await _pumpBar(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ChatSelectionActionBar(
          onExportMarkdown: () {},
          onExportTxt: () {},
          onExportImage: () {},
          onExportPdf: () {},
          onDelete: () {},
          showThinkingTools: tools,
          showThinkingContent: content,
          onToggleThinkingTools: () => setState(() => tools = !tools),
          onToggleThinkingContent: () => setState(() => content = !content),
        ),
      ),
    );

    expect(find.text('Thinking tools'), findsOneWidget);
    expect(find.text('Thinking content'), findsOneWidget);

    await tester.tap(find.text('Thinking tools'));
    await tester.pumpAndSettle();
    expect(tools, isTrue);

    await tester.tap(find.text('Thinking content'));
    await tester.pumpAndSettle();
    expect(content, isTrue);
  });
}
