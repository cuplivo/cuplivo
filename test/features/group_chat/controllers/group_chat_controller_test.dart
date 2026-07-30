import 'dart:async';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/group_chat_member.dart';
import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/group_chat_service.dart';
import 'package:Cuplivo/core/services/group_chat/group_chat_orchestrator.dart';
import 'package:Cuplivo/features/group_chat/controllers/group_chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GroupChatController', () {
    test('loads and restores the page snapshot', () async {
      final service = _FakeGroupChatService();
      final orchestrator = _FakeGroupChatOrchestrator(service);
      final restored = <List<GroupChatMessage>>[];
      final controller = GroupChatController(
        groupId: 'group-1',
        groupChatService: service,
        orchestrator: orchestrator,
        restoreMessageUiState: (messages) {
          restored.add(List<GroupChatMessage>.of(messages));
        },
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.isLoading, isFalse);
      expect(service.currentGroup, 'group-1');
      expect(controller.messages.single.content, 'hello');
      expect(controller.members, hasLength(2));
      expect(restored.single.single.id, 'message-1');
    });

    test('coalesces service notifications into a refreshed snapshot', () async {
      final service = _FakeGroupChatService();
      final orchestrator = _FakeGroupChatOrchestrator(service);
      final controller = GroupChatController(
        groupId: 'group-1',
        groupChatService: service,
        orchestrator: orchestrator,
        restoreMessageUiState: (_) {},
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      service.messages = <GroupChatMessage>[
        ...service.messages,
        GroupChatMessage(
          id: 'message-2',
          groupId: 'group-1',
          role: 'assistant',
          speakerAssistantId: 'assistant-1',
          content: 'updated',
          messageOrder: 1,
        ),
      ];
      service.emitChanged();
      service.emitChanged();
      await _settleAsyncWork();

      expect(controller.messages, hasLength(2));
      expect(controller.messages.last.content, 'updated');
    });

    test('tracks send state and forwards cancellation', () async {
      final service = _FakeGroupChatService();
      final orchestrator = _FakeGroupChatOrchestrator(service);
      final controller = GroupChatController(
        groupId: 'group-1',
        groupChatService: service,
        orchestrator: orchestrator,
        restoreMessageUiState: (_) {},
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      final send = controller.send('  user input  ');
      expect(controller.isSending, isTrue);
      expect(orchestrator.lastContent, 'user input');

      await controller.cancel();
      expect(orchestrator.cancelledGroupId, 'group-1');

      orchestrator.completeTurn();
      final result = await send;
      expect(result.isSuccess, isTrue);
      expect(controller.isSending, isFalse);
    });
  });
}

Future<void> _settleAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeGroupChatService extends GroupChatService {
  _FakeGroupChatService() : super();

  String? currentGroup;
  List<GroupChatMessage> messages = <GroupChatMessage>[
    GroupChatMessage(
      id: 'message-1',
      groupId: 'group-1',
      role: 'user',
      content: 'hello',
    ),
  ];
  List<GroupChatMember> members = <GroupChatMember>[
    GroupChatMember(groupId: 'group-1', kind: GroupChatMember.kindUser),
    GroupChatMember(
      groupId: 'group-1',
      kind: GroupChatMember.kindAssistant,
      assistantId: 'assistant-1',
      sortOrder: 1,
    ),
  ];

  @override
  Future<void> ensureLoaded() async {}

  @override
  void setCurrentGroup(String? id) {
    currentGroup = id;
  }

  @override
  Future<List<GroupChatMessage>> getMessages(String groupId) async =>
      List<GroupChatMessage>.of(messages);

  @override
  Future<List<GroupChatMember>> getMembers(String groupId) async =>
      List<GroupChatMember>.of(members);

  void emitChanged() => notifyListeners();
}

class _FakeGroupChatOrchestrator extends GroupChatOrchestrator {
  _FakeGroupChatOrchestrator(GroupChatService service)
    : super(
        groupChatService: service,
        resolveAssistant: (_) => null,
        resolveSettings: () => throw UnimplementedError(),
        prepareMemberGeneration:
            ({
              required String groupId,
              required List<GroupChatMessage> timeline,
              required Assistant assistant,
              required Map<String, String> assistantNames,
              required String providerKey,
              required String modelId,
              required SettingsProvider settings,
            }) => throw UnimplementedError(),
        runMemberStream:
            ({
              required GroupChatMessage placeholder,
              required Assistant assistant,
              required SettingsProvider settings,
              required String providerKey,
              required String modelId,
              required GroupMemberGenerationPreparation prepared,
              required GroupChatStreamFactory sendMessageStream,
              required bool Function() isCancelled,
            }) => throw UnimplementedError(),
      );

  Completer<GroupChatTurnResult>? _turnCompleter;
  bool running = false;
  String? lastContent;
  String? cancelledGroupId;

  @override
  bool isRunning(String groupId) => running;

  @override
  Future<GroupChatTurnResult> sendUserMessage({
    required String groupId,
    required String content,
  }) {
    lastContent = content;
    running = true;
    notifyListeners();
    final completer = Completer<GroupChatTurnResult>();
    _turnCompleter = completer;
    return completer.future.whenComplete(() {
      running = false;
      notifyListeners();
    });
  }

  @override
  Future<void> cancel(String groupId) async {
    cancelledGroupId = groupId;
  }

  void completeTurn() {
    _turnCompleter!.complete(
      GroupChatTurnResult(
        groupId: 'group-1',
        userMessage: GroupChatMessage(
          groupId: 'group-1',
          role: 'user',
          content: lastContent!,
        ),
        assistantMessages: const <GroupChatMessage>[],
        endedBy: 'end_round',
      ),
    );
  }
}
