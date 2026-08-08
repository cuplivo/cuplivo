import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/models/group_chat_director_log.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../home/controllers/generation_controller.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;
import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/message_generation_service.dart';
import '../../home/services/message_pipeline.dart';
import '../../home/services/tool_approval_service.dart';
import '../services/assistant_private_context_builder.dart';
import '../services/director_context_builder.dart';
import '../services/director_runner.dart';
import '../services/director_tool_protocol.dart';
import 'group_chat_stream_executor.dart';

typedef GroupChatUiFeedback = void Function(String messageKey);

/// Orchestrates user → director → assistant turns for one group chat session.
class GroupChatOrchestrator {
  GroupChatOrchestrator({
    required this.chatService,
    required this.groupChatProvider,
    required this.assistantProvider,
    required this.settingsProvider,
    required this.userProvider,
    required this.streamController,
    required this.generationController,
    required this.messageGenerationService,
    required this.streamExecutor,
    required this.approvalService,
    required this.askUserService,
    required this.onUiFeedback,
    required this.onMessagesChanged,
  }) {
    _contextBuilder = DirectorContextBuilder(chatService: chatService);
    _privateBuilder = AssistantPrivateContextBuilder(chatService: chatService);
    _directorRunner = DirectorRunner(
      chatService: chatService,
      contextBuilder: _contextBuilder,
    );
    _pipeline = MessagePipeline(
      chatService: chatService,
      messageGenerationService: messageGenerationService,
      streamController: streamController,
      generationController: generationController,
      executeStream: streamExecutor.executeStream,
    );
  }

  final ChatService chatService;
  final GroupChatProvider groupChatProvider;
  final AssistantProvider assistantProvider;
  final SettingsProvider settingsProvider;
  final UserProvider userProvider;
  final stream_ctrl.StreamController streamController;
  final GenerationController generationController;
  final MessageGenerationService messageGenerationService;
  final GroupChatStreamExecutor streamExecutor;
  final ToolApprovalService? approvalService;
  final AskUserInteractionService? askUserService;
  final GroupChatUiFeedback onUiFeedback;
  final VoidCallback onMessagesChanged;

  late final DirectorContextBuilder _contextBuilder;
  late final AssistantPrivateContextBuilder _privateBuilder;
  late final DirectorRunner _directorRunner;
  late final MessagePipeline _pipeline;

  bool _busy = false;
  bool _stopRequested = false;
  String? _activeStreamKey;

  /// Set while [handleUserMessage] is building the tip so director history
  /// excludes the live user bubble (already in [newUserContent]).
  String? _excludeUserMessageIdForDirector;

  bool get isBusy => _busy;

  void requestStop() {
    _stopRequested = true;
    final key = _activeStreamKey;
    if (key != null) {
      unawaited(streamExecutor.cancel(key));
    }
  }

  Future<void> handleUserMessage({
    required GroupChat group,
    required ChatMessage userMessage,
    ChatInputData? inputData,
  }) async {
    if (_busy) return;
    _busy = true;
    _stopRequested = false;
    try {
      final assistantIds = groupChatProvider.assistantIdsOf(group.id);
      if (assistantIds.isEmpty) {
        onUiFeedback('groupChatNoAssistants');
        return;
      }

      final userName = userProvider.name.trim().isEmpty
          ? 'User'
          : userProvider.name.trim();

      String directorUserContent;
      var g = groupChatProvider.getById(group.id) ?? group;
      String? skipPendingForHistory;
      var initialDirectorTrigger = GroupChatDirectorLogTrigger.user;
      if (g.pendingCapAssistantMessageId != null) {
        final pendingId = g.pendingCapAssistantMessageId!;
        skipPendingForHistory = pendingId;
        initialDirectorTrigger = GroupChatDirectorLogTrigger.capMerge;
        final msgs = chatService.getMessages(g.conversationId);
        ChatMessage? pending;
        for (final m in msgs) {
          if (m.id == pendingId) {
            pending = m;
            break;
          }
        }
        final aName =
            assistantProvider.assistants
                .where((a) => a.id == pending?.speakerAssistantId)
                .map((a) => a.name)
                .firstOrNull ??
            'Assistant';
        directorUserContent = _contextBuilder.buildCapMergeE3(
          assistantName: aName,
          pendingAssistantContent: pending == null
              ? ''
              : _contextBuilder.contentForDirector(pending),
          userName: userName,
          newUserMessageText: userMessage.content,
        );
        g = g.copyWith(
          pendingCapAssistantMessageId: null,
          assistantMessagesThisRound: 0,
        );
        await groupChatProvider.persistGroupState(g);
      } else {
        directorUserContent = _contextBuilder.buildUserTurnE1(
          userName: userName,
          userMessageText: userMessage.content,
        );
        g = g.copyWith(assistantMessagesThisRound: 0);
        await groupChatProvider.persistGroupState(g);
      }

      directorUserContent = await _maybeInjectRoster(
        g,
        directorUserContent,
        isHumanUserTurn: true,
      );

      _excludeUserMessageIdForDirector = userMessage.id;
      try {
        await _directorLoop(
          group: g,
          directorUserContent: directorUserContent,
          inputData: inputData,
          skipPendingCapMessageId: skipPendingForHistory,
          sourceMessageId: userMessage.id,
          initialTrigger: initialDirectorTrigger,
        );
      } finally {
        _excludeUserMessageIdForDirector = null;
      }
    } finally {
      _busy = false;
      onMessagesChanged();
    }
  }

