import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:Cuplivo/features/sync/widgets/sync_endpoint_detail.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The address form's contract with the store: a port the store will save, or
/// the form stays open.
///
/// The store refuses `port <= 0` ([SyncEndpointAdd.invalid]) — and the field has
/// no input formatter, so a desktop keyboard types `0`, `-1` and `70000` freely.
/// The dialog used to pop on anything `int.tryParse` accepted, which closed the
/// sheet on an address whose write then silently never happened: the enum's
/// `invalid` reaches the user as nothing at all.
void main() {
  ({String host, int port})? saved;

  Future<void> pumpForm(
    WidgetTester tester, {
    SyncPeerEndpoint? endpoint,
  }) async {
    saved = null;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await showSyncEndpointAddressDialog(
                  context: context,
                  endpoint: endpoint,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  Future<void> submit(WidgetTester tester, String host, String port) async {
    await tester.enterText(find.byType(TextField).at(0), host);
    await tester.enterText(find.byType(TextField).at(1), port);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
  }

  testWidgets('a number that is not a port keeps the form open', (
    tester,
  ) async {
    await pumpForm(tester);
    for (final port in ['0', '-1', '70000']) {
      await submit(tester, '192.168.1.10', port);
      expect(find.byType(AlertDialog), findsOneWidget, reason: port);
      expect(saved, isNull, reason: port);
    }
    // Only an explicit cancel closes it, and it closes with nothing saved.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(saved, isNull);
  });

  testWidgets('a port the store accepts closes the form with it', (
    tester,
  ) async {
    await pumpForm(tester);
    await submit(tester, '192.168.1.10', '65535');
    expect(find.byType(AlertDialog), findsNothing);
    expect(saved, (host: '192.168.1.10', port: 65535));

    await pumpForm(tester);
    await submit(tester, '192.168.1.11', '1');
    expect(saved, (host: '192.168.1.11', port: 1));
  });

  testWidgets('the edit form starts from the address it is repairing', (
    tester,
  ) async {
    await pumpForm(
      tester,
      endpoint: SyncPeerEndpoint(host: '192.168.1.7', port: 9527),
    );
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields[0].controller?.text, '192.168.1.7');
    expect(fields[1].controller?.text, '9527');
  });
}
