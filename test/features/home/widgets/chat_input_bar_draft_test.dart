import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/group_chat/models/chat_input_mode.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

void main() {
  late SharedPreferences prefs;
  InputDraftPersistence? draftPersistence;
  late Directory tempDir;
  int fileCounter = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempDir = Directory.systemTemp.createTempSync('chat_input_draft_test');
    fileCounter = 0;
  });

  tearDown(() {
    draftPersistence?.disposeInternal();
    draftPersistence = null;
    tempDir.deleteSync(recursive: true);
  });

  /// Seeds the persisted draft, then constructs the service so its preload
  /// picks it up (mirrors the real cold-start order: prefs written last
  /// session, service preloaded this session).
  InputDraftPersistence seedAndBuild({
    String text = '',
    List<String> images = const [],
    List<Map<String, String>> documents = const [],
  }) {
    final raw = jsonEncode({
      'text': text,
      'images': images,
      'documents': [
        for (final d in documents)
          {'path': d['path'], 'fileName': d['fileName'], 'mime': d['mime']},
      ],
    });
    prefs.setString(InputDraftPersistence.key, raw);
    draftPersistence = InputDraftPersistence(prefs);
    return draftPersistence!;
  }

  InputDraftPersistence buildService() {
    draftPersistence = InputDraftPersistence(prefs);
    return draftPersistence!;
  }

  File makeImageFile() {
    final file = File('${tempDir.path}/draft_img_${fileCounter++}.png');
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      ),
    );
    return file;
  }

  File makeDocFile() {
    final file = File('${tempDir.path}/draft_doc_${fileCounter++}.pdf');
    file.writeAsBytesSync([0x25, 0x50, 0x44, 0x46]);
    return file;
  }

  Widget buildHarness({
    required TextEditingController controller,
    required FocusNode focusNode,
    Future<ChatInputSubmissionResult> Function(ChatInputData input)? onSend,
    ChatInputBarController? mediaController,
    ChatInputMode mode = ChatInputMode.normal,
  }) {
    return MultiProvider(
      providers: [
        Provider<InputDraftPersistence>.value(
          value: draftPersistence ?? buildService(),
        ),
        ChangeNotifierProvider.value(value: SettingsProvider()),
        ChangeNotifierProvider.value(value: AssistantProvider()),
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
            onSend: onSend ?? (_) async => ChatInputSubmissionResult.rejected,
            mode: mode,
          ),
        ),
      ),
    );
  }

  group('cold-start restore', () {
    testWidgets('restores text and existing media from the draft', (
      tester,
    ) async {
      final image = makeImageFile();
      final doc = makeDocFile();
      seedAndBuild(
        text: 'unfinished message',
        images: [image.path],
        documents: [
          {
            'path': doc.path,
            'fileName': doc.path.split(Platform.pathSeparator).last,
            'mime': 'application/pdf',
          },
        ],
      );
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

      expect(controller.text, 'unfinished message');
      final restored = mediaController.snapshotInput(controller.text);
      expect(restored.imagePaths, [image.path]);
      expect(restored.documents.single.path, doc.path);

      // Flush the post-restore re-save so no timer outlives the test.
      await tester.pump(const Duration(milliseconds: 900));
      controller.dispose();
      focusNode.dispose();
    });

    testWidgets(
      'filters out deleted files but keeps data-URL images on restore',
      (tester) async {
        final image = makeImageFile();
        seedAndBuild(
          text: 'media draft',
          images: [
            image.path,
            '/definitely/missing.png',
            'data:image/png;base64,abc',
          ],
        );
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

        final restored = mediaController.snapshotInput(controller.text);
        expect(restored.imagePaths, [image.path, 'data:image/png;base64,abc']);

        await tester.pump(const Duration(milliseconds: 900));
        controller.dispose();
        focusNode.dispose();
      },
    );

    testWidgets('restores only once per process (draft consumed)', (
      tester,
    ) async {
      seedAndBuild(text: 'once only');
      final firstController = TextEditingController();
      final secondController = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(controller: firstController, focusNode: focusNode),
      );
      expect(firstController.text, 'once only');

      // A later bar mount (e.g. desktop window recreate) must not re-restore.
      await tester.pumpWidget(
        buildHarness(controller: secondController, focusNode: focusNode),
      );
      expect(secondController.text, isEmpty);

      await tester.pump(const Duration(milliseconds: 900));
      firstController.dispose();
      secondController.dispose();
      focusNode.dispose();
    });

    testWidgets('group-chat bar neither restores nor touches the draft', (
      tester,
    ) async {
      seedAndBuild(text: 'normal chat draft');
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(
          controller: controller,
          focusNode: focusNode,
          mode: ChatInputMode.groupChat,
        ),
      );
      expect(controller.text, isEmpty);
      // The draft must remain unconsumed for the normal bar.
      expect(
        draftPersistence!.takeDraftForRestore()?.text,
        'normal chat draft',
      );

      controller.dispose();
      focusNode.dispose();
    });

    testWidgets('draft with whitespace-only text and deleted media is cleared '
        'on restore', (tester) async {
      seedAndBuild(text: '   ', images: ['/definitely/missing.png']);
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(controller: controller, focusNode: focusNode),
      );

      expect(controller.text, isEmpty);
      // The un-restorable stale draft must not linger for the guardrail.
      expect(prefs.getString(InputDraftPersistence.key), isNull);

      controller.dispose();
      focusNode.dispose();
    });
  });

  group('debounced save', () {
    testWidgets('typing persists after the debounce window', (tester) async {
      buildService();
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(controller: controller, focusNode: focusNode),
      );

      await tester.enterText(find.byType(TextField), 'draft me');
      await tester.pump(const Duration(milliseconds: 100));
      expect(prefs.getString(InputDraftPersistence.key), isNull);

      await tester.pump(const Duration(milliseconds: 900));
      final decoded =
          jsonDecode(prefs.getString(InputDraftPersistence.key)!)
              as Map<String, dynamic>;
      expect(decoded['text'], 'draft me');

      controller.dispose();
      focusNode.dispose();
    });

    testWidgets('media added through the controller is persisted', (
      tester,
    ) async {
      final image = makeImageFile();
      buildService();
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
      mediaController.addImages([image.path]);
      await tester.pump(const Duration(milliseconds: 900));

      final decoded =
          jsonDecode(prefs.getString(InputDraftPersistence.key)!)
              as Map<String, dynamic>;
      expect(decoded['images'], [image.path]);

      controller.dispose();
      focusNode.dispose();
    });

    testWidgets('Shift+Enter newline insert persists to the draft', (
      tester,
    ) async {
      buildService();
      // The Enter-key handler only activates on tablet/desktop widths.
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(controller: controller, focusNode: focusNode),
      );

      await tester.enterText(find.byType(TextField), 'line one');
      // Programmatic insert paths never fire onChanged — the draft must be
      // saved explicitly.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 900));

      expect(controller.text, 'line one\n');
      final decoded =
          jsonDecode(prefs.getString(InputDraftPersistence.key)!)
              as Map<String, dynamic>;
      expect(decoded['text'], 'line one\n');

      controller.dispose();
      focusNode.dispose();
    });
  });

  group('clear semantics', () {
    testWidgets('sent clears the persisted draft immediately', (tester) async {
      seedAndBuild(text: 'about to send');
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(
          controller: controller,
          focusNode: focusNode,
          onSend: (_) async => ChatInputSubmissionResult.sent,
        ),
      );
      expect(controller.text, 'about to send');

      await tester.tap(find.byIcon(Lucide.ArrowUp));
      await tester.pumpAndSettle();

      expect(prefs.getString(InputDraftPersistence.key), isNull);
      expect(controller.text, isEmpty);

      controller.dispose();
      focusNode.dispose();
    });

    testWidgets('queued clears the persisted draft immediately', (
      tester,
    ) async {
      seedAndBuild(text: 'queued content');
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(
          controller: controller,
          focusNode: focusNode,
          onSend: (_) async => ChatInputSubmissionResult.queued,
        ),
      );
      await tester.tap(find.byIcon(Lucide.ArrowUp));
      await tester.pumpAndSettle();

      expect(prefs.getString(InputDraftPersistence.key), isNull);

      controller.dispose();
      focusNode.dispose();
    });

    testWidgets('rejected keeps the draft and the input', (tester) async {
      seedAndBuild(text: 'stays put');
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        buildHarness(
          controller: controller,
          focusNode: focusNode,
          onSend: (_) async => ChatInputSubmissionResult.rejected,
        ),
      );
      await tester.tap(find.byIcon(Lucide.ArrowUp));
      await tester.pumpAndSettle();

      expect(controller.text, 'stays put');
      final decoded =
          jsonDecode(prefs.getString(InputDraftPersistence.key)!)
              as Map<String, dynamic>;
      expect(decoded['text'], 'stays put');

      controller.dispose();
      focusNode.dispose();
    });

    testWidgets('clearDraft removes the persisted draft', (tester) async {
      seedAndBuild(text: 'wiped');
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
      expect(controller.text, 'wiped');

      mediaController.clearDraft();
      await tester.pump();

      expect(controller.text, isEmpty);
      expect(prefs.getString(InputDraftPersistence.key), isNull);

      controller.dispose();
      focusNode.dispose();
    });
  });
}
