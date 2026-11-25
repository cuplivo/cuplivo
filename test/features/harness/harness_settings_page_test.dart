import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/harness_tailcat_endpoint.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/harness_connection_provider.dart';
import 'package:Cuplivo/core/services/harness/harness_connection_probe.dart';
import 'package:Cuplivo/features/harness/pages/harness_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

import '../../support/business_test_harness.dart';

const String _storedUrl = 'https://dsh.example.com/?token=abc';
const String _storedTailcatAddress =
    'tcAPpXUQeEXAMPLEaddressEXAMPLEaddressEXAMPLEaddressEXAMPLE00';

/// A loaded-assistant view without the Drift-backed store.
///
/// The page needs real [AssistantProvider] behavior (rows, updates, deletes),
/// but a widget test of a settings form must not wait on a database write
/// finishing inside the fake-async zone. The overridden write methods complete
/// synchronously and keep the same contract the page relies on.
class _InMemoryAssistantProvider extends AssistantProvider {
  _InMemoryAssistantProvider({required super.preferences});

  final List<Assistant> _rows = <Assistant>[];

  @override
  List<Assistant> get assistants => List<Assistant>.unmodifiable(_rows);

  @override
  List<Assistant> get chatAssistants => List<Assistant>.unmodifiable(
    _rows.where((assistant) => !assistant.isDeepSeekHarness),
  );

  @override
  Assistant? getById(String id) {
    for (final row in _rows) {
      if (row.id == id) return row;
    }
    return null;
  }

  @override
  Future<String> addHarnessAssistant({required String name}) async {
    final id = 'harness-${_rows.length}';
    _rows.add(Assistant.harness(id: id, name: name));
    notifyListeners();
    return id;
  }

  @override
  Future<void> updateAssistant(Assistant updated) async {
    final index = _rows.indexWhere((assistant) => assistant.id == updated.id);
    if (index == -1) return;
    _rows[index] = updated;
    notifyListeners();
  }

  @override
  Future<bool> deleteAssistant(String id) async {
    final index = _rows.indexWhere((assistant) => assistant.id == id);
    if (index == -1) return false;
    _rows.removeAt(index);
    notifyListeners();
    return true;
  }
}

/// Proves links on demand: no network, and each [check] records the candidate
/// the page asked about plus the resulting phase.
class _StubHarnessConnections extends HarnessConnectionProvider {
  _StubHarnessConnections({required super.assistants});

  HarnessConnectionResult result = const HarnessConnectionResult.connected();
  final List<Assistant> checked = <Assistant>[];
  final List<String> resets = <String>[];
  final Map<String, HarnessConnectionPhase> _phases =
      <String, HarnessConnectionPhase>{};

  @override
  HarnessConnectionPhase phaseOf(String assistantId) =>
      _phases[assistantId] ?? HarnessConnectionPhase.unknown;

  @override
  Future<HarnessConnectionResult> check(Assistant assistant) async {
    checked.add(assistant);
    _phases[assistant.id] = result.isConnected
        ? HarnessConnectionPhase.connected
        : HarnessConnectionPhase.failed;
    notifyListeners();
    return result;
  }

  @override
  void reset(String assistantId) {
    resets.add(assistantId);
    if (_phases.remove(assistantId) != null) notifyListeners();
  }

  @override
  void ensureChecked(Iterable<Assistant> assistants) {}
}

Future<
  ({
    _InMemoryAssistantProvider assistants,
    _StubHarnessConnections connections,
    String id,
  })
>
_seedHarness(
  WidgetTester tester, {
  String? storedUrl,
  String? storedTailcatAddress,
  int storedTailcatPort = kHarnessTailcatDefaultPort,
}) async {
  late _InMemoryAssistantProvider assistants;
  late _StubHarnessConnections connections;
  late String id;
  await tester.runAsync(() async {
    assistants = _InMemoryAssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await assistants.loaded;
    id = await assistants.addHarnessAssistant(name: 'DeepSeek Harness');
    if (storedUrl != null) {
      await assistants.updateAssistant(
        assistants.getById(id)!.copyWith(harnessUrl: storedUrl),
      );
    }
    if (storedTailcatAddress != null) {
      await assistants.updateAssistant(
        assistants
            .getById(id)!
            .copyWith(
              harnessConnectionMode: HarnessConnectionMode.tailcat,
              harnessTailcatAddress: storedTailcatAddress,
              harnessTailcatPort: storedTailcatPort,
            ),
      );
    }
    connections = _StubHarnessConnections(assistants: assistants);
  });
  return (assistants: assistants, connections: connections, id: id);
}

