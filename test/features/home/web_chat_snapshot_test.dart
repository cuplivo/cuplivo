import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/chat/models/tool_ui_part.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';
import 'package:Cuplivo/features/home/webview/web_chat_snapshot.dart';

void main() {
  test('snapshot keeps compatibility transforms and live domain state', () {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: '<think>legacy thought</think>Visible answer',
      conversationId: 'c1',
      groupId: 'g1',
      version: 1,
      translation: 'Translated answer',
      isStreaming: true,
      timestamp: DateTime(2026, 8, 26, 12, 34, 56),
    );
    final reasoning = stream_ctrl.ReasoningData()
      ..text = 'live thought'
      ..expanded = true;
    final snapshot = const WebChatSnapshotBuilder().build(
      renderSessionId: 's1',
      conversationId: 'c1',
      renderRevision: 2,
      actionEpoch: 3,
      messages: <ChatMessage>[message],
      byGroup: <String, List<ChatMessage>>{
        'g1': <ChatMessage>[message],
      },
      versionSelections: <String, int>{'g1': 1},
      reasoning: <String, stream_ctrl.ReasoningData>{'m1': reasoning},
      reasoningSegments:
          const <String, List<stream_ctrl.ReasoningSegmentData>>{},
      contentSplits: const <String, stream_ctrl.ContentSplitData>{},
      toolParts: const <String, List<ToolUIPart>>{
        'm1': <ToolUIPart>[
          ToolUIPart(
            id: 'tool-1',
            toolName: 'search',
            arguments: <String, dynamic>{'query': 'Cuplivo'},
            loading: true,
          ),
        ],
      },
      selectedItems: const <String>{'m1'},
      selecting: true,
      truncCollapsedIndex: 0,
      suggestions: const <String>['Continue'],
      hasMoreBefore: true,
      hasMoreAfter: false,
      strings: const <String, String>{'copy': 'Copy'},
      theme: const <String, String>{'surface': '#ffffff'},
      user: const <String, dynamic>{
        'name': 'Ada',
        'avatarType': 'emoji',
        'avatarLabel': '🦊',
      },
      display: const <String, dynamic>{
        'backgroundStyle': 'frosted',
        'backgroundOwner': 'flutter',
        'showUserMessageActions': true,
        'showTokenStats': true,
      },
      topContentPadding: 72,
      bottomContentPadding: 104,
      assistant: Assistant(
        id: 'a1',
        name: 'Assistant',
        avatar: r'\\server\share\assistant.png',
        background: '/private/background.jpg',
        useAssistantAvatar: true,
      ),
      fontScale: 1,
      canStartMultiAI: true,
      autoCollapseThinking: true,
      locale: 'zh-Hans',
      textDirection: 'ltr',
      liveTranslationMessageIds: const <String>{'m1'},
      initialViewportAnchor: const <String, dynamic>{
        'messageId': 'm1',
        'offset': -16.0,
      },
    );

    final rendered = (snapshot['messages'] as List).single as Map;
    expect(snapshot['protocolVersion'], 4);
    expect(snapshot['assetVersion'], 'web-chat-v18');
    expect(snapshot['initialViewportMode'], 'anchor');
    expect(snapshot['locale'], 'zh-Hans');
    expect(snapshot['textDirection'], 'ltr');
    expect(snapshot['initialViewportAnchor'], <String, dynamic>{
      'messageId': 'm1',
      'offset': -16.0,
    });
    expect((snapshot['user'] as Map)['name'], 'Ada');
    expect((snapshot['display'] as Map)['backgroundStyle'], 'frosted');
    expect((snapshot['display'] as Map)['backgroundOwner'], 'flutter');
    expect((snapshot['display'] as Map)['contentInsets'], <String, double>{
      'top': 72,
      'bottom': 104,
    });
    expect((snapshot['assistant'] as Map)['avatar'], startsWith('local:'));
    expect((snapshot['assistant'] as Map)['avatar'], isNot(contains('server')));
    expect((snapshot['assistant'] as Map)['background'], startsWith('local:'));
    expect(
      (snapshot['assistant'] as Map)['background'],
      isNot(contains('/private')),
    );
    expect(rendered['content'], 'Visible answer');
    expect(rendered['timestampLabel'], '2026-08-26 12:34:56');
    expect(rendered['translationStreaming'], isTrue);
    final renderedReasoning = (rendered['reasoning'] as List).single as Map;
    expect(renderedReasoning['text'], 'live thought');
    expect(renderedReasoning['kind'], 'single');
    expect(renderedReasoning['index'], 0);
    expect(renderedReasoning['key'], 'm1:reasoning:single:0');
    expect(rendered['actions'], isEmpty);
    expect((rendered['tools'] as List).single['toolName'], 'search');
    expect(rendered['selected'], isTrue);
    expect(rendered['showContextDivider'], isTrue);
  });

  test(
    'snapshot emits only typed appearance fields and never raw style JSON',
    () {
      final snapshot = _minimalWebChatSnapshot(
        const <ChatMessage>[],
        appearance: <String, dynamic>{
          'userBubble': <String, dynamic>{
            'backgroundColor': '#112233AA',
            'cornerRadius': 18,
            'accentColor': '#FFFFFF',
            'unknown': '<style>body{display:none}</style>',
          },
          'assistantBubble': <String, dynamic>{
            'maxWidthPercent': 85,
            'backgroundColor': 'url(https://example.com/x)',
          },
          'processCard': <String, dynamic>{
            'accentColor': '#445566',
            'maxWidthPercent': 70,
          },
          'raw': <String, dynamic>{'unknown': true},
        },
      );

      expect(snapshot['appearance'], <String, dynamic>{
        'userBubble': <String, dynamic>{
          'backgroundColor': '#112233AA',
          'cornerRadius': 18.0,
        },
        'assistantBubble': <String, dynamic>{'maxWidthPercent': 85.0},
        'processCard': <String, dynamic>{'accentColor': '#445566'},
      });
      final encoded = jsonEncode(snapshot);
      expect(encoded, isNot(contains('<style>')));
      expect(encoded, isNot(contains('example.com')));
      expect(encoded, isNot(contains('"raw"')));
    },
  );

  test('snapshot defaults a fresh conversation to the bottom edge', () {
    final snapshot = const WebChatSnapshotBuilder().build(
      renderSessionId: 'fresh',
      conversationId: 'c1',
      renderRevision: 1,
      actionEpoch: 1,
      messages: const <ChatMessage>[],
      byGroup: const <String, List<ChatMessage>>{},
      versionSelections: const <String, int>{},
      reasoning: const <String, stream_ctrl.ReasoningData>{},
      reasoningSegments:
          const <String, List<stream_ctrl.ReasoningSegmentData>>{},
      contentSplits: const <String, stream_ctrl.ContentSplitData>{},
      toolParts: const <String, List<ToolUIPart>>{},
      selectedItems: const <String>{},
      selecting: false,
      truncCollapsedIndex: -1,
      suggestions: const <String>[],
      hasMoreBefore: false,
      hasMoreAfter: false,
      strings: const <String, String>{},
      theme: const <String, String>{},
      user: const <String, dynamic>{'name': 'User'},
      display: const <String, dynamic>{},
      topContentPadding: 0,
      bottomContentPadding: 0,
      assistant: null,
      fontScale: 1,
      canStartMultiAI: false,
      autoCollapseThinking: true,
    );

    expect(snapshot['initialViewportMode'], 'bottom');
    expect(snapshot, isNot(contains('initialViewportAnchor')));
  });

  test('snapshot distinguishes segmented and local legacy reasoning', () {
    final segmented = ChatMessage(
      id: 'segment-message',
      role: 'assistant',
      content: 'Segment answer',
      conversationId: 'c1',
    );
    final legacy = ChatMessage(
      id: 'legacy-message',
      role: 'assistant',
      content: '<think>legacy thought</think>Legacy answer',
      conversationId: 'c1',
    );
    final segment = stream_ctrl.ReasoningSegmentData()
      ..text = 'segment thought'
      ..expanded = false;
    final snapshot = const WebChatSnapshotBuilder().build(
      renderSessionId: 's1',
      conversationId: 'c1',
      renderRevision: 1,
      actionEpoch: 1,
      messages: <ChatMessage>[segmented, legacy],
      byGroup: const <String, List<ChatMessage>>{},
      versionSelections: const <String, int>{},
      reasoning: const <String, stream_ctrl.ReasoningData>{},
      reasoningSegments: <String, List<stream_ctrl.ReasoningSegmentData>>{
        segmented.id: <stream_ctrl.ReasoningSegmentData>[segment],
      },
      contentSplits: const <String, stream_ctrl.ContentSplitData>{},
      toolParts: const <String, List<ToolUIPart>>{},
      selectedItems: const <String>{},
      selecting: false,
      truncCollapsedIndex: -1,
      suggestions: const <String>[],
      hasMoreBefore: false,
      hasMoreAfter: false,
      strings: const <String, String>{},
      theme: const <String, String>{},
      user: const <String, dynamic>{'name': 'User'},
      display: const <String, dynamic>{'showUserMessageActions': false},
      topContentPadding: 0,
      bottomContentPadding: 0,
      assistant: null,
      fontScale: 1,
      canStartMultiAI: false,
      autoCollapseThinking: true,
    );

    final messages = snapshot['messages'] as List;
    final segmentedReasoning =
        ((messages.first as Map)['reasoning'] as List).single as Map;
    final legacyReasoning =
        ((messages.last as Map)['reasoning'] as List).single as Map;

    expect(segmentedReasoning['kind'], 'segment');
    expect(segmentedReasoning['key'], 'segment-message:reasoning:segment:0');
    expect(segmentedReasoning['expanded'], isFalse);
    expect((messages.first as Map)['actions'], <String>[
      'copy',
      'regenerate',
      'speak',
      'translate',
      'more',
    ]);
    expect(legacyReasoning['kind'], 'legacy');
    expect(legacyReasoning['key'], 'legacy-message:reasoning:legacy:0');
    expect(legacyReasoning['expanded'], isFalse);
  });

  test('attachment parser emits opaque handles for local paths', () {
    final attachments = parseWebChatAttachments(
      '[image:/private/photo.png]\n[file:C:\\doc.pdf|Doc|application/pdf]',
    );

    expect(attachments, hasLength(2));
    expect(attachments.first['reference'], startsWith('local:'));
    expect(attachments.first['reference'], isNot(contains('/private')));
    expect(attachments.last['name'], 'Doc');
  });

  test(
    'complete snapshots strip local attachment markers from Web strings',
    () {
      final message = ChatMessage(
        id: 'private-paths',
        role: 'assistant',
        content:
            'Answer\n[image:/private/photo.png]\n'
            r'[file:C:\sensitive\doc.pdf|Doc|application/pdf]',
        translation: r'Translated [image:D:\translation-only.png]',
        conversationId: 'c1',
      );
      final reasoning = stream_ctrl.ReasoningData()
        ..text = 'Thought [file:/private/reasoning.txt|Reasoning|text/plain]';
      final snapshot = _minimalWebChatSnapshot(
        <ChatMessage>[message],
        reasoning: <String, stream_ctrl.ReasoningData>{message.id: reasoning},
        toolParts: <String, List<ToolUIPart>>{
          message.id: const <ToolUIPart>[
            ToolUIPart(
              id: 'tool',
              toolName: 'read_file',
              arguments: <String, dynamic>{},
              content: 'Tool output [image:/private/tool.png]',
            ),
          ],
        },
      );

      final rendered = (snapshot['messages'] as List).single as Map;
      final serialized = jsonEncode(snapshot);
      expect(rendered['content'], 'Answer');
      expect(rendered['translation'], 'Translated');
      expect((rendered['reasoning'] as List).single['text'], 'Thought');
      expect((rendered['tools'] as List).single['content'], 'Tool output');
      expect((rendered['attachments'] as List), hasLength(2));
      expect(serialized, isNot(contains('/private')));
      expect(serialized, isNot(contains('sensitive')));
      expect(serialized, isNot(contains('translation-only')));
    },
  );

  test('HTML preview registry binds current fences to their messages', () {
    const sharedSource = '<button onclick="counter++">Run</button>';
    final first = ChatMessage(
      id: 'html-first',
      role: 'assistant',
      content:
          '```html\r\n$sharedSource\r\n```\n'
          '  ```html\n  <p>Indented preview</p>\n  ```\n'
          '```dart\n<div>not HTML</div>\n```\n'
          '    ```html\n    <p>not a fence</p>\n    ```',
      translation: '~~~HTML\n<p>Translated preview</p>\n~~~',
      conversationId: 'c1',
    );
    final second = ChatMessage(
      id: 'html-second',
      role: 'assistant',
      content: '```html\n$sharedSource\n```',
      conversationId: 'c1',
    );
    final snapshot = _minimalWebChatSnapshot(<ChatMessage>[first, second]);
    final registry = buildWebChatHtmlPreviewRegistry(snapshot);

    final firstHandle = webChatHtmlPreviewHandle(first.id, sharedSource);
    final secondHandle = webChatHtmlPreviewHandle(second.id, sharedSource);
    expect(firstHandle, isNot(secondHandle));
    expect(registry[firstHandle]?.messageId, first.id);
    expect(registry[secondHandle]?.messageId, second.id);
    expect(
      registry.values.map((entry) => entry.source),
      contains('<p>Translated preview</p>'),
    );
    expect(
      registry.values.map((entry) => entry.source),
      contains('<p>Indented preview</p>'),
    );
    expect(
      registry.values.map((entry) => entry.source),
      isNot(contains('<div>not HTML</div>')),
    );
    expect(
      registry.values.map((entry) => entry.source),
      isNot(contains('<p>not a fence</p>')),
    );
    expect(
      resolveWebChatHtmlPreviewSource(
        messageId: first.id,
        rawSource: '$sharedSource\n',
        registry: registry,
      ).source,
      sharedSource,
    );
    expect(
      () => resolveWebChatHtmlPreviewSource(
        messageId: first.id,
        rawSource: '<p>forged</p>',
        registry: registry,
      ),
      throwsA(isA<WebChatProtocolException>()),
    );
    expect(
      () => resolveWebChatHtmlPreviewSource(
        messageId: second.id,
        rawSource: '<p>Translated preview</p>',
        registry: registry,
      ),
      throwsA(isA<WebChatProtocolException>()),
    );
  });

  test('HTML preview registry rejects over-limit fences and actions', () {
    final oversized = List<String>.filled(
      webChatMaxHtmlPreviewCodeUnits + 1,
      'x',
    ).join();
    final registry = <String, WebChatHtmlPreviewSource>{};
    registerWebChatHtmlPreviews(
      messageId: 'oversized',
      serialized: <String, dynamic>{'content': '```html\n$oversized\n```'},
      registry: registry,
    );

    expect(registry, isEmpty);
    expect(
      () => resolveWebChatHtmlPreviewSource(
        messageId: 'oversized',
        rawSource: oversized,
        registry: registry,
      ),
      throwsA(isA<WebChatProtocolException>()),
    );
  });

  test('streaming HTML preview registry replaces stale message sources', () {
    const contentSource = '<p>Current answer</p>';
    const oldTranslationSource = '<p>Old translation</p>';
    const newTranslationSource = '<p>New translation</p>';
    final registry = <String, WebChatHtmlPreviewSource>{};
    final serialized = <String, dynamic>{
      'content': '```html\n$contentSource\n```',
      'translation': '```html\n$oldTranslationSource\n```',
    };
    registerWebChatHtmlPreviews(
      messageId: 'streaming',
      serialized: serialized,
      registry: registry,
    );
    serialized['translation'] = '```html\n$newTranslationSource\n```';

    replaceWebChatHtmlPreviews(
      messageId: 'streaming',
      serialized: serialized,
      registry: registry,
    );

    final sources = registry.values.map((entry) => entry.source).toSet();
    expect(sources, contains(contentSource));
    expect(sources, contains(newTranslationSource));
    expect(sources, isNot(contains(oldTranslationSource)));
  });

  test('HTML preview registry excludes content that is still streaming', () {
    final streaming = ChatMessage(
      id: 'streaming-html',
      role: 'assistant',
      content: '```html\n<p>Partial</p>\n```',
      conversationId: 'c1',
      isStreaming: true,
    );
    final snapshot = _minimalWebChatSnapshot(<ChatMessage>[streaming]);
    final registry = buildWebChatHtmlPreviewRegistry(snapshot);
    registerWebChatHtmlPreviews(
      messageId: 'translation',
      serialized: <String, dynamic>{
        'content': '```html\n<p>Stable answer</p>\n```',
        'translation': '```html\n<p>Partial translation</p>\n```',
        'translationStreaming': true,
      },
      registry: registry,
    );

    expect(
      registry.values.map((entry) => entry.source),
      contains('<p>Stable answer</p>'),
    );
    expect(
      registry.values.map((entry) => entry.source),
      isNot(contains('<p>Partial</p>')),
    );
    expect(
      registry.values.map((entry) => entry.source),
      isNot(contains('<p>Partial translation</p>')),
    );
  });

  test('media registry keeps local and bundled asset paths opaque', () {
    final message = ChatMessage(
      id: 'model-message',
      role: 'assistant',
      content: '[image:/private/photo.png]',
      conversationId: 'c1',
      modelId: 'gpt-5',
      providerId: 'openai',
    );

    final registry = buildWebChatMediaRegistry(
      <ChatMessage>[message],
      assistant: Assistant(
        id: 'assistant',
        name: 'Assistant',
        avatar: r'\\server\share\assistant.png',
        background: '/private/background.webp',
      ),
      userAvatarType: 'file',
      userAvatarValue: '/private/avatar.png',
    );

    expect(registry.keys, everyElement(isNot(contains('/private'))));
    expect(
      registry.values.any(
        (source) => source.kind == WebChatMediaSourceKind.localFile,
      ),
      isTrue,
    );
    expect(
      registry.values.any(
        (source) => source.kind == WebChatMediaSourceKind.bundledAsset,
      ),
      isTrue,
    );
    expect(
      registry.values.any(
        (source) => source.value == r'\\server\share\assistant.png',
      ),
      isTrue,
    );
    expect(
      registry.values.any(
        (source) => source.value == '/private/background.webp',
      ),
      isTrue,
    );
  });

  test('HTTP media uses opaque remote handles and remains in the registry', () {
    const url = 'http://images.example.test/photo.png';
    final message = ChatMessage(
      id: 'remote-image',
      role: 'assistant',
      content: '![remote]($url)\n[image:$url]',
      conversationId: 'c1',
    );
    final plainLink = ChatMessage(
      id: 'plain-link',
      role: 'assistant',
      content: '[site](http://example.test/page)',
      conversationId: 'c1',
    );

    final registry = buildWebChatMediaRegistry(<ChatMessage>[
      message,
      plainLink,
    ]);
    final handle = webChatRemoteMediaHandle(url);

    expect(
      parseWebChatAttachments(message.content).single['reference'],
      handle,
    );
    expect(registry[handle]?.kind, WebChatMediaSourceKind.remoteImage);
    expect(registry[handle]?.value, url);
    expect(registry[handle]?.messageIds, contains(message.id));
    expect(
      registry.containsKey(
        webChatRemoteMediaHandle('http://example.test/page'),
      ),
      isFalse,
    );
  });

  test('remote images inside tool Markdown join the active registry', () {
    const url = 'http://tools.example.test/result.webp';
    final message = ChatMessage(
      id: 'tool-message',
      role: 'assistant',
      content: 'Result',
      conversationId: 'c1',
    );

    final registry = buildWebChatMediaRegistry(
      <ChatMessage>[message],
      toolParts: const <String, List<ToolUIPart>>{
        'tool-message': <ToolUIPart>[
          ToolUIPart(
            id: 'tool',
            toolName: 'search_web',
            arguments: <String, dynamic>{},
            content: '![result](http://tools.example.test/result.webp)',
          ),
        ],
      },
    );

    expect(
      registry[webChatRemoteMediaHandle(url)]?.kind,
      WebChatMediaSourceKind.remoteImage,
    );
    expect(
      registry[webChatRemoteMediaHandle(url)]?.messageIds,
      contains(message.id),
    );
  });

  test('citation sources are structured, latest-first, and deduplicated', () {
    final sources = buildWebChatCitationSources(<ToolUIPart>[
      ToolUIPart(
        id: 'old',
        toolName: 'search_web',
        arguments: const <String, dynamic>{},
        content: jsonEncode(<String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'same',
              'index': 1,
              'title': 'Old title',
              'url': 'https://old.example.test',
            },
          ],
        }),
      ),
      ToolUIPart(
        id: 'new',
        toolName: 'builtin_search',
        arguments: const <String, dynamic>{},
        content: jsonEncode(<String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'same',
              'index': 1,
              'title': 'New title',
              'url': 'https://new.example.test',
              'snippet': 'Summary',
            },
            <String, dynamic>{
              'id': 'second',
              'index': '2',
              'title': 'Second',
              'url': 'https://second.example.test',
            },
          ],
        }),
      ),
    ]);

    expect(sources, hasLength(2));
    expect(sources.first['title'], 'New title');
    expect(sources.first['text'], 'Summary');
    expect(sources.last['id'], 'second');
    expect(
      buildWebChatCitationSources(const <ToolUIPart>[
        ToolUIPart(
          id: 'broken',
          toolName: 'search_web',
          arguments: <String, dynamic>{},
          content: '{broken',
        ),
      ]),
      isEmpty,
    );
  });
}

