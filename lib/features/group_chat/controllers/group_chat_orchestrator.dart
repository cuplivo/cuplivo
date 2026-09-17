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
import '../../home/controllers/chat_actions.dart';
import '../services/assistant_private_context_builder.dart';
import '../services/director_context_builder.dart';
import '../services/director_runner.dart';
import '../services/director_tool_protocol.dart';

/// One orchestrated member turn, as handed to [GroupChatTurnDriver.runTurn].
@immutable
class GroupChatTurnRequest {
  const GroupChatTurnRequest({
    required this.group,
    required this.speaker,
    required this.conversation,
    required this.privateContext,
    required this.providerKey,
    required this.modelId,
    this.input,
  });

  final GroupChat group;

  /// The speaker with the group roster paragraph already applied (see
  /// [GroupChatOrchestrator.applyGroupMemberInjection]).
  final Assistant speaker;
  final Conversation conversation;

  /// Per-speaker point-of-view history replacing persisted context.
  final List<ChatMessage> privateContext;
  final String providerKey;
  final String modelId;

  /// Non-null on the first turn after a human message: the user bubble was
  /// already persisted by the caller, so only its attachments ride along.
  final ChatInputData? input;
}

/// Runs one member turn and resolves with its final message.
///
/// The production implementation drives
/// `ChatActions.sendMessage(contextMessagesOverride: …, senderId: …)`; tests
/// substitute a fake and never touch the generation pipeline.
typedef GroupChatTurnDriver =
    Future<ChatMessage?> Function(GroupChatTurnRequest request);

/// Orchestrates user → director → assistant turns for one group chat session.
///
/// The director decides speakers ([DirectorRunner]); each chosen speaker runs
/// through [GroupChatTurnDriver], which wraps the ordinary single-chat send
/// seam (`ChatActions.sendMessage` with a per-speaker private context).
class GroupChatOrchestrator {
  GroupChatOrchestrator({
    required this.chatService,
    required this.groupChatProvider,
    required this.assistantProvider,
    required this.settingsProvider,
    required this.userProvider,
    required this.directorRunner,
    ChatActions? chatActions,
    GroupChatTurnDriver? runTurn,

    /// Test seam: replaces the default driver entirely so a test never builds
    /// the home-page controller graph (`ChatActions` needs seven wired
    /// collaborators). Production callers pass `chatActions` or `runTurn`.
    @visibleForTesting GroupChatTurnDriver? turnDriver,
    this.onUiFeedback,
    this.onMessagesChanged,
  }) : runTurn =
           turnDriver ??
           runTurn ??
           _defaultTurnDriver(chatActions, chatService) {
    _contextBuilder = DirectorContextBuilder(chatService: chatService);
    _privateBuilder = AssistantPrivateContextBuilder(chatService: chatService);
  }

  static GroupChatTurnDriver _defaultTurnDriver(
    ChatActions? chatActions,
    ChatService chatService,
  ) {
    if (chatActions == null) {
      throw ArgumentError.value(
        null,
        'chatActions',
        'required unless a custom runTurn driver is provided',
      );
    }
    return ChatActionsGroupChatTurnDriver(
      chatActions: chatActions,
      chatService: chatService,
    ).call;
  }

  final ChatService chatService;
  final GroupChatProvider groupChatProvider;
  final AssistantProvider assistantProvider;
  final SettingsProvider settingsProvider;
  final UserProvider userProvider;
  final DirectorRunner directorRunner;

  /// Executes one member turn (see [GroupChatTurnDriver]).
  final GroupChatTurnDriver runTurn;

  /// Localized-message keys the host page maps to snackbars.
  final GroupChatUiFeedback? onUiFeedback;
  final VoidCallback? onMessagesChanged;

  late final DirectorContextBuilder _contextBuilder;
  late final AssistantPrivateContextBuilder _privateBuilder;

  bool _busy = false;
  bool _stopRequested = false;

  /// Set while [handleUserMessage] is building the tip so director history
  /// excludes the live user bubble (already in [newUserContent]).
  String? _excludeUserMessageIdForDirector;

  bool get isBusy => _busy;

  /// Stops the round: no further director call and no further member turn.
  ///
  /// A member turn already in flight is cancelled through the ordinary stop
  /// path (`ChatActions.cancelStreamingById`), exactly like a manual Stop in
  /// single chat.
  void requestStop() {
    _stopRequested = true;
    final id = activeTurnConversationId;
    if (id != null) {
      unawaited(_cancelActiveTurn(id));
    }
  }

