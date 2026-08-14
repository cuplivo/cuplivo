import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/web_transcript/web_transcript_models.dart';
import 'package:Cuplivo/features/chat/web_transcript/web_transcript_projection.dart';

Future<SettingsProvider> _settings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = SettingsProvider();
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return settings;
}

const labels = WebTranscriptLabels(
  user: 'User',
  assistant: 'Assistant',
  resend: 'Resend',
  regenerate: 'Regenerate',
  translate: 'Translate',
  speak: 'Speak',
  edit: 'Edit',
  more: 'More',
  previousVersion: 'Previous version',
  nextVersion: 'Next version',
  reasoning: 'Reasoning',
  toolCall: 'Tool Call: {name}',
  arguments: 'Arguments',
  result: 'Result',
  noResult: 'No result',
  translation: 'Translation',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('projects visual content without exposing attachment paths', () async {
    final settings = await _settings();
    addTearDown(settings.dispose);
    final message = ChatMessage(
      id: 'm1',
      role: 'user',
      content:
          'hello\n[image:/managed/images/a.png]\n'
          '[file:/managed/upload/a.pdf|a.pdf|application/pdf]',
      conversationId: 'c1',
    );

    final snapshot = WebTranscriptProjection.build(
      conversationId: 'c1',
      messages: <ChatMessage>[message],
      settings: settings,
      labels: labels,
      resolveAssistant: (_) => null,
      byGroup: <String, List<ChatMessage>>{
        message.groupId!: <ChatMessage>[message],
      },
      versionSelections: const <String, int>{},
      reasoning: const <String, List<WebTranscriptReasoning>>{},
      tools: const <String, List<WebTranscriptTool>>{},
      splits: const <String, WebTranscriptSplits>{},
      formatTimestamp: (_) => 'time',
      selectedItems: const <String>{},
      collapsedTranslations: const <String>{},
      selecting: false,
      hasMoreBefore: false,
      hasMoreAfter: false,
    );

    final json = snapshot.messages.single.toJson().toString();
    expect(json, isNot(contains('/managed/')));
    expect(snapshot.resources, hasLength(2));
    expect(snapshot.messages.single.markdown, contains('cuplivo-resource://'));
  });

  test(
    'interleaves reasoning and tools and carries suggestion intent',
    () async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      final message = ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'before after',
        conversationId: 'c1',
      );

      final snapshot = WebTranscriptProjection.build(
        conversationId: 'c1',
        messages: <ChatMessage>[message],
        settings: settings,
        labels: labels,
        resolveAssistant: (_) => null,
        byGroup: <String, List<ChatMessage>>{
          message.groupId!: <ChatMessage>[message],
        },
        versionSelections: const <String, int>{},
        reasoning: const <String, List<WebTranscriptReasoning>>{
          'm1': <WebTranscriptReasoning>[
            WebTranscriptReasoning(text: 'why', expanded: true, loading: false),
          ],
        },
        tools: const <String, List<WebTranscriptTool>>{
          'm1': <WebTranscriptTool>[
            WebTranscriptTool(
              name: 'search',
              arguments: <String, dynamic>{'q': 'x'},
              content: 'found',
              loading: false,
            ),
          ],
        },
        splits: const <String, WebTranscriptSplits>{
          'm1': WebTranscriptSplits(
            offsets: <int>[6],
            reasoningCounts: <int>[1],
            toolCounts: <int>[1],
          ),
        },
        formatTimestamp: (_) => 'time',
        selectedItems: const <String>{},
        collapsedTranslations: const <String>{},
        selecting: false,
        hasMoreBefore: false,
        hasMoreAfter: false,
        suggestions: const <String>['Continue'],
      );

      final projected = snapshot.messages.single;
      expect(
        projected.markdown.indexOf('before'),
        lessThan(projected.markdown.indexOf('why')),
      );
      expect(projected.markdown, contains('Tool Call: search'));
      expect(
        projected.markdown.indexOf('found'),
        lessThan(projected.markdown.lastIndexOf('after')),
      );
      expect(
        projected.actions,
        contains(
          isA<WebTranscriptAction>()
              .having((action) => action.type, 'type', 'suggestion')
              .having((action) => action.value, 'value', 'Continue'),
        ),
      );
    },
  );

  test('assistant projection uses think-stripped visual content', () async {
    final settings = await _settings();
    addTearDown(settings.dispose);
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'visible <think>hidden</think> tail',
      conversationId: 'c1',
    );
    final snapshot = WebTranscriptProjection.build(
      conversationId: 'c1',
      messages: <ChatMessage>[message],
      settings: settings,
      labels: labels,
      resolveAssistant: (_) => null,
      byGroup: <String, List<ChatMessage>>{
        message.groupId!: <ChatMessage>[message],
      },
      versionSelections: const <String, int>{},
      reasoning: const <String, List<WebTranscriptReasoning>>{},
      tools: const <String, List<WebTranscriptTool>>{},
      splits: const <String, WebTranscriptSplits>{},
      formatTimestamp: (_) => 'time',
      selectedItems: const <String>{},
      collapsedTranslations: const <String>{},
      selecting: false,
      hasMoreBefore: false,
      hasMoreAfter: false,
    );
    expect(snapshot.messages.single.markdown, isNot(contains('hidden')));
  });

  test(
    'disabled user Markdown keeps attachment rendering but escapes text',
    () async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await settings.setEnableUserMarkdown(false);
      final message = ChatMessage(
        id: 'm1',
        role: 'user',
        content: '**literal** [image:/managed/images/a.png]',
        conversationId: 'c1',
      );
      final snapshot = WebTranscriptProjection.build(
        conversationId: 'c1',
        messages: <ChatMessage>[message],
        settings: settings,
        labels: labels,
        resolveAssistant: (_) => null,
        byGroup: <String, List<ChatMessage>>{
          message.groupId!: <ChatMessage>[message],
        },
        versionSelections: const <String, int>{},
        reasoning: const <String, List<WebTranscriptReasoning>>{},
        tools: const <String, List<WebTranscriptTool>>{},
        splits: const <String, WebTranscriptSplits>{},
        formatTimestamp: (_) => 'time',
        selectedItems: const <String>{},
        collapsedTranslations: const <String>{},
        selecting: false,
        hasMoreBefore: false,
        hasMoreAfter: false,
      );
      expect(snapshot.messages.single.markdown, startsWith(r'\*\*literal\*\*'));
      expect(
        snapshot.messages.single.markdown,
        contains('cuplivo-resource://'),
      );
      expect(snapshot.messages.single.format, 'markdown');
    },
  );
}
