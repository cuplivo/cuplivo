import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';
import '../../../support/temp_directory_cleanup.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => p.join(path, 'cache');

  @override
  Future<String?> getTemporaryPath() async => p.join(path, 'tmp');
}

const _assistantId = 'assistant-gradient-desktop';
const _switchKey = ValueKey('assistantEditGradientBackgroundSwitch');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final bytes = await File(
      'test/fixtures/fonts/JetBrainsMono-Regular.ttf',
    ).readAsBytes();
    await (FontLoader(
      'GradientTest',
    )..addFont(Future.value(bytes.buffer.asByteData()))).load();
  });

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase database;
  late WorkspaceProvider workspaces;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('kelivo_assistant_gradient_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    database = AppDatabase(NativeDatabase.memory());
    await database.customSelect('SELECT 1;').getSingle();
    workspaces = WorkspaceProvider(store: ExtensionEntityStore(database));
    await workspaces.loaded;
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    await database.close();
    await deleteDirectoryWhenReleased(tempDir);
  });

  testWidgets('the desktop assistant dialog can turn a synced gradient off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Providers start real async loads in their constructors, so both the
    // construction and the await belong inside runAsync.
    late final SettingsProvider settings;
    late final AssistantProvider ap;
    await tester.runAsync(() async {
      final harness = await createBusinessTestHarness(
        initial: {
          'assistants_v1': Assistant.encodeList([
            const Assistant(
              id: _assistantId,
              name: 'Default Assistant',
              // A LAN sync can land this row with the phone's gradient on.
              useGradientBackground: true,
            ),
          ]),
        },
      );
      ap = AssistantProvider(preferences: harness.preferences);
      await ap.loaded;

      final settingsPrefs = createBusinessTestPreferences();
      await settingsPrefs.load();
      settings = SettingsProvider(settingsPrefs);
      await settings.loaded;
    });
    expect(ap.getById(_assistantId)!.useGradientBackground, isTrue);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: ap),
          ChangeNotifierProvider<WorkspaceProvider>.value(value: workspaces),
        ],
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'GradientTest'),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAssistantDesktopDialog(
                  context,
                  assistantId: _assistantId,
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await pumpFrames(tester);

    // The dialog opens on the basic menu, where the gradient row must exist:
    // the desktop was the one layout without the control that turns it off.
    final row = find.byKey(_switchKey);
    await tester.ensureVisible(row);
    await pumpFrames(tester);
    expect(row, findsOneWidget);
    final toggle = find.descendant(of: row, matching: find.byType(IosSwitch));
    expect(tester.widget<IosSwitch>(toggle).value, isTrue);
    expect(find.text('Static mode'), findsOneWidget);
    // An image can never replace the gradient while the gradient owns the
    // background, so its picker must not compete with this row.
    expect(find.text('Choose Image'), findsNothing);

    await tester.tap(toggle);
    await pumpUntil(
      tester,
      () =>
          ap.getById(_assistantId)!.useGradientBackground == false &&
          find.text('Static mode').evaluate().isEmpty,
    );
    await tester.pump();
    expect(ap.getById(_assistantId)!.useGradientBackground, isFalse);
    expect(find.text('Static mode'), findsNothing);
    expect(find.text('Choose Image'), findsOneWidget);

    await tester.ensureVisible(row);
    await tester.tap(toggle);
    await pumpUntil(
      tester,
      () =>
          ap.getById(_assistantId)!.useGradientBackground == true &&
          find.text('Static mode').evaluate().isNotEmpty,
    );
    await tester.pump();
    expect(ap.getById(_assistantId)!.useGradientBackground, isTrue);
    expect(find.text('Static mode'), findsOneWidget);

    // End with the animation off so no preview clock outlives the test.
    await tester.tap(toggle);
    await pumpUntil(
      tester,
      () =>
          ap.getById(_assistantId)!.useGradientBackground == false &&
          find.text('Static mode').evaluate().isEmpty,
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// Pumps a fixed number of frames instead of settling: the dialog's own loads
/// run on real futures the test clock does not drive, so a settle is not a
/// reliable boundary here.
Future<void> pumpFrames(WidgetTester tester, [int count = 5]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The assistant provider notifies after persisting, so a switch rebuild only
/// lands once the real write completes. Give the event loop a turn per frame
/// until [done] holds instead of assuming a single pump is enough.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
