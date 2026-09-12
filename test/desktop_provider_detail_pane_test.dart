import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/codex_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/desktop/desktop_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/codex_account_entry.dart';
import 'package:Cuplivo/shared/widgets/ios_checkbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ProviderConfig _providerConfig(String id) {
  return ProviderConfig(
    id: id,
    enabled: true,
    name: id,
    apiKey: 'test-key',
    baseUrl: 'https://example.test/v1',
    providerType: ProviderKind.openai,
    chatPath: '/chat/completions',
    models: const ['same-model'],
    proxyEnabled: true,
    proxyType: 'http',
    proxyHost: '127.0.0.1',
    proxyPort: '',
    proxyUsername: '',
    proxyPassword: '',
  );
}

Widget _harness(
  SettingsProvider settings, {
  required String initialProviderKey,
  CodexDeviceCodeController? controller,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AssistantProvider>(
        create: (_) => AssistantProvider(preferences: businessPrefs),
      ),
      if (controller != null)
        ChangeNotifierProvider<CodexDeviceCodeController>.value(
          value: controller,
        ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DesktopSettingsPage(initialProviderKey: initialProviderKey),
      ),
    ),
  );
}

Future<SettingsProvider> _buildSettings(WidgetTester tester) async {
  businessPrefs = BusinessPreferences.memoryForTests(const {});
  final settings = SettingsProvider(preferences: businessPrefs);
  await tester.runAsync(_waitForSettingsLoad);
  await settings.setProviderConfig('ProviderA', _providerConfig('ProviderA'));
  await settings.setProviderConfig('ProviderB', _providerConfig('ProviderB'));
  await settings.setProvidersOrder(const ['ProviderA', 'ProviderB']);
  return settings;
}

