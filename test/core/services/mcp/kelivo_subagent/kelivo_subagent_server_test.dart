import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/headless_generation_service.dart';
import 'package:Cuplivo/core/services/mcp/kelivo_subagent/kelivo_subagent_server.dart';

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAssistantProvider extends AssistantProvider {
  _FakeAssistantProvider(this._assistants) : super();

  final List<Assistant> _assistants;

  @override
  List<Assistant> get assistants => List.unmodifiable(_assistants);
}

class _FakeChatService extends ChatService {
  _FakeChatService();

  final messagesByConversation = <String, List<ChatMessage>>{};

  @override
  List<ChatMessage> getMessages(String conversationId) =>
      List.unmodifiable(messagesByConversation[conversationId] ?? const []);

  @override
  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
    List<String>? mcpServerIds,
    String? parentConversationId,
    String conversationKind = Conversation.kindNormal,
    bool setAsCurrent = true,
  }) async {
    return Conversation(
      id: 'conv-$_createdCount',
      title: title ?? 'Untitled',
      assistantId: assistantId,
      mcpServerIds: mcpServerIds,
      parentConversationId: parentConversationId,
      conversationKind: conversationKind,
    );
  }

  int _createdCount = 0;

  @override
  String? get currentConversationId => 'parent-conv';

  @override
  Future<ChatMessage> addMessage({
    required String conversationId,
    required String role,
    required String content,
    String? modelId,
    String? providerId,
    int? totalTokens,
    bool isStreaming = false,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? groupId,
    String? subgroupId,
    int? version,
    bool isPreset = false,
    String? speakerAssistantId,
  }) async {
    _createdCount++;
    final message = ChatMessage(
      id: 'msg-$_createdCount',
      role: role,
      content: content,
      conversationId: conversationId,
    );
    (messagesByConversation[conversationId] ??= []).add(message);
    return message;
  }
}

void main() {
  late _FakeChatService chatService;
  late _FakeAssistantProvider assistants;
  late HeadlessGenerationService headlessGen;
  late KelivoSubagentMcpServerEngine engine;

  Assistant discoverable(String handoffId, {String? description}) {
    return Assistant(
      id: 'assistant-$handoffId',
      name: 'Assistant $handoffId',
      discoverable: true,
      handoffId: handoffId,
      handoffDescription: description,
    );
  }

  setUp(() {
    chatService = _FakeChatService();
    assistants = _FakeAssistantProvider([
      discoverable('research-bot', description: 'researches topics'),
      discoverable('code-helper'),
    ]);
    headlessGen = HeadlessGenerationService(chatService: chatService);
    engine = KelivoSubagentMcpServerEngine(
      assistants: assistants,
      chatService: chatService,
      headlessGen: headlessGen,
      contextProvider: () => _FakeBuildContext(),
    );
  });

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final resp = await engine.handleMessage({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    });
    return (resp as Map).cast<String, dynamic>();
  }

  Map<String, dynamic> toolResultOf(Map<String, dynamic> response) {
    return (response['result'] as Map).cast<String, dynamic>();
  }

  String textOf(Map<String, dynamic> result) {
    final content = (result['content'] as List).first as Map;
    return (content['text'] ?? '').toString();
  }

  group('KelivoSubagentMcpServerEngine wait-mode', () {
    test('tools/list exposes both handoff and handoff_sync', () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
        'params': {},
      });
      final result = (resp as Map)['result'] as Map;
      final tools = (result['tools'] as List).cast<Map>();
      final names = tools.map((t) => t['name']).toList();
      expect(names, contains('kelivo_handoff'));
      expect(names, contains('kelivo_handoff_sync'));
    });

    test('handoff_sync rejects an empty task', () async {
      final resp = await callTool('kelivo_handoff_sync', {
        'assistant': 'research-bot',
        'task': '  ',
      });
      final result = toolResultOf(resp);
      expect(result['isError'], isTrue);
      expect(textOf(result), contains('task must not be empty'));
    });

    test(
      'handoff_sync rejects an unknown target and lists available ones',
      () async {
        final resp = await callTool('kelivo_handoff_sync', {
          'assistant': 'nope',
          'task': 'do the thing',
        });
        final result = toolResultOf(resp);
        expect(result['isError'], isTrue);
        expect(textOf(result), contains('research-bot'));
        expect(textOf(result), contains('code-helper'));
      },
    );

    test(
      'handoff_sync returns structured started JSON and creates the child',
      () async {
        final resp = await callTool('kelivo_handoff_sync', {
          'assistant': 'research-bot',
          'task': 'research flutter drift',
        });
        final result = toolResultOf(resp);
        expect(result['isError'], isNull);

        final decoded = jsonDecode(textOf(result)) as Map;
        expect(decoded['status'], 'started');
        expect(decoded['conversation'], isA<String>());
        expect(decoded['conversation'], isNotEmpty);

        // In this test env the generation pipeline fails synchronously and
        // failJob cleans up the record; the prepareJob-before-response
        // ordering guarantee is covered by the service-level tests.

        // The child conversation got the task as its first user message.
        final messages = chatService.getMessages(decoded['conversation']);
        expect(messages, isNotEmpty);
        expect(messages.first.role, 'user');
        expect(messages.first.content, 'research flutter drift');
      },
    );

    test('v1 handoff keeps its prose result shape', () async {
      final resp = await callTool('kelivo_handoff', {
        'assistant': 'research-bot',
        'task': 'quick task',
      });
      final result = toolResultOf(resp);
      expect(textOf(result), contains('Handoff dispatched. Conversation:'));
    });

    test('waiter resolves with an error when generation fails before '
        'starting — never hangs', () async {
      final resp = await callTool('kelivo_handoff_sync', {
        'assistant': 'research-bot',
        'task': 'research flutter drift',
      });
      final result = toolResultOf(resp);
      final decoded = jsonDecode(textOf(result)) as Map;

      // In this test env the generation pipeline fails synchronously
      // (the fake BuildContext throws on the first provider read). The
      // waiter must still resolve with an error, not hang forever.
      final waitResult = await headlessGen.waitFor(decoded['conversation']);
      expect(waitResult.cancelled, isFalse);
      expect(waitResult.error, isNotNull);
    });
  });
}
