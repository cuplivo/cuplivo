import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/memory_provider.dart';
import 'package:Cuplivo/core/providers/quick_instruction_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/tts/tts_playback_models.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:Cuplivo/shared/widgets/plain_text_code_editor.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

const _assistantId = 'assistant-time-test';
const _secondAssistantId = 'assistant-time-test-2';

class _FakeTtsProvider extends ChangeNotifier implements TtsProvider {
  @override
  TtsPlaybackState get playbackState => const TtsPlaybackState();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Hand-written stand-in for the `file_picker` platform singleton, so the
/// import path can be driven from a widget test without the platform channel.
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;
  int pickFilesCalls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickFilesCalls++;
    return result;
  }
}

class _StubChatService extends ChatService {
  @override
  bool get initialized => true;

  @override
  List<Conversation> getConversationsWithSummaryForAssistant(String id) => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _seedPreferences({
  String systemPrompt = '',
  bool includeSecond = false,
  String secondSystemPrompt = 'second original',
}) {
  final assistants = <Assistant>[
    Assistant(
      id: _assistantId,
      name: 'Test Assistant',
      temperature: 0.6,
      systemPrompt: systemPrompt,
    ),
    if (includeSecond)
      Assistant(
        id: _secondAssistantId,
        name: 'Second Assistant',
        temperature: 0.6,
        systemPrompt: secondSystemPrompt,
      ),
  ];
  SharedPreferences.setMockInitialValues({
    'assistants_v1': Assistant.encodeList(assistants),
  });
  businessPrefs = BusinessPreferences.memoryForTests();
}

Future<AssistantProvider> _createAssistantProvider({
  required BusinessPreferences preferences,
}) async {
  final provider = AssistantProvider(preferences: preferences);
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
      ChangeNotifierProvider(
        create: (_) => UserProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider<TtsProvider>(create: (_) => _FakeTtsProvider()),
      Provider<ChatService>(create: (_) => _StubChatService()),
      ChangeNotifierProvider.value(value: assistantProvider),
      ChangeNotifierProvider(
        create: (_) => MemoryProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(
        create: (_) => QuickInstructionProvider(preferences: businessPrefs),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

/// Opens the Prompts tab and hands back the provider behind the page, so a
/// test can assert on what was actually persisted.
Future<AssistantProvider> _openPromptsTab(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final provider = await _createAssistantProvider(preferences: businessPrefs);
  await tester.pumpWidget(
    _buildHarness(
      assistantProvider: provider,
      child: const AssistantSettingsEditPage(assistantId: _assistantId),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('Prompts'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 600));
  return provider;
}

Future<void> _settleTabSwitch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 600));
}

/// Tears a harness down without leaving re_editor's one-shot timers behind.
///
/// While an editor is focused, re_editor schedules timers it never cancels:
/// a 100 ms cursor-blink delay and a 10 ms composing retry. If they are still
/// pending when the test ends, the binding fails with "A Timer is still
/// pending"; if they fire after the blink controller is disposed, the test
/// fails with "used after being disposed". Let them run out while the tree is
/// mounted, then drop focus (which cancels the periodic blink) and dispose.
Future<void> _tearDownEditorHarness(
  WidgetTester tester, {
  FocusNode? focusNode,
}) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  focusNode?.unfocus();
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 200));
}