Future<void> _pumpProviderSettings(
  WidgetTester tester,
  SettingsProvider settings,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_harness(settings, initialProviderKey: 'ProviderA'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop model selection state is cleared when provider changes',
    (tester) async {
      final settings = await _buildSettings(tester);
      addTearDown(settings.dispose);

      await _pumpProviderSettings(tester, settings);

      await tester.tap(find.byTooltip('Multi-select').first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('same-model').last);
      await tester.pump(const Duration(milliseconds: 300));

      final selectedCheckbox = tester.widget<IosCheckbox>(
        find.byType(IosCheckbox).last,
      );
      expect(selectedCheckbox.value, isTrue);

      await tester.tap(find.text('ProviderB').first);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(IosCheckbox), findsNothing);
    },
  );

  testWidgets('desktop provider proxy port input preserves typed order', (
    tester,
  ) async {
    final settings = await _buildSettings(tester);
    addTearDown(settings.dispose);

    await _pumpProviderSettings(tester, settings);

    await tester.tap(
      find.byKey(const ValueKey('desktop-provider-settings-ProviderA')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('desktop-provider-settings-dialog')),
      findsOneWidget,
    );

    final portField = find.byKey(
      const ValueKey('desktop-provider-proxy-port-field'),
    );
    await tester.ensureVisible(portField);
    await tester.pumpAndSettle();
    await tester.tap(portField);
    await tester.pump();
    await tester.enterText(portField, '1');
    await tester.pump();

    var fieldWidget = tester.widget<TextField>(portField);
    expect(fieldWidget.controller?.selection.baseOffset, 1);

    await tester.enterText(portField, '12345');
    await tester.pump(const Duration(milliseconds: 300));

    expect(settings.getProviderConfig('ProviderA').proxyPort, '12345');

    fieldWidget = tester.widget<TextField>(portField);
    expect(fieldWidget.controller?.text, '12345');
  });

  testWidgets('desktop LobeHub icon dialog uses provider settings flow', (
    tester,
  ) async {
    final settings = await _buildSettings(tester);
    addTearDown(settings.dispose);

    await _pumpProviderSettings(tester, settings);

    await tester.tap(
      find.byKey(const ValueKey('desktop-provider-settings-ProviderA')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('desktop-provider-settings-dialog')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('desktop-provider-settings-avatar-ProviderA')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter LobeHub Icon'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('desktop-provider-lobehub-icon-dialog')),
      findsOneWidget,
    );

    final iconField = find.byKey(
      const ValueKey('desktop-provider-lobehub-icon-field'),
    );
    await tester.enterText(iconField, 'openai');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final cfg = settings.getProviderConfig('ProviderA');
    expect(cfg.avatarType, 'lobehub');
    expect(cfg.avatarValue, 'openai');
  });

  testWidgets('desktop custom request section toggles on tap', (tester) async {
    final settings = await _buildSettings(tester);
    addTearDown(settings.dispose);

    await _pumpProviderSettings(tester, settings);

    await tester.tap(
      find.byKey(const ValueKey('desktop-provider-settings-ProviderA')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    final crossfade = find.byKey(
      const ValueKey('desktop-provider-custom-request-crossfade'),
    );
    final header = find.text('Custom Request');
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();

    expect(
      tester.widget<AnimatedCrossFade>(crossfade).crossFadeState,
      CrossFadeState.showFirst,
    );

    await tester.tap(header);
    await tester.pumpAndSettle();

    expect(
      tester.widget<AnimatedCrossFade>(crossfade).crossFadeState,
      CrossFadeState.showSecond,
    );

    await tester.tap(header);
    await tester.pumpAndSettle();

    expect(
      tester.widget<AnimatedCrossFade>(crossfade).crossFadeState,
      CrossFadeState.showFirst,
    );
  });

  testWidgets('desktop balance query spinner clears after request settles', (
    tester,
  ) async {
    businessPrefs = BusinessPreferences.memoryForTests(const {});
    final settings = SettingsProvider(preferences: businessPrefs);
    await tester.runAsync(_waitForSettingsLoad);
    await settings.setProviderConfig(
      'ProviderA',
      ProviderConfig(
        id: 'ProviderA',
        enabled: true,
        name: 'ProviderA',
        apiKey: 'test-key',
        baseUrl: 'https://example.test/v1',
        providerType: ProviderKind.openai,
        balanceEnabled: true,
        balanceApiPath: '/credits',
        balanceResultPath: 'data.total',
      ),
    );
    await settings.setProvidersOrder(const ['ProviderA']);
    addTearDown(settings.dispose);

    await _pumpProviderSettings(tester, settings);

    await tester.tap(
      find.byKey(const ValueKey('desktop-provider-settings-ProviderA')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    final queryButton = find.byKey(
      const ValueKey('desktop-provider-balance-query-button'),
    );
    await tester.ensureVisible(queryButton);
    await tester.pumpAndSettle();

    String queryButtonTooltip() {
      return tester
          .widget<Tooltip>(
            find.descendant(of: queryButton, matching: find.byType(Tooltip)),
          )
          .message!;
    }

    expect(queryButtonTooltip(), 'Check Balance');

    await tester.tap(queryButton);
    await tester.pump();

    expect(queryButtonTooltip(), 'Checking...');

    await tester.pumpAndSettle();

    expect(queryButtonTooltip(), 'Check Balance');

    // Let the error snackbar auto-dismiss so no timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  group('desktop providers pane codex gate', () {
    Future<SettingsProvider> buildSettings(
      WidgetTester tester, {
      required String key,
      required ProviderConfig cfg,
    }) async {
      businessPrefs = BusinessPreferences.memoryForTests(const {});
      final settings = SettingsProvider(preferences: businessPrefs);
      await tester.runAsync(_waitForSettingsLoad);
      await settings.setProviderConfig(key, cfg);
      await settings.setProvidersOrder([key]);
      return settings;
    }

    Future<void> pumpProvider(
      WidgetTester tester,
      SettingsProvider settings,
      String key,
    ) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = CodexDeviceCodeController();
      addTearDown(controller.resetForTest);
      await tester.pumpWidget(
        _harness(settings, initialProviderKey: key, controller: controller),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }

    ProviderConfig openAiConfig(
      String id, {
      bool multiKey = false,
      String? baseUrl,
    }) => ProviderConfig(
      id: id,
      enabled: true,
      name: id,
      apiKey: 'test-key',
      baseUrl: baseUrl ?? 'https://api.openai.com/v1',
      providerType: ProviderKind.openai,
      models: const ['gpt-4o'],
      multiKeyEnabled: multiKey,
    );

    testWidgets('built-in OpenAI shows the Codex account entry', (
      tester,
    ) async {
      final settings = await buildSettings(
        tester,
        key: 'OpenAI',
        cfg: openAiConfig('OpenAI'),
      );
      addTearDown(settings.dispose);

      await pumpProvider(tester, settings, 'OpenAI');

      expect(
        find.byType(CodexAccountEntry, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('multiKey OpenAI hides the Codex account entry', (
      tester,
    ) async {
      final settings = await buildSettings(
        tester,
        key: 'OpenAI',
        cfg: openAiConfig('OpenAI', multiKey: true),
      );
      addTearDown(settings.dispose);

      await pumpProvider(tester, settings, 'OpenAI');

      expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-openai provider hides the Codex account entry', (
      tester,
    ) async {
      final settings = await buildSettings(
        tester,
        key: 'Claude',
        cfg: ProviderConfig(
          id: 'Claude',
          enabled: true,
          name: 'Claude',
          apiKey: 'test-key',
          baseUrl: 'https://api.anthropic.com/v1',
          providerType: ProviderKind.claude,
          models: const ['claude-opus-4'],
        ),
      );
      addTearDown(settings.dispose);

      await pumpProvider(tester, settings, 'Claude');

      expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('custom openai provider on a codex host shows the entry', (
      tester,
    ) async {
      final settings = await buildSettings(
        tester,
        key: 'MyCodex',
        cfg: openAiConfig('MyCodex', baseUrl: kCodexBaseUrl),
      );
      addTearDown(settings.dispose);

      await pumpProvider(tester, settings, 'MyCodex');

      // A user-added openai provider pointed at the codex host is treated
      // like the built-in codex provider.
      expect(
        find.byType(CodexAccountEntry, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('custom openai provider on a non-codex host hides the entry', (
      tester,
    ) async {
      final settings = await buildSettings(
        tester,
        key: 'MyProxy',
        cfg: openAiConfig('MyProxy', baseUrl: 'https://myproxy.example.com/v1'),
      );
      addTearDown(settings.dispose);

      await pumpProvider(tester, settings, 'MyProxy');

      expect(find.byType(CodexAccountEntry, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
