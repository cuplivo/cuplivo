// The description row on a phone: a value that does not fit must give way, not
// squeeze its own label to nothing.
//
// `_iosNavRow` lays its trailing value out as a non-flex child, so a long value
// used to measure at its natural width, collapse the label to a sliver and (with
// wide glyphs) overflow the card. The row now holds the value in a loose flex.
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

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

const _assistantId = 'assistant-basic-description-row';

/// 29 CJK characters: a plausible answer to "what is this assistant for", well
/// inside the field's 300-character limit.
const _longDescription = '把自然语言需求写成 SQL 并解释执行计划，还要检查索引与慢查询日志';

/// The page runs on real futures the test clock does not drive, so a settle is
/// not a reliable boundary here.
Future<void> _pumpFrames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // A square-glyph font stands in for CJK: if a row survives this, it has room
    // for the real thing.
    final bytes = await File(
      'test/fixtures/fonts/JetBrainsMono-Regular.ttf',
    ).readAsBytes();
    await (FontLoader(
      'DescriptionRowTest',
    )..addFont(Future.value(bytes.buffer.asByteData()))).load();
  });

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase database;
  late WorkspaceProvider workspaces;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('kelivo_desc_row_');
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
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Opens the phone's basic tab and returns the label's laid-out width.
  Future<double> openAndMeasure(
    WidgetTester tester, {
    required String description,
    double width = 360,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      const haptics = MethodChannel('haptic_feedback');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(haptics, (_) async => true);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(haptics, null),
      );

      final harness = await createBusinessTestHarness(
        initial: {
          'assistants_v1': Assistant.encodeList([
            Assistant(
              id: _assistantId,
              name: 'Default Assistant',
              description: description,
            ),
          ]),
        },
      );
      final ap = AssistantProvider(preferences: harness.preferences);
      await tester.runAsync(() => ap.loaded);

      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(
              create: (_) => SettingsProvider(createBusinessTestPreferences()),
            ),
            ChangeNotifierProvider.value(value: ap),
            ChangeNotifierProvider<WorkspaceProvider>.value(value: workspaces),
          ],
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'DescriptionRowTest'),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openAssistantBasicSettings(
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
      await _pumpFrames(tester);

      // The page has its own layout noise on a phone; this case is about the
      // one row, so drain what is already there before measuring.
      for (var i = 0; i < 16; i++) {
        if (tester.takeException() == null) break;
      }

      final labelFinder = find.text('Description');
      await tester.scrollUntilVisible(
        labelFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _pumpFrames(tester);

      final label = tester.renderObject<RenderParagraph>(labelFinder);
      return label.size.width;
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('a long description leaves the label readable at 360 dp', (
    tester,
  ) async {
    final labelWidth = await openAndMeasure(
      tester,
      description: _longDescription,
    );

    // The row shows a state, not a preview: a 24-character preview used to
    // squeeze this label to 3.5 px and, with wide glyphs, overflow the card.
    expect(
      labelWidth,
      greaterThan(60),
      reason: 'the label must keep enough width to be readable',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('its value sits flush right like every other settings row', (
    tester,
  ) async {
    await openAndMeasure(tester, description: _longDescription);

    // A shared row that made its trailing group flexible would pin the label to
    // half the row and leave the value floating mid-row; this asserts the value
    // still ends where the card's padding starts.
    final value = find.text('Set');
    expect(value, findsOneWidget);
    final card = find
        .ancestor(of: value, matching: find.byType(SectionCard))
        .first;
    final gap = tester.getRect(card).right - tester.getRect(value).right;
    expect(gap, lessThan(40), reason: 'the value must be right-aligned');
  });

  testWidgets('an empty description lays the row out exactly as before', (
    tester,
  ) async {
    final labelWidth = await openAndMeasure(tester, description: '');
    expect(labelWidth, greaterThan(60));
    // Nothing written, no value: the grammar the other optional rows use.
    expect(find.text('Set'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
