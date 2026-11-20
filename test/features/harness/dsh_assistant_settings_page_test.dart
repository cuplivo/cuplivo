import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/features/harness/pages/assistant/dsh_assistant_settings_page.dart';
import 'package:Cuplivo/features/harness/pages/assistant/dsh_settings_tab_bodies.dart';
import 'package:Cuplivo/features/harness/pages/assistant/dsh_settings_tabs.dart';
import 'package:Cuplivo/features/harness/services/dsh_credential_store.dart';
import 'package:Cuplivo/features/harness/services/dsh_remote_store.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_settings_tab_strip.dart';
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
    expect(
      find.byKey(const ValueKey<String>('dsh-settings-tab-connection')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dsh-settings-tab-general')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dsh-connect-name')), findsOneWidget);
    expect(find.byKey(const Key('dsh-connect-url')), findsOneWidget);
    expect(find.byKey(const Key('dsh-connect-confirm')), findsOneWidget);
    expect(find.text('DeepSeek Harness'), findsWidgets);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    // The invented 内容 tab is gone; the Host plugin tabs only appear once the
    // catalog is connected, so create mode has neither.
    expect(find.text('Content'), findsNothing);
    expect(find.text('Built-in plugins'), findsNothing);
    expect(find.text('Agent presets'), findsNothing);
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

  Widget localizedHost(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  testWidgets('the strip renders exactly the specs it is given', (
    tester,
  ) async {
    var changed = '';
    await tester.pumpWidget(
      localizedHost(
        DshSettingsTabStrip(
          specs: [
            DshSettingsTabSpec(
              id: 'alpha',
              label: 'Alpha',
              body: (_) => const SizedBox.shrink(),
            ),
            DshSettingsTabSpec(
              id: 'beta',
              label: 'Beta',
              key: const Key('beta-tab'),
              body: (_) => const SizedBox.shrink(),
            ),
          ],
          activeId: 'alpha',
          onChanged: (id) => changed = id,
        ),
      ),
    );

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Content'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('dsh-settings-tab-alpha')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('beta-tab')));
    await tester.pumpAndSettle();
    expect(changed, 'beta');
  });

  testWidgets('the plugins body lists rows and the read-only note', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedHost(
        const DshPluginsTabBody(
          plugins: [
            DshPluginEntry(
              id: 'tools',
              title: 'Harness Tools',
              moduleName: '@dsh/tools',
              enabled: true,
              phase: 'active',
              diagnostic: 'needs attention',
            ),
          ],
        ),
      ),
    );

    expect(find.text('Harness Tools'), findsOneWidget);
    expect(find.text('@dsh/tools'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.textContaining('Phase: active'), findsOneWidget);
    expect(find.textContaining('needs attention'), findsOneWidget);
    expect(
      find.textContaining('Plugins are managed by the remote'),
      findsOneWidget,
    );
  });

  testWidgets('the plugins body has an honest empty state', (tester) async {
    await tester.pumpWidget(
      localizedHost(const DshPluginsTabBody(plugins: [])),
    );
    expect(find.text('This Host reports no built-in plugins.'), findsOneWidget);
  });

  testWidgets('the agent presets body lists groups read-only', (tester) async {
    await tester.pumpWidget(
      localizedHost(
        const DshAgentPresetsTabBody(
          groups: [
            DshAgentPresetGroup(
              id: 'standard',
              name: 'Standard',
              isDefault: true,
              plugins: [
                DshAgentPresetPlugin(
                  moduleName: '@dsh/tools',
                  title: 'Toolbox',
                ),
              ],
            ),
          ],
        ),
      ),
    );

    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Toolbox'), findsOneWidget);
    expect(
      find.textContaining('Agent presets are owned by the remote'),
      findsOneWidget,
    );
  });

  testWidgets('the agent presets body has an honest empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedHost(const DshAgentPresetsTabBody(groups: [])),
    );
    expect(find.text('This Host reports no Agent presets.'), findsOneWidget);
  });
}