Future<AppLocalizations> _pumpPage(
  WidgetTester tester, {
  required _InMemoryAssistantProvider assistants,
  required _StubHarnessConnections connections,
  required String assistantId,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
        ChangeNotifierProvider<HarnessConnectionProvider>.value(
          value: connections,
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppSnackBarOverlay(child: child!),
        home: HarnessSettingsPage(assistantId: assistantId),
      ),
    ),
  );
  // First pump runs the open-time probe scheduled in didChangeDependencies;
  // the second one paints its result.
  await tester.pump();
  await tester.pump();
  return AppLocalizations.of(tester.element(find.byType(HarnessSettingsPage)))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an unconnected harness page shows both fields and no status row',
    (tester) async {
      final seeded = await _seedHarness(tester);
      final l10n = await _pumpPage(
        tester,
        assistants: seeded.assistants,
        connections: seeded.connections,
        assistantId: seeded.id,
      );

      expect(find.byKey(const Key('harness-url-field')), findsOneWidget);
      expect(find.byKey(const Key('harness-confirm-button')), findsOneWidget);
      expect(find.text(l10n.assistantHarnessWebUiUrlLabel), findsOneWidget);
      expect(find.text(l10n.assistantHarnessWebUiUrlHint), findsOneWidget);
      expect(find.byKey(const Key('harness-connected-status')), findsNothing);
      expect(find.text(l10n.assistantHarnessConnected), findsNothing);
      expect(find.text(l10n.assistantHarnessConfirm), findsOneWidget);

      // The name field is seeded from the assistant; the URL field starts empty
      // because there is no stored link yet.
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields, hasLength(2));
      expect(fields.first.controller!.text, 'DeepSeek Harness');
      expect(fields.last.controller!.text, isEmpty);
      // Nothing to re-prove on open.
      expect(seeded.connections.checked, isEmpty);

      // Renaming writes straight through to the provider, like the edit page.
      await tester.enterText(find.byType(TextField).first, 'Harness renamed');
      await tester.pump();
      expect(seeded.assistants.getById(seeded.id)!.name, 'Harness renamed');
    },
  );

  testWidgets(
    'confirming an empty or malformed link warns and stores nothing',
    (tester) async {
      final seeded = await _seedHarness(tester);
      final l10n = await _pumpPage(
        tester,
        assistants: seeded.assistants,
        connections: seeded.connections,
        assistantId: seeded.id,
      );

      await tester.tap(find.byKey(const Key('harness-confirm-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(l10n.assistantHarnessInvalidUrl), findsOneWidget);
      // A clearly invalid link is rejected locally: no probe, no persistence.
      expect(seeded.connections.checked, isEmpty);
      expect(seeded.assistants.getById(seeded.id)!.harnessUrl, isNull);

      await tester.enterText(
        find.byKey(const Key('harness-url-field')),
        'not-a-url',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('harness-confirm-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text(l10n.assistantHarnessInvalidUrl), findsWidgets);
      expect(seeded.connections.checked, isEmpty);
      expect(seeded.assistants.getById(seeded.id)!.harnessUrl, isNull);
      // The typed text stays put so it can be corrected.
      expect(find.text('not-a-url'), findsOneWidget);
      // Editing dropped the old answer.
      expect(seeded.connections.resets, contains(seeded.id));

      // Let the snackbar timers run out before the test ends.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a saved link is re-proved on open and shows the connected row', (
    tester,
  ) async {
    final seeded = await _seedHarness(tester, storedUrl: _storedUrl);
    final l10n = await _pumpPage(
      tester,
      assistants: seeded.assistants,
      connections: seeded.connections,
      assistantId: seeded.id,
    );

    expect(seeded.connections.checked, hasLength(1));
    expect(seeded.connections.checked.single.harnessUrl, _storedUrl);
    expect(find.byKey(const Key('harness-connected-status')), findsOneWidget);
    expect(find.text(l10n.assistantHarnessConnected), findsOneWidget);
    expect(find.text(l10n.assistantHarnessConfirm), findsOneWidget);

    // The stored launch link carries the token: the field stays empty.
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.last.controller!.text, isEmpty);
    expect(find.textContaining('token='), findsNothing);
  });

  testWidgets(
    'confirming a valid link persists it, clears the field and lights the status',
    (tester) async {
      final seeded = await _seedHarness(tester);
      final l10n = await _pumpPage(
        tester,
        assistants: seeded.assistants,
        connections: seeded.connections,
        assistantId: seeded.id,
      );

      await tester.enterText(
        find.byKey(const Key('harness-url-field')),
        '  $_storedUrl  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('harness-confirm-button')));
      await tester.pump();
      await tester.pump();

      // The probe saw the trimmed link; the provider stores exactly that.
      expect(seeded.connections.checked, hasLength(1));
      expect(seeded.connections.checked.single.harnessUrl, _storedUrl);
      expect(seeded.assistants.getById(seeded.id)!.harnessUrl, _storedUrl);
      expect(find.byKey(const Key('harness-connected-status')), findsOneWidget);
      expect(find.text(l10n.assistantHarnessConnected), findsOneWidget);
      final urlField = tester.widget<TextField>(find.byType(TextField).last);
      expect(urlField.controller!.text, isEmpty);
    },
  );

  testWidgets('a failed probe shows its reason and keeps the typed link', (
    tester,
  ) async {
    final seeded = await _seedHarness(tester);
    seeded.connections.result = const HarnessConnectionResult.failed(
      HarnessConnectionFailure.missingToken,
    );
    final l10n = await _pumpPage(
      tester,
      assistants: seeded.assistants,
      connections: seeded.connections,
      assistantId: seeded.id,
    );

    await tester.enterText(
      find.byKey(const Key('harness-url-field')),
      'https://dsh.example.com/',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('harness-confirm-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text(l10n.assistantHarnessMissingToken), findsOneWidget);
    expect(seeded.assistants.getById(seeded.id)!.harnessUrl, isNull);
    expect(find.text('https://dsh.example.com/'), findsOneWidget);
    expect(find.byKey(const Key('harness-connected-status')), findsNothing);

    // Let the snackbar timers run out before the test ends.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
  testWidgets('a tailcat-connected harness opens on the tailcat form', (
    tester,
  ) async {
    final seeded = await _seedHarness(
      tester,
      storedTailcatAddress: _storedTailcatAddress,
      storedTailcatPort: 14000,
    );
    final l10n = await _pumpPage(
      tester,
      assistants: seeded.assistants,
      connections: seeded.connections,
      assistantId: seeded.id,
    );

    // The stored method is preselected - it is not a secret - and the field
    // below it is that method's, so the link field is gone.
    expect(find.byKey(const Key('harness-method-tailcat')), findsOneWidget);
    expect(find.byKey(const Key('harness-tailcat-field')), findsOneWidget);
    expect(find.byKey(const Key('harness-url-field')), findsNothing);
    expect(find.text(l10n.assistantHarnessTailcatAddressLabel), findsOneWidget);
    expect(
      find.text(l10n.assistantHarnessTailcatAddressHelper),
      findsOneWidget,
    );

    // Opening the page re-proves the stored tailcat connection through the
    // provider (the stub records the candidate it was asked about).
    expect(seeded.connections.checked, hasLength(1));
    expect(
      seeded.connections.checked.single.harnessTailcatAddress,
      _storedTailcatAddress,
    );
    expect(seeded.connections.checked.single.harnessTailcatPort, 14000);
    expect(find.byKey(const Key('harness-connected-status')), findsOneWidget);

    // The address is a capability: it is stored, never rendered back.
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields, hasLength(2));
    expect(fields.first.controller!.text, 'DeepSeek Harness');
    expect(fields.last.controller!.text, isEmpty);
    expect(find.textContaining('tc${'a' * 20}'), findsNothing);
    expect(find.textContaining(_storedTailcatAddress), findsNothing);
  });

  testWidgets('switching the method swaps the field and drops the old answer', (
    tester,
  ) async {
    final seeded = await _seedHarness(tester);
    final l10n = await _pumpPage(
      tester,
      assistants: seeded.assistants,
      connections: seeded.connections,
      assistantId: seeded.id,
    );

    await tester.tap(find.byKey(const Key('harness-method-tailcat')));
    await tester.pump();

    expect(find.byKey(const Key('harness-tailcat-field')), findsOneWidget);
    expect(find.byKey(const Key('harness-url-field')), findsNothing);
    expect(find.text(l10n.assistantHarnessTailcatAddressHint), findsOneWidget);
    expect(seeded.connections.resets, contains(seeded.id));

    await tester.tap(find.byKey(const Key('harness-method-link')));
    await tester.pump();

    expect(find.byKey(const Key('harness-url-field')), findsOneWidget);
    expect(find.byKey(const Key('harness-tailcat-field')), findsNothing);
  });

  testWidgets(
    'confirming text that is not a tailcat address warns and stores nothing',
    (tester) async {
      final seeded = await _seedHarness(tester);
      final l10n = await _pumpPage(
        tester,
        assistants: seeded.assistants,
        connections: seeded.connections,
        assistantId: seeded.id,
      );

      await tester.tap(find.byKey(const Key('harness-method-tailcat')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('harness-tailcat-field')),
        'not-a-tailcat-address',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('harness-confirm-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.text(l10n.assistantHarnessTailcatInvalidAddress),
        findsOneWidget,
      );
      // Local validation rejected it: no probe, no persistence.
      expect(seeded.connections.checked, isEmpty);
      final stored = seeded.assistants.getById(seeded.id)!;
      expect(stored.harnessConnectionMode, HarnessConnectionMode.publicLink);
      expect(stored.harnessTailcatAddress, isNull);
      // The typed text stays put so it can be corrected.
      expect(find.text('not-a-tailcat-address'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'confirming a pairing command saves address and port, clears the field and lights the status',
    (tester) async {
      final seeded = await _seedHarness(tester);
      final l10n = await _pumpPage(
        tester,
        assistants: seeded.assistants,
        connections: seeded.connections,
        assistantId: seeded.id,
      );

      await tester.tap(find.byKey(const Key('harness-method-tailcat')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('harness-tailcat-field')),
        'tailcat forward $_storedTailcatAddress 18080:15000',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('harness-confirm-button')));
      await tester.pump();
      await tester.pump();

      expect(seeded.connections.checked, hasLength(1));
      final checked = seeded.connections.checked.single;
      expect(checked.harnessConnectionMode, HarnessConnectionMode.tailcat);
      expect(checked.harnessTailcatAddress, _storedTailcatAddress);
      expect(checked.harnessTailcatPort, 15000);
      expect(checked.harnessUrl, isNull);

      final stored = seeded.assistants.getById(seeded.id)!;
      expect(stored.harnessConnectionMode, HarnessConnectionMode.tailcat);
      expect(stored.harnessTailcatAddress, _storedTailcatAddress);
      expect(stored.harnessTailcatPort, 15000);
      expect(stored.harnessUrl, isNull);

      expect(find.byKey(const Key('harness-connected-status')), findsOneWidget);
      expect(find.text(l10n.assistantHarnessConnected), findsOneWidget);
      final tailcatField = tester.widget<TextField>(
        find.byKey(const Key('harness-tailcat-field')).first,
      );
      expect(tailcatField.controller!.text, isEmpty);
    },
  );

  testWidgets('a failed tailcat probe shows its reason and keeps the text', (
    tester,
  ) async {
    final seeded = await _seedHarness(tester);
    seeded.connections.result = const HarnessConnectionResult.failed(
      HarnessConnectionFailure.tailcatUnavailable,
    );
    final l10n = await _pumpPage(
      tester,
      assistants: seeded.assistants,
      connections: seeded.connections,
      assistantId: seeded.id,
    );

    await tester.tap(find.byKey(const Key('harness-method-tailcat')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('harness-tailcat-field')),
      _storedTailcatAddress,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('harness-confirm-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text(l10n.assistantHarnessTailcatUnavailable), findsOneWidget);
    expect(seeded.assistants.getById(seeded.id)!.harnessTailcatAddress, isNull);
    expect(find.byKey(const Key('harness-connected-status')), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('saving a tailcat connection retires the stored link', (
    tester,
  ) async {
    final seeded = await _seedHarness(tester, storedUrl: _storedUrl);
    await _pumpPage(
      tester,
      assistants: seeded.assistants,
      connections: seeded.connections,
      assistantId: seeded.id,
    );

    await tester.tap(find.byKey(const Key('harness-method-tailcat')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('harness-tailcat-field')),
      _storedTailcatAddress,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('harness-confirm-button')));
    await tester.pump();
    await tester.pump();

    final stored = seeded.assistants.getById(seeded.id)!;
    expect(stored.harnessConnectionMode, HarnessConnectionMode.tailcat);
    expect(stored.harnessTailcatAddress, _storedTailcatAddress);
    expect(
      stored.harnessUrl,
      isNull,
      reason: 'one connection per assistant: the old link must not linger',
    );
  });
}