Map<String, dynamic> _minimalWebChatSnapshot(
  List<ChatMessage> messages, {
  Map<String, stream_ctrl.ReasoningData> reasoning =
      const <String, stream_ctrl.ReasoningData>{},
  Map<String, List<ToolUIPart>> toolParts = const <String, List<ToolUIPart>>{},
  Map<String, dynamic> appearance = const <String, dynamic>{},
}) => const WebChatSnapshotBuilder().build(
  renderSessionId: 'test-session',
  conversationId: 'c1',
  renderRevision: 1,
  actionEpoch: 1,
  messages: messages,
  byGroup: const <String, List<ChatMessage>>{},
  versionSelections: const <String, int>{},
  reasoning: reasoning,
  reasoningSegments: const <String, List<stream_ctrl.ReasoningSegmentData>>{},
  contentSplits: const <String, stream_ctrl.ContentSplitData>{},
  toolParts: toolParts,
  selectedItems: const <String>{},
  selecting: false,
  truncCollapsedIndex: -1,
  suggestions: const <String>[],
  hasMoreBefore: false,
  hasMoreAfter: false,
  strings: const <String, String>{},
  theme: const <String, String>{},
  appearance: appearance,
  user: const <String, dynamic>{'name': 'User'},
  display: const <String, dynamic>{},
  topContentPadding: 0,
  bottomContentPadding: 0,
  assistant: null,
  fontScale: 1,
  canStartMultiAI: false,
  autoCollapseThinking: true,
);