Finder get _warningIcons =>
    find.byWidgetPredicate((w) => w is Icon && w.icon == Lucide.TriangleAlert);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'volatile variables get a warning badge in the system prompt list',
    (tester) async {
      _seedPreferences();
      await _openPromptsTab(tester);

      expect(_warningIcons, findsNWidgets(4));
    },
  );

  testWidgets('warning banner appears while system prompt contains time vars', (
    tester,
  ) async {
    _seedPreferences(systemPrompt: 'The time is {cur_datetime}.');
    await _openPromptsTab(tester);

    expect(find.textContaining('prompt caching cannot hit'), findsOneWidget);
  });

  testWidgets('no warning banner without volatile vars', (tester) async {
    _seedPreferences();
    await _openPromptsTab(tester);

    expect(find.textContaining('prompt caching cannot hit'), findsNothing);
  });

  testWidgets('memory tab badges the time memory variables', (tester) async {
    _seedPreferences();
    await _openPromptsTab(tester);

    await tester.tap(find.text('Memory'));
    await _settleTabSwitch(tester);

    expect(_warningIcons, findsNWidgets(3));
  });

  testWidgets('enable gate: Enable anyway turns the switch on', (tester) async {
    _seedPreferences(systemPrompt: 'Time: {cur_datetime}');
    await _openPromptsTab(tester);

    await tester.tap(find.byType(IosSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('System prompt contains time variables'), findsOneWidget);

    await tester.tap(find.text('Enable anyway'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('System prompt contains time variables'), findsNothing);
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isTrue);
  });

  testWidgets('enable gate: Go remove keeps the switch off', (tester) async {
    _seedPreferences(systemPrompt: 'Time: {cur_datetime}');
    await _openPromptsTab(tester);

    await tester.tap(find.byType(IosSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Go remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('System prompt contains time variables'), findsNothing);
    expect(tester.widget<IosSwitch>(find.byType(IosSwitch)).value, isFalse);
  });

  testWidgets('info dialog shows the appended time format', (tester) async {
    _seedPreferences();
    await _openPromptsTab(tester);

    await tester.tap(find.byIcon(Lucide.BadgeInfo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Appended time format'), findsOneWidget);
    expect(find.textContaining('(Mon 26-08-08 14:30:05)'), findsOneWidget);
  });

  testWidgets('inserts a variable at the end before the editor is focused', (
    tester,
  ) async {
    _seedPreferences(systemPrompt: 'first line is longer\nlast');
    await _openPromptsTab(tester);

    final editor = tester.widget<PlainTextCodeEditor>(
      find.byType(PlainTextCodeEditor).first,
    );
    expect(editor.focusNode?.hasFocus, isFalse);

    await tester.tap(find.text('{model_id}'));
    await tester.pump();

    expect(editor.controller.text, 'first line is longer\nlast{model_id}');

    await _tearDownEditorHarness(tester, focusNode: editor.focusNode);
  });

  testWidgets('keeps the editor selection when the variable chip takes focus', (
    tester,
  ) async {
    _seedPreferences(systemPrompt: 'first line\nsecond line');
    await _openPromptsTab(tester);

    final editorFinder = find.byType(PlainTextCodeEditor).first;
    final editor = tester.widget<PlainTextCodeEditor>(editorFinder);
    await tester.tap(editorFinder);
    await tester.pump();
    editor.controller.selection = CodeLineSelection.collapsed(
      index: 0,
      offset: 6,
    );
    await tester.pump();

    await tester.tap(find.text('{model_id}'));
    await tester.pump();

    expect(editor.controller.text, 'first {model_id}line\nsecond line');
    await _tearDownEditorHarness(tester, focusNode: editor.focusNode);
  });

  testWidgets(
    'resets focus history when switching assistants before variable insertion',
    (tester) async {
      _seedPreferences(includeSecond: true);
      final provider = await _createAssistantProvider(
        preferences: businessPrefs,
      );
      await tester.pumpWidget(
        _buildHarness(
          assistantProvider: provider,
          child: const AssistantSettingsEditPage(assistantId: _assistantId),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Prompts'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 600));

      final firstEditor = find.byType(PlainTextCodeEditor).first;
      await tester.tap(firstEditor);
      await tester.pump();

      await tester.pumpWidget(
        _buildHarness(
          assistantProvider: provider,
          child: const AssistantSettingsEditPage(
            assistantId: _secondAssistantId,
          ),
        ),
      );
      await tester.pump();

      final secondEditor = tester.widget<PlainTextCodeEditor>(
        find.byType(PlainTextCodeEditor).first,
      );
      expect(secondEditor.focusNode?.hasFocus, isFalse);
      await tester.tap(find.text('{model_id}'));
      await tester.pump();

      expect(secondEditor.controller.text, 'second original{model_id}');
      await _tearDownEditorHarness(tester, focusNode: secondEditor.focusNode);
    },
  );

  testWidgets('switching assistants does not rewrite CRLF prompts', (
    tester,
  ) async {
    const crlfPrompt = 'first line\r\nlast';
    _seedPreferences(includeSecond: true, secondSystemPrompt: crlfPrompt);
    final provider = await _createAssistantProvider(preferences: businessPrefs);
    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: provider,
        child: const AssistantSettingsEditPage(assistantId: _assistantId),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Prompts'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: provider,
        child: const AssistantSettingsEditPage(assistantId: _secondAssistantId),
      ),
    );
    await tester.pump(const Duration(milliseconds: 900));

    final editor = tester.widget<PlainTextCodeEditor>(
      find.byType(PlainTextCodeEditor).first,
    );
    expect(editor.controller.text, crlfPrompt);
    expect(provider.getById(_secondAssistantId)?.systemPrompt, crlfPrompt);

    await _tearDownEditorHarness(tester, focusNode: editor.focusNode);
  });

  testWidgets('flushes pending prompt when the page is disposed', (
    tester,
  ) async {
    _seedPreferences();
    final provider = await _createAssistantProvider(preferences: businessPrefs);
    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: provider,
        child: const AssistantSettingsEditPage(assistantId: _assistantId),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Prompts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600));

    final editor = tester.widget<PlainTextCodeEditor>(
      find.byType(PlainTextCodeEditor).first,
    );
    editor.controller.text = 'saved before leaving';
    await tester.pump();
    await _tearDownEditorHarness(tester, focusNode: editor.focusNode);

    expect(
      provider.getById(_assistantId)?.systemPrompt,
      'saved before leaving',
    );
  });

  testWidgets('flushes pending prompt to the previous assistant on switch', (
    tester,
  ) async {
    _seedPreferences(includeSecond: true);
    final provider = await _createAssistantProvider(preferences: businessPrefs);
    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: provider,
        child: const AssistantSettingsEditPage(assistantId: _assistantId),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Prompts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600));

    final editor = tester.widget<PlainTextCodeEditor>(
      find.byType(PlainTextCodeEditor).first,
    );
    editor.controller.text = 'assistant one pending';
    await tester.pump();
    await tester.pumpWidget(
      _buildHarness(
        assistantProvider: provider,
        child: const AssistantSettingsEditPage(assistantId: _secondAssistantId),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      provider.getById(_assistantId)?.systemPrompt,
      'assistant one pending',
    );
    expect(
      provider.getById(_secondAssistantId)?.systemPrompt,
      'second original',
    );

    await _tearDownEditorHarness(tester, focusNode: editor.focusNode);
  });

  testWidgets('keeps imported CRLF line endings after a later edit', (
    tester,
  ) async {
    const imported = 'a\r\nb';
    _seedPreferences(systemPrompt: 'lf only');
    final picker = _FakeFilePicker(
      FilePickerResult([
        PlatformFile(
          name: 'prompt.txt',
          size: imported.length,
          bytes: utf8.encode(imported),
        ),
      ]),
    );
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = _FakeFilePicker(null));

    final provider = await _openPromptsTab(tester);

    await tester.tap(find.text('Import file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(picker.pickFilesCalls, 1);
    // The import itself already persists the picked bytes.
    expect(provider.getById(_assistantId)?.systemPrompt, imported);

    // The editor document is what the *next* edit persists, so editing after
    // the import must not silently normalise the CRLF bytes to LF.
    final editor = tester.widget<PlainTextCodeEditor>(
      find.byType(PlainTextCodeEditor).first,
    );
    final controller = editor.controller;
    controller.selection = CodeLineSelection.collapsed(
      index: controller.lineCount - 1,
      offset: controller.codeLines[controller.lineCount - 1].text.length,
    );
    await tester.pump();
    controller.replaceSelection('X');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    // Let the debounced save, the import confirmation toast and re_editor's
    // one-shot timers all run out while the tree is still mounted.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(provider.getById(_assistantId)?.systemPrompt, 'a\r\nbX');

    await _tearDownEditorHarness(tester, focusNode: editor.focusNode);
  });

  testWidgets('keeps CRLF line endings applied from the full screen editor', (
    tester,
  ) async {
    const applied = 'a\r\nb';
    _seedPreferences(systemPrompt: 'lf only');
    final provider = await _openPromptsTab(tester);

    await tester.tap(find.byIcon(Lucide.Maximize2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).last, applied);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(provider.getById(_assistantId)?.systemPrompt, applied);

    final editor = tester.widget<PlainTextCodeEditor>(
      find.byType(PlainTextCodeEditor).first,
    );
    final controller = editor.controller;
    controller.selection = CodeLineSelection.collapsed(
      index: controller.lineCount - 1,
      offset: controller.codeLines[controller.lineCount - 1].text.length,
    );
    await tester.pump();
    controller.replaceSelection('X');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();

    expect(provider.getById(_assistantId)?.systemPrompt, 'a\r\nbX');

    await _tearDownEditorHarness(tester, focusNode: editor.focusNode);
  });
}
