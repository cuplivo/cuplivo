import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/business_test_harness.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/utils/model_display_helper.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// A real 1x1 PNG, so the restored attachment preview decodes instead of
/// tripping the test binding's error handler.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  /// The handle the draft service itself writes through. Re-acquired after the
  /// test providers are built, because constructing them resets the mock store.
  late SharedPreferences prefs;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildHarness({
    required SettingsProvider settings,
    required AssistantProvider assistants,
    required TextEditingController controller,
    required FocusNode focusNode,
    required Future<ChatInputSubmissionResult> Function(ChatInputData input)
    onSend,
    ChatInputBarController? mediaController,
  }) {
    final chatModel = resolveChatModel(
      settings,
      assistant: assistants.currentAssistant,
    );
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: assistants),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatInputBar(
            chatModelProviderKey: chatModel.providerKey,
            chatModelId: chatModel.modelId,
            controller: controller,
            focusNode: focusNode,
            mediaController: mediaController,
            onSend: onSend,
          ),
        ),
      ),
    );
  }

  /// Builds the providers, seeds the (post-reset) prefs store and initializes
  /// the draft service, in that order — provider construction calls
  /// `SharedPreferences.setMockInitialValues`, so seeding earlier would be lost.
  Future<void> pumpBar(
    WidgetTester tester, {
    required TextEditingController controller,
    required FocusNode focusNode,
    required Future<ChatInputSubmissionResult> Function(ChatInputData input)
    onSend,
    ChatInputBarController? mediaController,
    Future<void> Function(SharedPreferences prefs)? seed,
  }) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    prefs = await SharedPreferences.getInstance();
    await seed?.call(prefs);
    await InputDraftPersistence.ensureInitialized();
    await tester.pumpWidget(
      buildHarness(
        settings: settings,
        assistants: assistants,
        controller: controller,
        focusNode: focusNode,
        mediaController: mediaController,
        onSend: onSend,
      ),
    );
  }

  Future<void> tapSendButton(WidgetTester tester) async {
    await tester.tap(find.byIcon(Lucide.ArrowUp));
    await tester.pumpAndSettle();
  }

  Future<void> pumpDebounce(WidgetTester tester) async {
    await tester.pump(
      InputDraftPersistence.debounceDuration +
          const Duration(milliseconds: 100),
    );
  }

  Map<String, dynamic>? persistedDraft() {
    final raw = prefs.getString(InputDraftPersistence.key);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  String draftJson({
    String text = '',
    List<String> images = const [],
    List<Map<String, String>> documents = const [],
  }) {
    return jsonEncode({
      'text': text,
      'images': images,
      'documents': [
        for (final d in documents)
          {'path': d['path'], 'fileName': d['fileName'], 'mime': d['mime']},
      ],
    });
  }

  testWidgets('冷启动恢复草稿：文本 + 仍存在的媒体，缺失文件被过滤', (tester) async {
    final dir = Directory.systemTemp.createTempSync('cuplivo_draft_restore');
    addTearDown(() => dir.deleteSync(recursive: true));
    final image = File(p.join(dir.path, 'kept.png'))
      ..writeAsBytesSync(_onePixelPng);
    final document = File(p.join(dir.path, 'kept.pdf'))
      ..writeAsStringSync('pdf');
    final missing = p.join(dir.path, 'gone.bin');

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.rejected,
      seed: (prefs) => prefs.setString(
        InputDraftPersistence.key,
        draftJson(
          text: 'restored text',
          images: [image.path, missing],
          documents: [
            {
              'path': document.path,
              'fileName': 'kept.pdf',
              'mime': 'application/pdf',
            },
            {
              'path': missing,
              'fileName': 'gone.pdf',
              'mime': 'application/pdf',
            },
          ],
        ),
      ),
    );

    expect(controller.text, 'restored text');
    expect(find.text('kept.pdf'), findsOneWidget);
    expect(find.text('gone.pdf'), findsNothing);
    expect(
      find.byKey(const ValueKey('chat-input-image-previews')),
      findsOneWidget,
    );

    // The filtered content is re-persisted so storage matches the bar.
    await pumpDebounce(tester);
    final draft = persistedDraft();
    expect(draft, isNotNull);
    expect(draft!['text'], 'restored text');
    final images = (draft['images'] as List).cast<String>();
    expect(images, hasLength(1));
    // Separators may be normalized, so compare paths platform-agnostically.
    expect(p.equals(images.single, image.path), isTrue);
    final documents = (draft['documents'] as List).cast<Map<String, dynamic>>();
    expect(documents, hasLength(1));
    expect(p.equals(documents.single['path'] as String, document.path), isTrue);

    // The cold-start handle is consumed exactly once per process.
    expect(InputDraftPersistence.maybeInstance!.takeDraftForRestore(), isNull);
  });

  testWidgets('冷启动草稿全部被过滤时丢弃，不恢复空壳', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.rejected,
      seed: (prefs) => prefs.setString(
        InputDraftPersistence.key,
        draftJson(
          text: '   ',
          images: ['/definitely/missing.png'],
          documents: [
            {
              'path': '/definitely/missing.pdf',
              'fileName': 'm.pdf',
              'mime': '',
            },
          ],
        ),
      ),
    );

    expect(controller.text, isEmpty);
    expect(persistedDraft(), isNull);
  });

  testWidgets('输入文本触发防抖落盘', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.rejected,
    );

    await tester.enterText(find.byType(TextField), 'hello draft');
    expect(persistedDraft(), isNull, reason: '防抖窗口内不应落盘');

    await pumpDebounce(tester);
    expect(persistedDraft()!['text'], 'hello draft');
  });

  testWidgets('发送成功立即清除草稿键', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.sent,
    );

    await tester.enterText(find.byType(TextField), 'to send');
    await pumpDebounce(tester);
    expect(persistedDraft(), isNotNull);

    await tapSendButton(tester);
    expect(controller.text, isEmpty);
    expect(persistedDraft(), isNull);
  });

  testWidgets('入队同样立即清除草稿键', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.queued,
    );

    await tester.enterText(find.byType(TextField), 'to queue');
    await pumpDebounce(tester);
    expect(persistedDraft(), isNotNull);

    await tapSendButton(tester);
    expect(persistedDraft(), isNull);
  });

  testWidgets('发送被拒绝时草稿保留', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.rejected,
    );

    await tester.enterText(find.byType(TextField), 'keep me');
    await pumpDebounce(tester);

    await tapSendButton(tester);
    expect(controller.text, 'keep me');
    await pumpDebounce(tester);
    expect(persistedDraft()!['text'], 'keep me');
  });

  testWidgets('程序化写入输入框（建议词/快捷短语/语音）同样落盘', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.rejected,
    );

    // The home controller inserts text by assigning the controller value, which
    // never fires TextField.onChanged — the draft must still follow.
    controller.value = const TextEditingValue(
      text: 'inserted by suggestion',
      selection: TextSelection.collapsed(offset: 22),
    );
    await pumpDebounce(tester);
    expect(persistedDraft()!['text'], 'inserted by suggestion');
  });

  testWidgets('输入框销毁时冲刷尚未落盘的草稿', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      onSend: (_) async => ChatInputSubmissionResult.rejected,
    );

    await tester.enterText(find.byType(TextField), 'flushed on dispose');
    expect(persistedDraft(), isNull, reason: '防抖窗口内不应落盘');

    // Tearing the bar down flushes the pending debounce instead of dropping it.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(persistedDraft()!['text'], 'flushed on dispose');
  });

  testWidgets('清空输入框同时移除持久化草稿', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    final mediaController = ChatInputBarController();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      mediaController: mediaController,
      onSend: (_) async => ChatInputSubmissionResult.rejected,
    );

    await tester.enterText(find.byType(TextField), 'drop me');
    await pumpDebounce(tester);
    expect(persistedDraft(), isNotNull);

    mediaController.clearDraft();
    await pumpDebounce(tester);
    expect(controller.text, isEmpty);
    expect(persistedDraft(), isNull);
  });
}
