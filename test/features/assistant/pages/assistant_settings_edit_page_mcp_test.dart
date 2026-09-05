import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/memory_provider.dart';
import 'package:Cuplivo/core/providers/quick_phrase_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/features/home/services/local_tools_service.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

const _assistantId = 'assistant-mcp-test';

void _seedPreferences() {
  SharedPreferences.setMockInitialValues({
    'assistants_v1': Assistant.encodeList([
      Assistant(id: _assistantId, name: 'Test Assistant', temperature: 0.6),
    ]),
  });
  businessPrefs = BusinessPreferences.memoryForTests();
}

Future<AssistantProvider> _createAssistantProvider({
  required BusinessPreferences preferences,
}) async {
  final provider = AssistantProvider(preferences: businessPrefs);
  await provider.loadFromPrefs();
  return provider;
}

Widget _buildHarness({
  required AssistantProvider assistantProvider,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider.value(value: assistantProvider),
      ChangeNotifierProvider(
        create: (_) => MemoryProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(
        create: (_) => QuickPhraseProvider(preferences: businessPrefs),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('assistant edit page shows MCP tab on mobile', (tester) async {
    _seedPreferences();
    final assistantProvider = await _createAssistantProvider(
      preferences: businessPrefs,
    );

    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: assistantProvider,
        child: const AssistantSettingsEditPage(assistantId: _assistantId),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('MCP'), findsOneWidget);
  });

  testWidgets('assistant local tools page uses clock icon for time info', (
    tester,
  ) async {
    _seedPreferences();
    final assistantProvider = await _createAssistantProvider(
      preferences: businessPrefs,
    );

    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: assistantProvider,
        child: const AssistantSettingsEditPage(assistantId: _assistantId),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Local Tools'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Time Info'), findsOneWidget);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(AssistantSettingsEditPage)),
    )!;
    expect(find.text(l10n.workspaceDefaultDirectoryTitle), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Icon && widget.icon == Lucide.clock,
      ),
      findsOneWidget,
    );
    // flutter_test defaults defaultTargetPlatform to Android, so the
    // device-backed local tool rows (screen time + calendar) are present.
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Icon && widget.icon == Lucide.Calendar,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Icon && widget.icon == Lucide.CalendarPlus,
      ),
      findsOneWidget,
    );
  });

  testWidgets('local tools tab hides device tools on desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    _seedPreferences();
    final assistantProvider = await _createAssistantProvider(
      preferences: businessPrefs,
    );

    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: assistantProvider,
        child: const AssistantSettingsEditPage(assistantId: _assistantId),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Local Tools'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Time Info'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Icon && widget.icon == Lucide.Calendar,
      ),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Icon && widget.icon == Lucide.Smartphone,
      ),
      findsNothing,
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('assistant local tools page lists handoff tools', (tester) async {
    _seedPreferences();
    final assistantProvider = await _createAssistantProvider(
      preferences: businessPrefs,
    );

    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: assistantProvider,
        child: const AssistantSettingsEditPage(assistantId: _assistantId),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Local Tools'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Sub-agent Delegation'), findsOneWidget);
    // The status row only renders once the handoff tool is enabled.
    // Initially disabled: the seed assistant has no local tool ids. Enable it
    // through the provider (the toggle row itself sits below the 600px test
    // window in this tab).
    final seeded = assistantProvider.getById(_assistantId)!;
    await assistantProvider.updateAssistant(
      seeded.copyWith(
        localToolIds: [...seeded.localToolIds, LocalToolNames.handoff],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No sub-agent targets available'), findsOneWidget);
  });

  testWidgets('assistant desktop dialog shows MCP menu item', (tester) async {
    _seedPreferences();
    final assistantProvider = await _createAssistantProvider(
      preferences: businessPrefs,
    );

    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: assistantProvider,
        child: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () => showAssistantDesktopDialog(
                  context,
                  assistantId: _assistantId,
                ),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('MCP'), findsOneWidget);
  });
}