  /// Conversation whose member turn is currently running (null between turns).
  String? activeTurnConversationId;

  Future<void> _cancelActiveTurn(String conversationId) async {
    try {
      await ChatActions.cancelActiveGenerationFor(conversationId);
    } catch (e) {
      debugPrint('[GroupChatOrchestrator] cancel active turn: $e');
    }
  }

  // ==========================================================================
  // Entry points
  // ==========================================================================

  /// Runs the director loop after the caller persisted a human message.
  ///
  /// [userMessage] must already be in the conversation; the round counter is
  /// reset here (a new human turn starts a fresh speaking round).
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
        _feedback('groupChatNoAssistants');
        return;
      }

      final userName = _userName();

      String directorUserContent;
      var g = groupChatProvider.getById(group.id) ?? group;
      String? skipPendingForHistory;
      var initialDirectorTrigger = GroupChatDirectorLogTrigger.user;
      if (g.pendingCapAssistantMessageId != null) {
        final pendingId = g.pendingCapAssistantMessageId!;
        skipPendingForHistory = pendingId;
        initialDirectorTrigger = GroupChatDirectorLogTrigger.capMerge;
        final msgs = await chatService.loadMessages(g.conversationId);
        ChatMessage? pending;
        for (final m in msgs) {
          if (m.id == pendingId) {
            pending = m;
            break;
          }
        }
        final aName =
            assistantProvider.assistants
                .where((a) => a.id == pending?.senderId)
                .map((a) => a.name)
                .firstOrNull ??
            'Assistant';
        directorUserContent = _contextBuilder.buildCapMergeE3(
          assistantName: aName,
          pendingAssistantContent: pending == null
              ? ''
              : _contextBuilder.contentForDirector(pending),
          userName: userName,
          newUserMessageText: DirectorContextBuilder.plainTextForDirector(
            userMessage.content,
          ),
        );
        g = g.copyWith(
          pendingCapAssistantMessageId: null,
          assistantMessagesThisRound: 0,
        );
        await groupChatProvider.persistGroupState(g);
      } else {
        directorUserContent = _contextBuilder.buildUserTurnE1(
          userName: userName,
          userMessageText: DirectorContextBuilder.plainTextForDirector(
            userMessage.content,
          ),
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
        await directorLoop(
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
      onMessagesChanged?.call();
    }
  }

  /// Re-runs one assistant bubble with the same speaker and no director call.
  ///
  /// Deferred onto the worktree regeneration entry point: `ChatActions
  /// .regenerateAtMessage` rebuilds its context from persisted history, which
  /// would replace the speaker's private point of view with the public
  /// transcript. A single-member regenerate therefore appends a new version
  /// through the same seam as an orchestrated turn.
  Future<void> regenerateAssistantMessage({
    required GroupChat group,
    required ChatMessage message,
  }) async {
    if (_busy) return;
    if (message.role != 'assistant') return;
    final speakerId = message.senderId;
    if (speakerId == null || speakerId.isEmpty) {
      _feedback('groupChatAssistantNoModel');
      return;
    }
    final speaker = assistantProvider.getById(speakerId);
    if (speaker == null) {
      _feedback('groupChatAssistantNoModel');
      return;
    }

    _busy = true;
    _stopRequested = false;
    try {
      final g = groupChatProvider.getById(group.id) ?? group;
      final userName = _userName();
      final effective = applyGroupMemberInjection(
        group: g,
        speaker: speaker,
        userName: userName,
        memberNames: _memberNames(g, userName),
      );
      final model = _modelFor(effective);
      if (model == null) {
        _feedback('groupChatAssistantNoModel');
        return;
      }
      final conversation = _conversationFor(g);
      final publicMessages = await chatService.loadMessages(g.conversationId);
      final prefix = _prefixBeforeMessage(
        publicMessages,
        conversation.versionSelections,
        message.id,
      );
      if (prefix == null) return;

      final result = await runTurn(
        GroupChatTurnRequest(
          group: g,
          speaker: effective,
          conversation: conversation,
          privateContext: _privateBuilder.build(
            conversation: conversation,
            publicMessages: prefix,
            speaker: effective,
            userName: userName,
            assistantsById: _assistantsById(),
          ),
          providerKey: model.providerKey,
          modelId: model.modelId,
        ),
      );
      if (result == null) return;
      await groupChatProvider.touchUpdatedAt(g.id);
      onMessagesChanged?.call();
    } finally {
      _busy = false;
      onMessagesChanged?.call();
    }
  }

  /// Truncates everything after the user group, then re-enters the director
  /// loop with the same user bubble.
  Future<void> resendUserMessage({
    required GroupChat group,
    required ChatMessage userMessage,
  }) async {
    if (_busy) return;
    if (userMessage.role != 'user') return;

    _busy = true;
    _stopRequested = false;
    try {
      final g = groupChatProvider.getById(group.id) ?? group;
      await truncateAfterMessageGroup(
        conversationId: g.conversationId,
        anchor: userMessage,
      );
      await repairCapIfNeeded(g.id);
      onMessagesChanged?.call();
      _busy = false;
      await handleUserMessage(group: g, userMessage: userMessage);
    } finally {
      _busy = false;
      onMessagesChanged?.call();
    }
  }

  /// Deletes one version (or a whole reply group) and repairs round state.
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
          (await chatService.loadMessages(
            group.conversationId,
          )).where((m) => (m.groupId ?? m.id) == gid).toList();
      ids.addAll(groupMsgs.map((m) => m.id));
    } else {
      ids.add(message.id);
    }
    for (final id in ids) {
      await chatService.deleteMessage(id);
    }
    await repairCapIfNeeded(group.id, deletedIds: ids.toSet());
    onMessagesChanged?.call();
  }

  // ==========================================================================
  // Director loop
  // ==========================================================================

  Future<void> directorLoop({
    required GroupChat group,
    required String directorUserContent,
    ChatInputData? inputData,
    String? skipPendingCapMessageId,
    required String sourceMessageId,
    required GroupChatDirectorLogTrigger initialTrigger,
  }) async {
    var g = groupChatProvider.getById(group.id) ?? group;
    var nextContent = directorUserContent;
    final userName = _userName();
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
      final conversation = _conversationFor(g);
      final publicMessages = await chatService.loadMessages(g.conversationId);
      final versionSelections = Map<String, int>.from(
        conversation.versionSelections,
      );

      DirectorDecision decision;
      try {
        decision = await directorRunner.run(
          group: g,
          newUserContent: nextContent,
          rosterAssistants: roster,
          userName: userName,
          memberNames: memberNames,
          settings: settingsProvider,
          modelSupportsTools: modelSupportsTools,
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
          _feedback('groupChatNoDirectorModel');
        } else {
          _feedback('groupChatDirectorModelNoTools');
        }
        return;
      } on TimeoutException {
        _feedback('groupChatDirectorTimeout');
        return;
      } catch (e) {
        debugPrint('[GroupChatOrchestrator] director error: $e');
        _feedback('groupChatDirectorError');
        return;
      }

      firstDirectorCall = false;
      _excludeUserMessageIdForDirector = null;

      if (_stopRequested) return;
      final nextSpeakerId = nextSpeakerForDecision(
        decision: decision,
        rosterIds: roster.map((a) => a.id).toSet(),
        group: g,
      );
      if (nextSpeakerId == null) {
        if (decision.kind == DirectorDecisionKind.selectSpeaker &&
            !roster.any((a) => a.id == decision.assistantId)) {
          debugPrint(
            '[GroupChatOrchestrator] unknown speaker ${decision.assistantId}',
          );
        }
        return;
      }
      final speaker = roster.firstWhere((a) => a.id == nextSpeakerId);

      final assistantMsg = await runAssistantTurn(
        group: g,
        speaker: speaker,
        userName: userName,
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

  /// Which speaker to run next, or null to end the round.
  ///
  /// Pure so the cap / unknown-speaker guards are testable without a
  /// transport: `end_turn`, a missing id, an id outside the roster and an
  /// exhausted round budget all end the round.
  static String? nextSpeakerForDecision({
    required DirectorDecision decision,
    required Set<String> rosterIds,
    required GroupChat group,
  }) {
    if (decision.kind == DirectorDecisionKind.endTurn) return null;
    final id = decision.assistantId;
    if (id == null || !rosterIds.contains(id)) return null;
    if (group.assistantMessagesThisRound >=
        group.maxAssistantMessagesPerRound) {
      return null;
    }
    return id;
  }

  /// Runs one member turn through [runTurn]; returns its final message.
  Future<ChatMessage?> runAssistantTurn({
    required GroupChat group,
    required Assistant speaker,
    required String userName,
    ChatInputData? inputData,
  }) async {
    final effective = applyGroupMemberInjection(
      group: group,
      speaker: speaker,
      userName: userName,
      memberNames: _memberNames(group, userName),
    );
    final model = _modelFor(effective);
    if (model == null) {
      _feedback('groupChatAssistantNoModel');
      return null;
    }

    final conversation = _conversationFor(group);
    final publicMessages = await chatService.loadMessages(group.conversationId);
    final privateMessages = _privateBuilder.build(
      conversation: conversation,
      publicMessages: publicMessages,
      speaker: effective,
      userName: userName,
      assistantsById: _assistantsById(),
    );

    activeTurnConversationId = conversation.id;
    ChatMessage? result;
    try {
      result = await runTurn(
        GroupChatTurnRequest(
          group: group,
          speaker: effective,
          conversation: conversation,
          privateContext: privateMessages,
          providerKey: model.providerKey,
          modelId: model.modelId,
          input: inputData,
        ),
      );
    } finally {
      activeTurnConversationId = null;
    }
    if (result == null) return null;
    await groupChatProvider.touchUpdatedAt(group.id);
    onMessagesChanged?.call();
    return result;
  }

  // ==========================================================================
  // Shared helpers (public for tests and the host page)
  // ==========================================================================

  /// Applies the optional "group members" paragraph to a member assistant's
  /// system prompt (see [GroupChat.injectGroupMembersIntoAssistantSystemPrompt])
  /// and disables proactive care: only the human drives a group round.
  Assistant applyGroupMemberInjection({
    required GroupChat group,
    required Assistant speaker,
    required String userName,
    required List<String> memberNames,
  }) {
    final injection = AssistantPrivateContextBuilder.buildGroupMemberInjection(
      group: group,
      userName: userName,
      memberNames: memberNames,
    );
    if (injection == null || injection.isEmpty) return speaker;
    final base = speaker.systemPrompt.trim();
    return speaker.copyWith(
      systemPrompt: base.isEmpty ? injection : '$base\n\n$injection',
    );
  }

  /// Whether the director model advertises tool calling. Absent metadata is
  /// treated as "supported" so providers without an override table still run.
  bool modelSupportsTools(String providerKey, String modelId) {
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

  /// Deletes every reply group after [anchor]'s group.
  Future<void> truncateAfterMessageGroup({
    required String conversationId,
    required ChatMessage anchor,
  }) async {
    final all = await chatService.loadMessages(conversationId);
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

  /// Drops the pending-cap marker when its message is gone (deletion or a
  /// truncation that removed the capped bubble).
  Future<void> repairCapIfNeeded(
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
    final msgs = await chatService.loadMessages(g.conversationId);
    final stillThere = msgs.any((m) => m.id == pending);
    if (!stillThere) {
      g = g.copyWith(
        pendingCapAssistantMessageId: null,
        assistantMessagesThisRound: 0,
      );
      await groupChatProvider.persistGroupState(g);
    }
  }

  /// Collapsed public messages strictly before [messageId], or null when the
  /// message is not part of the selected timeline.
  List<ChatMessage>? _prefixBeforeMessage(
    List<ChatMessage> publicMessages,
    Map<String, int> versionSelections,
    String messageId,
  ) {
    final collapsed = _contextBuilder.collapsePublicVersions(
      publicMessages,
      versionSelections,
    );
    final cutIndex = collapsed.indexWhere((m) => m.id == messageId);
    if (cutIndex < 0) return null;
    return collapsed.sublist(0, cutIndex);
  }

  Future<String> _maybeInjectRoster(
    GroupChat group,
    String content, {
    required bool isHumanUserTurn,
  }) async {
    final conversation = _conversationFor(group);
    final public = await chatService.loadMessages(group.conversationId);
    final collapsed = _contextBuilder.collapsePublicVersions(
      public,
      conversation.versionSelections,
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

  ({String providerKey, String modelId})? _modelFor(Assistant assistant) {
    final providerKey =
        (assistant.chatModelProvider ?? settingsProvider.currentModelProvider)
            ?.trim();
    final modelId = (assistant.chatModelId ?? settingsProvider.currentModelId)
        ?.trim();
    if (providerKey == null ||
        providerKey.isEmpty ||
        modelId == null ||
        modelId.isEmpty) {
      return null;
    }
    return (providerKey: providerKey, modelId: modelId);
  }

  Conversation _conversationFor(GroupChat group) {
    return chatService.getConversation(group.conversationId) ??
        Conversation(
          id: group.conversationId,
          title: group.name,
          extras: const <String, dynamic>{},
        );
  }

  Map<String, Assistant> _assistantsById() {
    return {for (final a in assistantProvider.assistants) a.id: a};
  }

  List<String> _memberNames(GroupChat group, String userName) {
    final memberIds = groupChatProvider.assistantIdsOf(group.id).toSet();
    return assistantProvider.assistants
        .where((a) => memberIds.contains(a.id))
        .map((a) => a.name)
        .toList();
  }

  String _userName() {
    final name = userProvider.name.trim();
    return name.isEmpty ? 'User' : name;
  }

  void _feedback(String key) => onUiFeedback?.call(key);
}

/// Default [GroupChatTurnDriver]: one member turn through the send seam.
///
/// `ChatActions.sendMessage` returns as soon as the user/assistant pair is
/// persisted — generation continues detached, and its result carries only the
/// empty placeholder. Completion is therefore observed through
/// [ChatActions.onAssistantMessageFinished], which fires exactly once with the
/// finalized message; the id of our own placeholder selects it out of the
/// stream of single-chat completions this shared callback also carries.
class ChatActionsGroupChatTurnDriver {
  ChatActionsGroupChatTurnDriver({
    required this.chatActions,
    required this.chatService,
    this.completionTimeout = const Duration(minutes: 5),
  });

  final ChatActions chatActions;
  final ChatService chatService;

  /// Safety net for a run whose terminal callback never arrives (a cancelled
  /// HTTP request can end without any finish handler). Without it the director
  /// loop would hang forever.
  final Duration completionTimeout;

  Future<ChatMessage?> call(GroupChatTurnRequest request) async {
    final actions = chatActions;
    final input = request.input ?? const ChatInputData(text: '');
    final completer = Completer<void>();
    final previousHandler = actions.onAssistantMessageFinished;
    String? claimedId;
    actions.onAssistantMessageFinished = (message) async {
      // Claim exactly one terminal message: an assistant reply authored by our
      // speaker in our conversation. Anything else belongs to single chat and
      // goes to whoever owned the callback before us.
      if (claimedId == null &&
          message.role == 'assistant' &&
          message.conversationId == request.conversation.id &&
          message.senderId == request.speaker.id) {
        claimedId = message.id;
        if (!completer.isCompleted) completer.complete();
        return;
      }
      await previousHandler?.call(message);
    };

    try {
      final result = await actions.sendMessage(
        input: input,
        conversation: request.conversation,
        assistantOverride: request.speaker,
        modelOverride: (
          providerKey: request.providerKey,
          modelId: request.modelId,
        ),
        contextMessagesOverride: request.privateContext,
        senderId: request.speaker.id,
        generateTitleOnFinish: false,
      );
      if (!result.success) {
        final error = result.errorMessage;
        if (error == 'no_model') {
          throw const MissingModelConfigError();
        }
        throw StateError('group_send_rejected:$error');
      }
      final placeholder = result.assistantMessage;
      if (placeholder == null) {
        throw StateError('group_send_placeholder_missing');
      }
      // From here the placeholder owns our claim: a run that never reaches a
      // terminal callback (a cancelled request can end without one) must not
      // block the round forever, hence the timeout below.
      claimedId = placeholder.id;

      await completer.future
          .timeout(
            completionTimeout,
            onTimeout: () {
              debugPrint(
                '[GroupChatOrchestrator] turn settle timeout ${placeholder.id}',
              );
            },
          )
          .catchError((Object e) {
            debugPrint('[GroupChatOrchestrator] turn settle error: $e');
          });
      return await _readBack(placeholder.id);
    } finally {
      // Turns are serialized (orchestrator busy flag + the conversation-level
      // send claim), so restoring unconditionally cannot drop another owner.
      actions.onAssistantMessageFinished = previousHandler;
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<ChatMessage?> _readBack(String messageId) async {
    final messages = await chatService.loadMessagesByIds([messageId]);
    for (final message in messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }
}

/// Thrown when the resolved model configuration is unusable.
class MissingModelConfigError implements Exception {
  const MissingModelConfigError();
}

typedef GroupChatUiFeedback = void Function(String messageKey);
