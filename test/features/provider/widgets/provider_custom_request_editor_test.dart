import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/provider/widgets/provider_custom_request_editor.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';

void main() {
  testWidgets('adds, edits, and removes provider request rows', (tester) async {
    var headers = <Map<String, String>>[];
    var body = <Map<String, String>>[];

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: ProviderCustomRequestEditor(
                headers: headers,
                body: body,
                onHeadersChanged: (rows) async {
                  setState(() => headers = rows);
                },
                onBodyChanged: (rows) async {
                  setState(() => body = rows);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('provider-custom-header-add')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('provider-custom-header-name-0')),
      'X-Test',
    );
    await tester.enterText(
      find.byKey(const ValueKey('provider-custom-header-value-0')),
      'header-value',
    );
    await tester.pump();

    expect(headers, [
      {'name': 'X-Test', 'value': 'header-value'},
    ]);

    await tester.tap(find.byKey(const ValueKey('provider-custom-body-add')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('provider-custom-body-name-0')),
      'metadata',
    );
    await tester.enterText(
      find.byKey(const ValueKey('provider-custom-body-value-0')),
      '{"source":"provider"}',
    );
    await tester.pump();

    expect(body, [
      {'key': 'metadata', 'value': '{"source":"provider"}'},
    ]);

    await tester.tap(
      find.byKey(const ValueKey('provider-custom-header-delete-0')),
    );
    await tester.pump();
    expect(headers, isEmpty);
  });

  testWidgets('deleting focused rows does not reuse stale controllers', (
    tester,
  ) async {
    var headers = <Map<String, String>>[
      {'name': 'Header-A', 'value': 'value-a'},
      {'name': 'Header-B', 'value': 'value-b'},
    ];
    var body = <Map<String, String>>[
      {'key': 'body-a', 'value': '1'},
      {'key': 'body-b', 'value': '2'},
    ];

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: ProviderCustomRequestEditor(
                headers: headers,
                body: body,
                onHeadersChanged: (rows) async {
                  setState(() => headers = rows);
                },
                onBodyChanged: (rows) async {
                  setState(() => body = rows);
                },
              ),
            ),
          ),
        ),
      ),
    );

    final firstHeaderName = find.byKey(
      const ValueKey('provider-custom-header-name-0'),
    );
    await tester.tap(firstHeaderName);
    await tester.pump();
    expect(
      tester.widget<TextField>(firstHeaderName).focusNode?.hasFocus,
      isTrue,
    );

    tester
        .widget<IosIconButton>(
          find.byKey(const ValueKey('provider-custom-header-delete-0')),
        )
        .onTap!();
    await tester.pump();

    expect(
      tester.widget<TextField>(firstHeaderName).controller?.text,
      'Header-B',
    );
    await tester.enterText(firstHeaderName, 'Header-B-updated');
    await tester.pump();
    expect(headers, [
      {'name': 'Header-B-updated', 'value': 'value-b'},
    ]);

    final firstBodyName = find.byKey(
      const ValueKey('provider-custom-body-name-0'),
    );
    await tester.tap(firstBodyName);
    await tester.pump();
    expect(tester.widget<TextField>(firstBodyName).focusNode?.hasFocus, isTrue);

    tester
        .widget<IosIconButton>(
          find.byKey(const ValueKey('provider-custom-body-delete-0')),
        )
        .onTap!();
    await tester.pump();

    expect(tester.widget<TextField>(firstBodyName).controller?.text, 'body-b');
    await tester.enterText(firstBodyName, 'body-b-updated');
    await tester.pump();
    expect(body, [
      {'key': 'body-b-updated', 'value': '2'},
    ]);
  });
}