  /// Single-bubble assistant regenerate: same groupId, new version, no director.
  Future<void> regenerateAssistantMessage({
    required GroupChat group,
    required ChatMessage message,
  }) async {
    if (_busy) return;
    if (message.role != 'assistant') return;
    final speakerId = message.speakerAssistantId;
    if (speakerId == null || speakerId.isEmpty) {
      onUiFeedback('groupChatAssistantNoModel');
      return;
    }
    final speaker = assistantProvider.getById(speakerId);
    if (speaker == null) {
      onUiFeedback('groupChatAssistantNoModel');
      return;
    }

    _busy = true;
    _stopRequested = false;
    try {
      final key = _activeStreamKey;
      if (key != null) {
        await streamExecutor.cancel(key);
      }

      final providerKey =
          (speaker.chatModelProvider ?? settingsProvider.currentModelProvider)
              ?.trim();
      final modelId = (speaker.chatModelId ?? settingsProvider.currentModelId)
          ?.trim();
      if (providerKey == null ||
          providerKey.isEmpty ||
          modelId == null ||
          modelId.isEmpty) {
        onUiFeedback('groupChatAssistantNoModel');
        return;
      }

      final userName = userProvider.name.trim().isEmpty
          ? 'User'
          : userProvider.name.trim();
      final effective = _applyGroupMemberInjection(group, speaker, userName);

      final conversation =
          chatService.getConversation(group.conversationId) ??
          Conversation(
            id: group.conversationId,
            title: group.name,
            conversationKind: Conversation.kindGroup,
          );

      final publicMessages = chatService.getMessages(group.conversationId);
      final versionSelections = Map<String, int>.from(
        conversation.versionSelections,
      );
      final collapsed = _contextBuilder.collapsePublicVersions(
        publicMessages,
        versionSelections,
      );
      final cutIndex = collapsed.indexWhere((m) => m.id == message.id);
      if (cutIndex < 0) return;
      final prefix = collapsed.sublist(0, cutIndex);

      final assistantsById = {
        for (final a in assistantProvider.assistants) a.id: a,
      };

      final privateMessages = _privateBuilder.build(
        conversation: conversation,
        publicMessages: prefix,
        speaker: effective,
        userName: userName,
        assistantsById: assistantsById,
      );

      final gid = message.groupId ?? message.id;
      int maxVersion = message.version;
      for (final m in publicMessages) {
        final mg = m.groupId ?? m.id;
        if (mg == gid && m.version > maxVersion) maxVersion = m.version;
      }

      final placeholder = await messageGenerationService
          .createAssistantPlaceholder(
            conversationId: group.conversationId,
            modelId: modelId,
            providerKey: providerKey,
            groupId: gid,
            version: maxVersion + 1,
            speakerAssistantId: effective.id,
          );
      await chatService.setSelectedVersion(
        group.conversationId,
        gid,
        placeholder.version,
      );

      var g = groupChatProvider.getById(group.id) ?? group;
      if (g.pendingCapAssistantMessageId == message.id) {
        g = g.copyWith(pendingCapAssistantMessageId: placeholder.id);
        await groupChatProvider.persistGroupState(g);
      }

      onMessagesChanged();

      final done = Completer<void>();
      _activeStreamKey = placeholder.id;
      streamController.toolParts.remove(placeholder.id);

      await _pipeline.executeAssistantResponse(
        assistantMessage: placeholder,
        providerKey: providerKey,
        modelId: modelId,
        context: ModelExecutionContext(
          conversation: conversation,
          settings: settingsProvider,
          assistant: effective,
          approvalService: approvalService,
          askUserService: askUserService,
          versionSelections: {
            ...conversation.versionSelections,
            gid: placeholder.version,
          },
        ),
        completeMessages: privateMessages,
        inputData: null,
        generateTitleOnFinish: false,
        onStreamComplete: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future;
      _activeStreamKey = null;
      await groupChatProvider.touchUpdatedAt(group.id);
      onMessagesChanged();
    } finally {
      _busy = false;
      onMessagesChanged();
    }
  }

  /// Truncate messages after the user group, then re-enter the director loop.
  Future<void> resendUserMessage({
    required GroupChat group,
    required ChatMessage userMessage,
  }) async {
    if (_busy) return;
    if (userMessage.role != 'user') return;

    _busy = true;
    _stopRequested = false;
    try {
      final key = _activeStreamKey;
      if (key != null) {
        await streamExecutor.cancel(key);
      }

      await _truncateAfterMessageGroup(
        conversationId: group.conversationId,
        anchor: userMessage,
      );
      await _repairCapIfNeeded(group.id);
      onMessagesChanged();

      final g = groupChatProvider.getById(group.id) ?? group;
      // Drop outer busy so handleUserMessage can run.
      _busy = false;
      await handleUserMessage(group: g, userMessage: userMessage);
    } finally {
      _busy = false;
      onMessagesChanged();
    }
  }

  Future<void> deleteMessageVersions({
    required GroupChat group,
    required ChatMessage message,
    required bool allVersions,
    Map<String, List<ChatMessage>>? byGroup,
  }) async {
    final gid = message.groupId ?? message.id;
    final ids = <String>[];
    if (allVersions) {
      final groupMsgs =
          byGroup?[gid] ??
          chatService
              .getMessages(group.conversationId)
              .where((m) => (m.groupId ?? m.id) == gid)
              .toList();
      ids.addAll(groupMsgs.map((m) => m.id));
    } else {
      ids.add(message.id);
    }
    for (final id in ids) {
      await chatService.deleteMessage(id);
    }
    await _repairCapIfNeeded(group.id, deletedIds: ids.toSet());
    onMessagesChanged();
  }

  Future<void> _truncateAfterMessageGroup({
    required String conversationId,
    required ChatMessage anchor,
  }) async {
    final all = chatService.getMessages(conversationId);
    final anchorGid = anchor.groupId ?? anchor.id;
    var seenAnchor = false;
    final toDelete = <String>[];
    for (final m in all) {
      final gid = m.groupId ?? m.id;
      if (!seenAnchor) {
        if (gid == anchorGid) {
          seenAnchor = true;
        }
        continue;
      }
      if (gid == anchorGid) continue;
      toDelete.add(m.id);
    }
    for (final id in toDelete) {
      await chatService.deleteMessage(id);
    }
  }

  Future<void> _repairCapIfNeeded(
    String groupChatId, {
    Set<String>? deletedIds,
  }) async {
    var g = groupChatProvider.getById(groupChatId);
    if (g == null) return;
    final pending = g.pendingCapAssistantMessageId;
    if (pending == null) return;
    if (deletedIds != null && deletedIds.contains(pending)) {
      g = g.copyWith(
        pendingCapAssistantMessageId: null,
        assistantMessagesThisRound: 0,
      );
      await groupChatProvider.persistGroupState(g);
      return;
    }
    final msgs = chatService.getMessages(g.conversationId);
    final stillThere = msgs.any((m) => m.id == pending);
    if (!stillThere) {
      g = g.copyWith(
        pendingCapAssistantMessageId: null,
        assistantMessagesThisRound: 0,
      );
      await groupChatProvider.persistGroupState(g);
    }
  }

  Future<void> _directorLoop({
    required GroupChat group,
    required String directorUserContent,
    ChatInputData? inputData,
    String? skipPendingCapMessageId,
    required String sourceMessageId,
    required GroupChatDirectorLogTrigger initialTrigger,
  }) async {
    var g = groupChatProvider.getById(group.id) ?? group;
    var nextContent = directorUserContent;
    final userName = userProvider.name.trim().isEmpty
        ? 'User'
        : userProvider.name.trim();
    var firstDirectorCall = true;
    var nextSourceMessageId = sourceMessageId;
    var nextTrigger = initialTrigger;

    while (!_stopRequested) {
      g = groupChatProvider.getById(g.id) ?? g;
      final assistantIds = groupChatProvider.assistantIdsOf(g.id);
      if (assistantIds.isEmpty) break;

      final roster = assistantProvider.assistants
          .where((a) => assistantIds.contains(a.id))
          .toList();
      final memberNames = [userName, ...roster.map((a) => a.name)];
      final assistantsById = {for (final a in roster) a.id: a};
      final conversation = chatService.getConversation(g.conversationId);
      final publicMessages = chatService.getMessages(g.conversationId);
      final versionSelections = Map<String, int>.from(
        conversation?.versionSelections ?? const {},
      );

      DirectorDecision decision;
      try {
        decision = await _directorRunner.run(
          group: g,
          newUserContent: nextContent,
          rosterAssistants: roster,
          userName: userName,
          memberNames: memberNames,
          settings: settingsProvider,
          modelSupportsTools: _modelSupportsTools,
          publicMessages: publicMessages,
          versionSelections: versionSelections,
          assistantsById: assistantsById,
          skipPendingCapMessageId: firstDirectorCall
              ? skipPendingCapMessageId
              : null,
          excludeTrailingUserMessageId: firstDirectorCall
              ? _excludeUserMessageIdForDirector
              : null,
          sourceMessageId: nextSourceMessageId,
          trigger: nextTrigger,
          onRuntimeLog: (log) {
            groupChatProvider.recordDirectorRuntimeLog(g.id, log);
          },
        );
      } on DirectorSoftError catch (e) {
        if (e.kind == DirectorSoftErrorKind.noModel) {
          onUiFeedback('groupChatNoDirectorModel');
        } else {
          onUiFeedback('groupChatDirectorModelNoTools');
        }
        return;
      } on TimeoutException {
        onUiFeedback('groupChatDirectorTimeout');
        return;
      } catch (e) {
        debugPrint('[GroupChatOrchestrator] director error: $e');
        onUiFeedback('groupChatDirectorError');
        return;
      }

      firstDirectorCall = false;
      _excludeUserMessageIdForDirector = null;

      if (_stopRequested) return;
      if (decision.kind == DirectorDecisionKind.endTurn ||
          decision.assistantId == null) {
        return;
      }

      final speakerId = decision.assistantId!;
      final speaker = roster.where((a) => a.id == speakerId).firstOrNull;
      if (speaker == null) {
        debugPrint('[GroupChatOrchestrator] unknown speaker $speakerId');
        return;
      }

      g = groupChatProvider.getById(g.id) ?? g;
      if (g.assistantMessagesThisRound >= g.maxAssistantMessagesPerRound) {
        return;
      }

      final assistantMsg = await _runAssistantTurn(
        group: g,
        speaker: speaker,
        inputData: inputData,
      );
      if (assistantMsg == null || _stopRequested) return;

      g = groupChatProvider.getById(g.id) ?? g;
      final count = g.assistantMessagesThisRound + 1;
      if (count >= g.maxAssistantMessagesPerRound) {
        g = g.copyWith(
          assistantMessagesThisRound: count,
          pendingCapAssistantMessageId: assistantMsg.id,
        );
        await groupChatProvider.persistGroupState(g);
        return;
      }

      g = g.copyWith(assistantMessagesThisRound: count);
      await groupChatProvider.persistGroupState(g);

      nextContent = _contextBuilder.buildAssistantTurnE2(
        assistantName: speaker.name,
        assistantContent: _contextBuilder.contentForDirector(assistantMsg),
      );
      nextContent = await _maybeInjectRoster(
        g,
        nextContent,
        isHumanUserTurn: false,
      );
      nextSourceMessageId = assistantMsg.id;
      nextTrigger = GroupChatDirectorLogTrigger.assistant;
      inputData = null;
    }
  }

  Future<String> _maybeInjectRoster(
    GroupChat group,
    String content, {
    required bool isHumanUserTurn,
  }) async {
    final conversation = chatService.getConversation(group.conversationId);
    final public = chatService.getMessages(group.conversationId);
    final collapsed = _contextBuilder.collapsePublicVersions(
      public,
      conversation?.versionSelections ?? const {},
    );
    final priorUsers = _contextBuilder.countHumanUserTurnsFromPublic(collapsed);
    final priorDirectorLines = _contextBuilder
        .countDirectorUserMessagesFromPublic(collapsed);
    final userTurnCount = priorUsers + (isHumanUserTurn ? 1 : 0);
    final directorUserMsgCount = priorDirectorLines + 1;
    final isFirstHuman = isHumanUserTurn && priorUsers == 0;

    final inject = _contextBuilder.maybeAppendRoster(
      mode: group.assistantDetailInjectionMode,
      n: group.assistantDetailInjectionN,
      isHumanUserTurn: isHumanUserTurn,
      isFirstHumanUser: isFirstHuman,
      userTurnCount: userTurnCount,
      directorUserMsgCount: directorUserMsgCount,
    );
    if (!inject) return content;

    final assistantIds = groupChatProvider.assistantIdsOf(group.id);
    final roster = assistantProvider.assistants
        .where((a) => assistantIds.contains(a.id))
        .toList();
    final block = _contextBuilder.buildRosterBlock(roster);
    return '$content\n\n$block';
  }

  Future<ChatMessage?> _runAssistantTurn({
    required GroupChat group,
    required Assistant speaker,
    ChatInputData? inputData,
  }) async {
    final userName = userProvider.name.trim().isEmpty
        ? 'User'
        : userProvider.name.trim();
    final effective = _applyGroupMemberInjection(group, speaker, userName);

    final providerKey =
        (effective.chatModelProvider ?? settingsProvider.currentModelProvider)
            ?.trim();
    final modelId = (effective.chatModelId ?? settingsProvider.currentModelId)
        ?.trim();
    if (providerKey == null ||
        providerKey.isEmpty ||
        modelId == null ||
        modelId.isEmpty) {
      onUiFeedback('groupChatAssistantNoModel');
      return null;
    }

    final conversation =
        chatService.getConversation(group.conversationId) ??
        Conversation(
          id: group.conversationId,
          title: group.name,
          conversationKind: Conversation.kindGroup,
        );

    final publicMessages = chatService.getMessages(group.conversationId);
    final assistantsById = {
      for (final a in assistantProvider.assistants) a.id: a,
    };

    final privateMessages = _privateBuilder.build(
      conversation: conversation,
      publicMessages: publicMessages,
      speaker: effective,
      userName: userName,
      assistantsById: assistantsById,
    );

    final placeholder = await messageGenerationService
        .createAssistantPlaceholder(
          conversationId: group.conversationId,
          modelId: modelId,
          providerKey: providerKey,
          speakerAssistantId: effective.id,
        );
    onMessagesChanged();

    final done = Completer<void>();
    _activeStreamKey = placeholder.id;

    streamController.toolParts.remove(placeholder.id);

    await _pipeline.executeAssistantResponse(
      assistantMessage: placeholder,
      providerKey: providerKey,
      modelId: modelId,
      context: ModelExecutionContext(
        conversation: conversation,
        settings: settingsProvider,
        assistant: effective,
        approvalService: approvalService,
        askUserService: askUserService,
        versionSelections: conversation.versionSelections,
      ),
      completeMessages: privateMessages,
      inputData: inputData,
      generateTitleOnFinish: false,
      onStreamComplete: () {
        if (!done.isCompleted) done.complete();
      },
    );

    await done.future;
    _activeStreamKey = null;
    await groupChatProvider.touchUpdatedAt(group.id);
    onMessagesChanged();

    final msgs = chatService.getMessages(group.conversationId);
    for (final m in msgs.reversed) {
      if (m.id == placeholder.id) return m;
    }
    return placeholder;
  }

  /// Applies the optional "group members" paragraph to a member assistant's
  /// system prompt (see [GroupChat.injectGroupMembersIntoAssistantSystemPrompt]).
  Assistant _applyGroupMemberInjection(
    GroupChat group,
    Assistant speaker,
    String userName,
  ) {
    var effective = speaker.copyWith(enableProactiveCare: false);
    if (!group.injectGroupMembersIntoAssistantSystemPrompt) return effective;
    final memberIds = groupChatProvider.assistantIdsOf(group.id).toSet();
    final memberNames = assistantProvider.assistants
        .where((a) => memberIds.contains(a.id))
        .map((a) => a.name)
        .toList();
    final injection = AssistantPrivateContextBuilder.buildGroupMemberInjection(
      group: group,
      userName: userName,
      memberNames: memberNames,
    );
    if (injection == null || injection.isEmpty) return effective;
    final base = effective.systemPrompt.trim();
    effective = effective.copyWith(
      systemPrompt: base.isEmpty ? injection : '$base\n\n$injection',
    );
    return effective;
  }

  bool _modelSupportsTools(String providerKey, String modelId) {
    try {
      final cfg = settingsProvider.getProviderConfig(providerKey);
      final ov = cfg.modelOverrides[modelId];
      if (ov is Map) {
        final abs = ov['abilities'];
        if (abs is List) {
          return abs.map((e) => e.toString()).contains('tool');
        }
      }
    } catch (e) {
      debugPrint('[GroupChatOrchestrator] modelSupportsTools: $e');
    }
    return true;
  }
}
