import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/features/harness/pages/assistant/dsh_assistant_settings_page.dart';
import 'package:Cuplivo/features/harness/services/dsh_credential_store.dart';
import 'package:Cuplivo/features/harness/services/dsh_remote_store.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';

class _MemoryCredentials implements DshCredentialStore {
  @override
  Future<void> deleteCookie(String remoteId) async {}

  @override
  Future<String?> readCookie(String remoteId) async => null;

  @override
  Future<void> writeCookie(String remoteId, String cookie) async {}
}

/// The create-mode assistant page is the end of the create flow: it validates
/// locally, persists the record and hands the one-shot launch token to the
/// provider. No adapter is wired in this test, which is exactly the foundation
/// state, so the last step must fail inline instead of navigating away.
void main() {
  Future<DshConnectionsProvider> pumpPage(WidgetTester tester) async {
    final provider = DshConnectionsProvider(
      store: DshRemoteStore(createBusinessTestPreferences()),
      credentials: _MemoryCredentials(),
    );
    await provider.loaded;
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<DshConnectionsProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DshAssistantSettingsPage.create(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  Finder field(String key) => find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(EditableText),
  );

  testWidgets('the create page carries the tabs and the E2E hook keys', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('dsh-settings-tabs')), findsOneWidget);
    expect(find.byKey(const Key('dsh-models-tab')), findsOneWidget);
    expect(find.byKey(const Key('dsh-connect-name')), findsOneWidget);
    expect(find.byKey(const Key('dsh-connect-url')), findsOneWidget);
    expect(find.byKey(const Key('dsh-connect-confirm')), findsOneWidget);
    expect(find.text('DeepSeek Harness'), findsWidgets);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Content'), findsOneWidget);
  });

  testWidgets('an empty name fails locally without creating a record', (
    tester,
  ) async {
    final provider = await pumpPage(tester);
    await tester.enterText(field('dsh-connect-name'), '');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('dsh-connect-confirm')));
    await tester.tap(find.byKey(const Key('dsh-connect-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Enter an assistant name.'), findsOneWidget);
    expect(provider.remotes, isEmpty);
  });

  testWidgets('an unparsable WebUI link fails locally', (tester) async {
    final provider = await pumpPage(tester);
    await tester.enterText(field('dsh-connect-name'), 'Studio');
    await tester.enterText(field('dsh-connect-url'), 'http://host:3080/proxy');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('dsh-connect-confirm')));
    await tester.tap(find.byKey(const Key('dsh-connect-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'That link is not valid. Paste the WebUI link printed by DeepSeek Harness.',
      ),
      findsOneWidget,
    );
    expect(provider.remotes, isEmpty);
  });

  testWidgets(
    'a valid link creates the record, then reports the missing adapter inline',
    (tester) async {
      final provider = await pumpPage(tester);
      await tester.enterText(field('dsh-connect-name'), 'Studio');
      await tester.enterText(
        field('dsh-connect-url'),
        'dsh web: http://127.0.0.1:3080/?token=launch',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('dsh-connect-confirm')));
      await tester.tap(find.byKey(const Key('dsh-connect-confirm')));
      await tester.pumpAndSettle();

      expect(provider.remotes, hasLength(1));
      expect(provider.remotes.single.name, 'Studio');
      expect(
        find.text(
          'The DeepSeek Harness client is not wired up yet, so connecting is unavailable.',
        ),
        findsOneWidget,
      );
    },
  );
}
