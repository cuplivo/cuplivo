import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/widgets/chat_selection_delete_dialog.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

class _DialogHarness extends StatefulWidget {
  const _DialogHarness({
    required this.count,
    required this.hasMultiVersionSelection,
  });

  final int count;
  final bool hasMultiVersionSelection;

  @override
  State<_DialogHarness> createState() => _DialogHarnessState();
}

class _DialogHarnessState extends State<_DialogHarness> {
  String? resultBanner;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final result = await showChatSelectionDeleteDialog(
          context,
          count: widget.count,
          hasMultiVersionSelection: widget.hasMultiVersionSelection,
        );
        if (!mounted) return;
        setState(
          () => resultBanner = result == null
              ? 'null'
              : result
              ? 'true'
              : 'false',
        );
      },
      child: Text(resultBanner ?? 'open'),
    );
  }
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  required int count,
  required bool hasMultiVersionSelection,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) {
              return AppLocalizations.of(context) == null
                  ? const Text('no-l10n')
                  : _DialogHarness(
                      count: count,
                      hasMultiVersionSelection: hasMultiVersionSelection,
                    );
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('单版本选择确认删除本版本', (tester) async {
    await _pumpDialog(tester, count: 2, hasMultiVersionSelection: false);

    expect(find.text('Delete Selected'), findsOneWidget);
    expect(find.text('false'), findsNothing);
    expect(
      find.text('Delete 2 selected version(s)? This cannot be undone.'),
      findsOneWidget,
    );
    expect(find.text('Delete This Version'), findsNothing);
    expect(find.text('Delete All Versions'), findsNothing);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Selected'), findsNothing);
    expect(find.text('false'), findsOneWidget);
  });

  testWidgets('多版本选择默认删除本版本，警告文案为本版本', (tester) async {
    await _pumpDialog(tester, count: 1, hasMultiVersionSelection: true);

    expect(
      find.text('Delete 1 selected version(s)? This cannot be undone.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Delete all versions of 1 selected message(s)? This cannot be undone.',
      ),
      findsNothing,
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Selected'), findsNothing);
    expect(find.text('false'), findsOneWidget);
  });

  testWidgets('多版本选择切换到全部版本后确认删除全部版本', (tester) async {
    await _pumpDialog(tester, count: 1, hasMultiVersionSelection: true);

    expect(
      find.text(
        'Delete all versions of 1 selected message(s)? This cannot be undone.',
      ),
      findsNothing,
    );

    await tester.tap(find.text('Delete All Versions'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Delete all versions of 1 selected message(s)? This cannot be undone.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Selected'), findsNothing);
    expect(find.text('true'), findsOneWidget);
  });

  testWidgets('取消返回 null', (tester) async {
    await _pumpDialog(tester, count: 1, hasMultiVersionSelection: true);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Selected'), findsNothing);
    expect(find.text('null'), findsOneWidget);
  });
}
