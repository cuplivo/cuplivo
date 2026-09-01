import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/group_chat/models/chat_input_mode.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:path/path.dart' as p;

/// Simulates an Android IME pushing image content into the text field
/// (Gboard / WeChat clipboard paste via `commitContent`). The bytes flow
/// through the same `ContentInsertionConfiguration` callback the Android
/// embedding invokes, so these tests cover the platform entry point.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

const String _tempPrefix = 'chat_input_ime_paste_test';

void main() {
  late BusinessPreferences businessPrefs;
  late InputDraftPersistence? draftPersistence;
  late SharedPreferences prefs;
  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  String contentUri(String name) =>
      Uri.parse('content://com.example.ime/clipboard/$name').toString();

  // Same valid 1x1 PNG used by the draft tests.
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  void sweepPreviousTempDirs() {
    final leftovers = Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).startsWith(_tempPrefix));
    for (final dir in leftovers) {
      try {
        dir.deleteSync(recursive: true);
      } catch (e) {
        debugPrint(
          '[Test teardown] could not sweep leftover temp dir '
          '${dir.path}: $e',
        );
      }
    }
  }

  Future<void> deleteTempWithRetries(Directory dir) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on PathAccessException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    debugPrint(
      '[Test teardown] temp dir ${dir.path} still pinned by flutter_tester; '
      'it will be swept by the next test run.',
    );
  }

  setUp(() async {
    // Windows-only quirk: flutter_tester's image decoder can keep a
    // previewed image file pinned until the process exits, so this process
    // may find orphan temp dirs that a fresh instance can delete.
    sweepPreviousTempDirs();
    businessPrefs = BusinessPreferences.memoryForTests();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    draftPersistence = null;
    tempDir = Directory.systemTemp.createTempSync(_tempPrefix);
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    draftPersistence?.disposeInternal();
    draftPersistence = null;
    await deleteTempWithRetries(tempDir);
  });

  InputDraftPersistence buildDraftPersistence() {
    draftPersistence = InputDraftPersistence(prefs);
    return draftPersistence!;
  }

  Widget buildHarness({
    required TextEditingController controller,
    required FocusNode focusNode,
    required ChatInputBarController mediaController,
  }) {
    return MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: businessPrefs),
        Provider<InputDraftPersistence>.value(value: buildDraftPersistence()),
        ChangeNotifierProvider.value(
          value: SettingsProvider(preferences: businessPrefs),
        ),
        ChangeNotifierProvider.value(
          value: AssistantProvider(preferences: businessPrefs),
        ),
        ChangeNotifierProvider.value(value: InputStatusProvider()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            focusNode: focusNode,
            mediaController: mediaController,
            onSend: (_) async => ChatInputSubmissionResult.rejected,
            mode: ChatInputMode.normal,
          ),
        ),
      ),
    );
  }

  Future<void> insertContent(
    WidgetTester tester, {
    required String mimeType,
    required String uri,
    Uint8List? data,
    required bool Function()? settled,
  }) async {
    await tester.runAsync(() async {
      tester
          .state<EditableTextState>(find.byType(EditableText))
          .insertContent(
            KeyboardInsertedContent(mimeType: mimeType, uri: uri, data: data),
          );
      if (settled == null) {
        // Negative scenarios cannot assert "nothing happened" by polling;
        // give the handler a fixed window to prove its no-op behavior.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return;
      }
      // Poll instead of a fixed delay: the async save/attach flow in
      // _handleInsertedContent is real IO whose latency varies by runner.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!settled() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
  }

  Directory uploadDir() => Directory('${tempDir.path}/upload');

  List<String> uploadFiles() => uploadDir().existsSync()
      ? uploadDir().listSync().map((e) => e.path).toList()
      : [];

  testWidgets('declares image mime types for IME content insertion', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: ChatInputBarController(),
      ),
    );

    final config = tester
        .widget<TextField>(find.byType(TextField))
        .contentInsertionConfiguration;
    expect(config, isNotNull);
    expect(config!.allowedMimeTypes, containsAll(['image/png', 'image/gif']));
    expect(config.onContentInserted, isNotNull);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('IME paste (png) attaches the image and persists its bytes', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'show me this');
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
      ),
    );

    await insertContent(
      tester,
      mimeType: 'image/png',
      uri: contentUri('paste.png'),
      data: pngBytes,
      settled: () => mediaController.snapshotInput('').imagePaths.length == 1,
    );

    final paths = mediaController.snapshotInput('').imagePaths;
    expect(paths, hasLength(1));
    expect(paths.single, endsWith('.png'));
    final saved = File(paths.single);
    expect(saved.existsSync(), isTrue);
    expect(
      await tester.runAsync(() => saved.readAsBytes()),
      orderedEquals(pngBytes),
    );
    expect(controller.text, 'show me this');

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('IME paste with jpg alias saves with a .jpg extension', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
      ),
    );

    await insertContent(
      tester,
      mimeType: 'image/jpg',
      uri: contentUri('paste.jpg'),
      data: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]),
      settled: () => mediaController.snapshotInput('').imagePaths.length == 1,
    );

    final paths = mediaController.snapshotInput('').imagePaths;
    expect(paths, hasLength(1));
    expect(paths.single, endsWith('.jpg'));

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('consecutive IME image inserts attach both images', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
      ),
    );

    await insertContent(
      tester,
      mimeType: 'image/png',
      uri: contentUri('one.png'),
      data: pngBytes,
      settled: () => mediaController.snapshotInput('').imagePaths.length == 1,
    );
    await insertContent(
      tester,
      mimeType: 'image/webp',
      uri: contentUri('two.webp'),
      data: Uint8List.fromList(const [0x52, 0x49, 0x46, 0x46]),
      settled: () => mediaController.snapshotInput('').imagePaths.length == 2,
    );

    final paths = mediaController.snapshotInput('').imagePaths;
    expect(paths, hasLength(2));
    expect(paths.toSet(), hasLength(2));

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('unsupported IME mime type is ignored without side effects', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
      ),
    );

    // The framework guard rejects undeclared mimes before insertContent, so
    // invoke the handler directly to exercise the defensive ignore branch.
    await tester.runAsync(() async {
      tester
          .widget<TextField>(find.byType(TextField))
          .contentInsertionConfiguration!
          .onContentInserted(
            KeyboardInsertedContent(
              mimeType: 'video/mp4',
              uri: contentUri('clip.mp4'),
              data: Uint8List.fromList(const [0x00, 0x00, 0x00]),
            ),
          );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(mediaController.snapshotInput('').imagePaths, isEmpty);
    expect(uploadFiles(), isEmpty);

    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('IME content without data is ignored without side effects', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
      ),
    );

    await insertContent(
      tester,
      mimeType: 'image/png',
      uri: contentUri('hollow.png'),
      settled: null,
    );

    expect(mediaController.snapshotInput('').imagePaths, isEmpty);
    expect(uploadFiles(), isEmpty);

    controller.dispose();
    focusNode.dispose();
  });
}
