import 'package:Cuplivo/core/services/api/message_authorship.dart';
import 'package:Cuplivo/core/services/api/native_input_attachments.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/models/model_spec.dart';
import 'package:Cuplivo/core/services/api/providers/openai/chat_completions_api.dart';
import 'package:flutter_test/flutter_test.dart';

final _nativeInputs = NativeInputAttachments(
  config: ProviderConfig(
    id: 'test',
    enabled: true,
    name: 'test',
    apiKey: '',
    baseUrl: 'https://api.example.com/v1',
  ),
  spec: ModelSpec(id: 'test', displayName: 'test'),
  protocol: NativeInputProtocol.chatCompletions,
);

void main() {
  test('a group peer marker never reaches the request body', () async {
    final messages = await buildOpenAIChatCompletionMessages(
      [
        <String, dynamic>{'role': 'user', 'content': 'plan the week'},
        <String, dynamic>{
          'role': 'user',
          'content': '<group_message from="Bob">\nTuesday\n</group_message>',
          groupPeerSenderKey: 'a2',
        },
        <String, dynamic>{'role': 'assistant', 'content': ''},
      ],
      nativeInputs: _nativeInputs,
      canImageInput: false,
      allowRemoteImages: false,
      reasoningReplay: ReasoningReplayPolicy.none,
      skipImageParsing: true,
    );

    expect(messages, hasLength(3));
    expect(messages.any((m) => m.containsKey(groupPeerSenderKey)), isFalse);
    // The peers' words survive as plain user text.
    expect(messages[1]['role'], 'user');
    expect(
      messages[1]['content'],
      '<group_message from="Bob">\nTuesday\n</group_message>',
    );
  });

  test('skipImageParsing leaves markdown images as plain text', () async {
    const raw = 'see ![x](data:image/png;base64,abc) later';
    final messages = await buildOpenAIChatCompletionMessages(
      [
        <String, dynamic>{'role': 'user', 'content': raw},
      ],
      nativeInputs: _nativeInputs,
      canImageInput: true,
      allowRemoteImages: true,
      reasoningReplay: ReasoningReplayPolicy.none,
      skipImageParsing: true,
    );

    expect(messages, hasLength(1));
    expect(messages.single['content'], raw);
    expect(messages.single['content'], isA<String>());
  });

  test('markdown images are extracted when parsing is enabled', () async {
    const raw = 'see ![x](data:image/png;base64,abc) later';
    final messages = await buildOpenAIChatCompletionMessages(
      [
        <String, dynamic>{'role': 'user', 'content': raw},
      ],
      nativeInputs: _nativeInputs,
      canImageInput: true,
      allowRemoteImages: false,
      reasoningReplay: ReasoningReplayPolicy.none,
    );

    final content = messages.single['content'];
    expect(content, isA<List>());
    final parts = (content as List).cast<Map>();
    expect(parts.any((part) => part['type'] == 'image_url'), isTrue);
    expect(
      parts.where((part) => part['type'] == 'text').map((part) => part['text']),
      isNot(contains(contains('!['))),
    );
  });

  test(
    'skipImageParsing keeps remote markdown images out of image_url parts',
    () async {
      const raw = 'doc ![pic](https://example.invalid/pic.jpg) end';
      final messages = await buildOpenAIChatCompletionMessages(
        [
          <String, dynamic>{'role': 'user', 'content': raw},
        ],
        nativeInputs: _nativeInputs,
        canImageInput: true,
        allowRemoteImages: true,
        reasoningReplay: ReasoningReplayPolicy.none,
        skipImageParsing: true,
      );

      expect(messages.single['content'], raw);
    },
  );

  test(
    'signed reasoning_details strip the parallel text echo without a model-id check',
    () async {
      final messages = await buildOpenAIChatCompletionMessages(
        [
          <String, dynamic>{
            'role': 'assistant',
            'content': 'ok',
            'reasoning_content': 'unsigned echo',
            'reasoning_details': [
              {
                'type': 'reasoning.text',
                'text': 'think',
                'signature': 'sig-1',
                'format': 'anthropic-claude-v1',
              },
            ],
          },
        ],
        nativeInputs: _nativeInputs,
        canImageInput: false,
        allowRemoteImages: false,
        reasoningReplay: ReasoningReplayPolicy.all,
      );

      expect(messages.single.containsKey('reasoning_content'), isFalse);
      expect(messages.single['reasoning_details'], [
        {
          'type': 'reasoning.text',
          'text': 'think',
          'signature': 'sig-1',
          'format': 'anthropic-claude-v1',
        },
      ]);
    },
  );
}
