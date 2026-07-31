import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/assistant.dart';
import '../../models/director_session.dart';
import '../../models/group_chat_member.dart';
import '../../models/group_chat_message.dart';
import '../../models/group_chat_settings.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import '../chat/group_chat_service.dart';
import '../chat/chat_stream_executor.dart';
import 'director_prompt_builder.dart';
import 'director_session_store.dart';
import 'director_tool_service.dart';

/// Orchestrator phase for one group while a user turn is running.
enum GroupChatPhase { idle, directing, memberSpeaking, done, error }

/// Stable error codes for UI (l10n mapping lives in Phase 3).
class GroupChatErrorCode {
  static const String noDirectorModel = 'groupChatNoDirectorModel';
  static const String directorModelNoTools = 'groupChatDirectorModelNoTools';
  static const String groupNotFound = 'groupChatNotFound';
  static const String notEnoughMembers = 'groupChatNotEnoughMembers';
  static const String memberNotFound = 'groupChatMemberNotFound';
  static const String memberNoModel = 'groupChatMemberNoModel';
  static const String alreadyRunning = 'groupChatAlreadyRunning';
  static const String cancelled = 'groupChatCancelled';
  static const String directorNoDecision = 'groupChatDirectorNoDecision';
  static const String directorFailed = 'groupChatDirectorFailed';
  static const String memberFailed = 'groupChatMemberFailed';
  static const String emptyContent = 'groupChatEmptyContent';
}

class GroupChatOrchestratorException implements Exception {
  GroupChatOrchestratorException(this.code, [this.message, this.cause]);

  final String code;
  final String? message;
  final Object? cause;

  @override
  String toString() =>
      'GroupChatOrchestratorException($code${message == null ? '' : ': $message'})';
}

/// Result of [GroupChatOrchestrator.sendUserMessage].
class GroupChatTurnResult {
  const GroupChatTurnResult({
    required this.groupId,
    required this.userMessage,
    required this.assistantMessages,
    required this.endedBy,
    this.errorCode,
    this.errorMessage,
  });

  final String groupId;
  final GroupChatMessage userMessage;
  final List<GroupChatMessage> assistantMessages;

  /// `end_round` | `max_messages` | `cancel` | `error`
  final String endedBy;
  final String? errorCode;
  final String? errorMessage;

  bool get isSuccess => errorCode == null;
}

class GroupMemberGenerationPreparation {
  const GroupMemberGenerationPreparation({
    required this.apiMessages,
    required this.toolDefs,
    required this.onToolCall,
    required this.userMediaPaths,
    this.extraHeaders,
    this.extraBody,
  });

  final List<Map<String, dynamic>> apiMessages;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final List<String> userMediaPaths;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
}

typedef MemberGenerationPreparer =
    Future<GroupMemberGenerationPreparation> Function({
      required String groupId,
      required List<GroupChatMessage> timeline,
      required Assistant assistant,
      required Map<String, String> assistantNames,
      required String providerKey,
      required String modelId,
      required SettingsProvider settings,
    });

typedef GroupMemberStreamRunner =
    Future<GroupChatMessage> Function({
      required GroupChatMessage placeholder,
      required Assistant assistant,
      required SettingsProvider settings,
      required String providerKey,
      required String modelId,
      required GroupMemberGenerationPreparation prepared,
      required GroupChatStreamFactory sendMessageStream,
      required bool Function() isCancelled,
    });

/// Injectable stream factory for director / member LLM calls.
typedef GroupChatStreamFactory =
    Stream<ChatStreamChunk> Function(GroupChatStreamRequest request);

/// Parameters for one [GroupChatStreamFactory] invocation.
class GroupChatStreamRequest {
  const GroupChatStreamRequest({
    required this.config,
    required this.modelId,
    required this.messages,
    this.userMediaPaths = const <String>[],
    this.tools,
    this.onToolCall,
    this.thinkingBudget,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.stream = true,
    this.requestId,
    this.extraHeaders,
    this.extraBody,
    this.allowImagesApiRouting = false,
    this.ocrActive = false,
  });

  final ProviderConfig config;
  final String modelId;
  final List<Map<String, dynamic>> messages;
  final List<String> userMediaPaths;
  final List<Map<String, dynamic>>? tools;
  final ToolCallHandler? onToolCall;
  final int? thinkingBudget;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final bool stream;
  final String? requestId;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
  final bool allowImagesApiRouting;
  final bool ocrActive;
}

Stream<ChatStreamChunk> _defaultGroupChatStream(GroupChatStreamRequest r) {
  return ChatStreamExecutor.open(
    ChatStreamExecutionRequest(
      config: r.config,
      modelId: r.modelId,
      messages: r.messages,
      userMediaPaths: r.userMediaPaths,
      tools: r.tools,
      onToolCall: r.onToolCall,
      thinkingBudget: r.thinkingBudget,
      temperature: r.temperature,
      topP: r.topP,
      maxTokens: r.maxTokens,
      stream: r.stream,
      requestId: r.requestId,
      extraHeaders: r.extraHeaders,
      extraBody: r.extraBody,
      allowImagesApiRouting: r.allowImagesApiRouting,
      ocrActive: r.ocrActive,
    ),
  );
}

/// Pure helpers extracted for unit tests (max count / consecutive rules).
class GroupChatRoundPolicy {
  const GroupChatRoundPolicy._();

  /// Whether another assistant message is allowed under [max] and current [count].
  static bool canSpeakMore({required int count, required int max}) {
    if (max <= 0) return false;
    return count < max;
  }

  /// Whether [nextAssistantId] is allowed given consecutive setting.
  static bool allowsSpeaker({
    required bool allowSameAssistantConsecutive,
    required String? lastSpeakerId,
    required String nextAssistantId,
  }) {
    if (allowSameAssistantConsecutive) return true;
    if (lastSpeakerId == null) return true;
    return lastSpeakerId != nextAssistantId;
  }
}

/// Group chat state machine:
/// Idle → Directing → MemberSpeaking → Directing → … → Idle
///
/// Director transcript is **never** written to the public group timeline.
class GroupChatOrchestrator extends ChangeNotifier {
  GroupChatOrchestrator({
    required this.groupChatService,
    required this.resolveAssistant,
    required this.resolveSettings,
    required this.runMemberStream,
    required this.prepareMemberGeneration,
    DirectorSessionStore? directorSessionStore,
    GroupChatStreamFactory? sendMessageStream,
  }) : directorStore =
           directorSessionStore ?? DirectorSessionStore(groupChatService),
       sendMessageStream = sendMessageStream ?? _defaultGroupChatStream;

  final GroupChatService groupChatService;
  final Assistant? Function(String assistantId) resolveAssistant;
  final SettingsProvider Function() resolveSettings;
  final MemberGenerationPreparer prepareMemberGeneration;
  final GroupMemberStreamRunner runMemberStream;
  final DirectorSessionStore directorStore;
  final GroupChatStreamFactory sendMessageStream;

  final Map<String, GroupChatPhase> _phaseByGroup = {};
  final Map<String, String> _activeRequestIdByGroup = {};
  final Set<String> _cancelRequested = {};

  GroupChatPhase phaseOf(String groupId) =>
      _phaseByGroup[groupId] ?? GroupChatPhase.idle;

  bool isRunning(String groupId) {
    final p = phaseOf(groupId);
    return p == GroupChatPhase.directing || p == GroupChatPhase.memberSpeaking;
  }

  /// Cancel in-flight director / member streams for [groupId].
  Future<void> cancel(String groupId) async {
    _cancelRequested.add(groupId);
    final rid = _activeRequestIdByGroup[groupId];
    if (rid != null && rid.isNotEmpty) {
      try {
        ChatApiService.cancelRequest(rid);
      } catch (e) {
        debugPrint('[GroupChatOrchestrator] cancelRequest failed: $e');
      }
    }
    notifyListeners();
  }

  /// Write a user message and run director → member loop until end.
  Future<GroupChatTurnResult> sendUserMessage({
    required String groupId,
    required String content,
  }) async {
    final text = content.trim();
    if (text.isEmpty) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.emptyContent,
        'Empty user message',
      );
    }

    if (isRunning(groupId)) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.alreadyRunning,
        'Group $groupId is already generating',
      );
    }

    await groupChatService.ensureLoaded();
    final group = groupChatService.getGroup(groupId);
    if (group == null) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.groupNotFound,
        'Group $groupId not found',
      );
    }

    final settings = group.settings;
    final appSettings = resolveSettings();
    final directorModel = resolveDirectorModel(
      settings: SettingsProviderAdapter(appSettings),
      groupDirectorProvider: settings.directorModelProvider,
      groupDirectorModelId: settings.directorModelId,
    );
    final directorProvider = directorModel.providerKey;
    final directorModelId = directorModel.modelId;
    if (directorProvider == null || directorModelId == null) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.noDirectorModel,
        'No director model configured',
      );
    }

    final directorConfig = appSettings.getProviderConfig(directorProvider);
    debugPrint(
      '[GroupChat] sendUserMessage group=$groupId '
      'director=$directorProvider/$directorModelId '
      'apiKeyEmpty=${directorConfig.apiKey.trim().isEmpty}',
    );
    if (!modelSupportsToolCalling(
      config: directorConfig,
      modelId: directorModelId,
    )) {
      debugPrint(
        '[GroupChat] director model lacks tool ability: '
        '$directorProvider/$directorModelId',
      );
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.directorModelNoTools,
        'Director model must support tool calling: $directorProvider/$directorModelId',
      );
    }

    final members = await groupChatService.getMembers(groupId);
    final enabledAssistants = members
        .where(
          (m) =>
              m.kind == GroupChatMember.kindAssistant &&
              m.isEnabled &&
              (m.assistantId?.isNotEmpty ?? false),
        )
        .toList();
    if (enabledAssistants.length < 2) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.notEnoughMembers,
        'Need at least 2 enabled assistant members',
      );
    }

    final allowedIds = enabledAssistants.map((m) => m.assistantId!).toSet();
    final nameMap = <String, String>{};
    final intros = <DirectorMemberIntro>[];
    for (final m in enabledAssistants) {
      final a = resolveAssistant(m.assistantId!);
      if (a == null) {
        debugPrint(
          '[GroupChatOrchestrator] assistant missing: ${m.assistantId}',
        );
        nameMap[m.assistantId!] = m.assistantId!;
        intros.add(
          DirectorMemberIntro(
            assistantId: m.assistantId!,
            name: m.assistantId!,
            systemPrompt: '',
          ),
        );
      } else {
        nameMap[a.id] = a.name;
        intros.add(DirectorMemberIntro.fromAssistant(a));
      }
    }

    _cancelRequested.remove(groupId);
    final assistantOut = <GroupChatMessage>[];

    // Claim the group immediately so a second tap cannot pass isRunning
    // while addMessage / director setup is still in flight.
    _setPhase(groupId, GroupChatPhase.directing);
    debugPrint('[GroupChat] phase=directing (claimed) group=$groupId');

    GroupChatMessage? userMessage;
    var endedBy = 'end_round';
    String? errorCode;
    String? errorMessage;
    var assistantCount = 0;
    String? lastSpeakerId;
    final maxAssistants = settings.maxAssistantMessagesPerUserTurn <= 0
        ? GroupChatSettings.defaultMaxAssistantMessagesPerUserTurn
        : settings.maxAssistantMessagesPerUserTurn;
    // Hoisted so finally can always flush the latest director transcript.
    var directorMessages = <Map<String, dynamic>>[];
    var directorMessagesTouched = false;

    try {
      userMessage = await groupChatService.addMessage(
        GroupChatMessage(
          groupId: groupId,
          role: 'user',
          content: text,
          speakerAssistantId: null,
        ),
      );
      debugPrint(
        '[GroupChat] user message saved id=${userMessage.id} '
        'order=${userMessage.messageOrder} group=$groupId',
      );

      var directorSession = await directorStore.ensure(groupId);
      directorSession = await directorStore.put(
        directorSession.copyWith(
          status: DirectorSession.statusDirecting,
          triggerUserMessageId: userMessage.id,
          clearErrorText: true,
          state: <String, dynamic>{
            ...directorSession.state,
            'assistantCountThisTurn': 0,
            'lastSpeakerId': null,
          },
          updatedAt: DateTime.now(),
        ),
      );

      // Build / refresh director messages for this user turn.
      directorMessages = List<Map<String, dynamic>>.from(
        directorSession.messages.map((e) => Map<String, dynamic>.from(e)),
      );

      final isFresh =
          directorMessages.isEmpty ||
          !directorMessages.any((m) => m['role'] == 'system');

      if (isFresh) {
        directorMessages = DirectorPromptBuilder.buildInitialMessages(
          systemPrompt: DirectorPromptBuilder.resolveSystemPrompt(settings),
          members: intros,
          userMessage: text,
          allowSameAssistantConsecutive: settings.allowSameAssistantConsecutive,
        );
      } else {
        directorMessages = DirectorPromptBuilder.appendPublicMessageAndAsk(
          directorMessages,
          publicMessage: userMessage,
          assistantNames: nameMap,
        );
      }
      directorMessagesTouched = true;

      if (settings.persistDirectorTranscript) {
        directorSession = await directorStore.put(
          directorSession.copyWith(
            messages: directorMessages,
            updatedAt: DateTime.now(),
          ),
        );
      }

      while (true) {
        _throwIfCancelled(groupId);

        if (!GroupChatRoundPolicy.canSpeakMore(
          count: assistantCount,
          max: maxAssistants,
        )) {
          endedBy = 'max_messages';
          debugPrint(
            '[GroupChat] hit max assistants=$maxAssistants group=$groupId',
          );
          break;
        }

        _setPhase(groupId, GroupChatPhase.directing);
        await directorStore.updateStatus(
          groupId,
          DirectorSession.statusDirecting,
        );

        final decision = await _runDirector(
          groupId: groupId,
          config: directorConfig,
          modelId: directorModelId,
          messages: directorMessages,
          allowedAssistantIds: allowedIds,
          temperature: null,
        );

        _throwIfCancelled(groupId);

        if (decision.endRound) {
          endedBy = 'end_round';
          // Record a short silent assistant ack in director history only.
          directorMessages =
              List<Map<String, dynamic>>.from(
                directorMessages.map((e) => Map<String, dynamic>.from(e)),
              )..add(<String, dynamic>{
                'role': 'assistant',
                'content': decision.reason == null || decision.reason!.isEmpty
                    ? '[tool] end_round'
                    : '[tool] end_round reason=${decision.reason}',
              });
          directorMessagesTouched = true;
          break;
        }

        final speakerId = decision.assistantId!;
        if (!allowedIds.contains(speakerId)) {
          throw GroupChatOrchestratorException(
            GroupChatErrorCode.memberNotFound,
            'Director selected unknown member $speakerId',
          );
        }
        if (!GroupChatRoundPolicy.allowsSpeaker(
          allowSameAssistantConsecutive: settings.allowSameAssistantConsecutive,
          lastSpeakerId: lastSpeakerId,
          nextAssistantId: speakerId,
        )) {
          // Treat illegal consecutive pick as end_round to avoid loops.
          debugPrint(
            '[GroupChat] consecutive speaker blocked: $speakerId group=$groupId',
          );
          directorMessages =
              List<Map<String, dynamic>>.from(
                directorMessages.map((e) => Map<String, dynamic>.from(e)),
              )..add(<String, dynamic>{
                'role': 'assistant',
                'content':
                    '[tool] end_round (blocked consecutive speaker $speakerId)',
              });
          directorMessagesTouched = true;
          endedBy = 'end_round';
          break;
        }

        directorMessages =
            List<Map<String, dynamic>>.from(
              directorMessages.map((e) => Map<String, dynamic>.from(e)),
            )..add(<String, dynamic>{
              'role': 'assistant',
              'content': decision.reason == null || decision.reason!.isEmpty
                  ? '[tool] select_speaker:$speakerId'
                  : '[tool] select_speaker:$speakerId reason=${decision.reason}',
            });
        directorMessagesTouched = true;

        _setPhase(groupId, GroupChatPhase.memberSpeaking);
        await directorStore.updateStatus(
          groupId,
          DirectorSession.statusMemberSpeaking,
          state: <String, dynamic>{
            'assistantCountThisTurn': assistantCount,
            'lastSpeakerId': lastSpeakerId,
            'currentSpeakerId': speakerId,
          },
        );

        final memberMsg = await _runMemberTurn(
          groupId: groupId,
          speakerAssistantId: speakerId,
          assistantNames: nameMap,
          appSettings: appSettings,
        );
        assistantOut.add(memberMsg);
        assistantCount += 1;
        lastSpeakerId = speakerId;
        debugPrint(
          '[GroupChat] member done speaker=$speakerId '
          'len=${memberMsg.content.length} count=$assistantCount group=$groupId',
        );

        directorMessages = DirectorPromptBuilder.appendPublicMessageAndAsk(
          directorMessages,
          publicMessage: memberMsg,
          assistantNames: nameMap,
        );
        directorMessagesTouched = true;

        if (settings.persistDirectorTranscript) {
          await directorStore.put(
            (await directorStore.ensure(groupId)).copyWith(
              messages: directorMessages,
              state: <String, dynamic>{
                'assistantCountThisTurn': assistantCount,
                'lastSpeakerId': lastSpeakerId,
              },
              updatedAt: DateTime.now(),
            ),
          );
        }
      }
    } on GroupChatOrchestratorException catch (e) {
      // User message is already persisted — never rethrow so UI can map
      // [GroupChatTurnResult.errorCode] to a concrete SnackBar (not generic fail).
      if (e.code == GroupChatErrorCode.cancelled) {
        endedBy = 'cancel';
        errorCode = e.code;
        errorMessage = e.message;
        debugPrint('[GroupChat] turn cancelled group=$groupId');
      } else {
        endedBy = 'error';
        errorCode = e.code;
        errorMessage = e.message;
        debugPrint(
          '[GroupChat] turn error group=$groupId code=${e.code} msg=${e.message}',
        );
        _setPhase(groupId, GroupChatPhase.error);
        try {
          await directorStore.updateStatus(
            groupId,
            DirectorSession.statusError,
            errorText: e.toString(),
          );
        } catch (storeErr) {
          debugPrint(
            '[GroupChat] director status error write failed: $storeErr',
          );
        }
      }
    } catch (e, st) {
      debugPrint('[GroupChat] turn failed group=$groupId: $e\n$st');
      endedBy = 'error';
      errorCode = GroupChatErrorCode.directorFailed;
      errorMessage = e.toString();
      _setPhase(groupId, GroupChatPhase.error);
      try {
        await directorStore.updateStatus(
          groupId,
          DirectorSession.statusError,
          errorText: e.toString(),
        );
      } catch (storeErr) {
        debugPrint('[GroupChat] director status error write failed: $storeErr');
      }
    } finally {
      _activeRequestIdByGroup.remove(groupId);
      _cancelRequested.remove(groupId);

      // Always flush latest director transcript (end_round / errors / max).
      if (settings.persistDirectorTranscript && directorMessagesTouched) {
        try {
          final existing = await directorStore.ensure(groupId);
          await directorStore.put(
            existing.copyWith(
              messages: directorMessages,
              state: <String, dynamic>{
                ...existing.state,
                'assistantCountThisTurn': assistantCount,
                'lastSpeakerId': lastSpeakerId,
                'lastEndedBy': endedBy,
                if (errorCode != null) 'lastErrorCode': errorCode,
              },
              updatedAt: DateTime.now(),
            ),
          );
          debugPrint(
            '[GroupChat] director transcript flushed msgs=${directorMessages.length} '
            'endedBy=$endedBy group=$groupId',
          );
        } catch (e) {
          debugPrint('[GroupChat] director transcript flush failed: $e');
        }
      }

      if (errorCode == null || errorCode == GroupChatErrorCode.cancelled) {
        _setPhase(groupId, GroupChatPhase.idle);
        try {
          await directorStore.updateStatus(
            groupId,
            DirectorSession.statusIdle,
            clearError: true,
            state: <String, dynamic>{
              'assistantCountThisTurn': assistantCount,
              'lastSpeakerId': lastSpeakerId,
              'lastEndedBy': endedBy,
            },
          );
        } catch (e) {
          debugPrint('[GroupChat] director idle status write failed: $e');
        }
      }
      notifyListeners();
    }

    debugPrint(
      '[GroupChat] turn done group=$groupId endedBy=$endedBy '
      'assistants=${assistantOut.length} errorCode=$errorCode',
    );

    final savedUser = userMessage;
    if (savedUser == null) {
      // Failed before the user row was written — surface as a thrown error so
      // the UI uses the pre-flight SnackBar path (no "reply failed" phrasing).
      throw GroupChatOrchestratorException(
        errorCode ?? GroupChatErrorCode.directorFailed,
        errorMessage ?? 'Failed before user message was saved',
      );
    }

    return GroupChatTurnResult(
      groupId: groupId,
      userMessage: savedUser,
      assistantMessages: List<GroupChatMessage>.of(assistantOut),
      endedBy: endedBy,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }

  void _setPhase(String groupId, GroupChatPhase phase) {
    _phaseByGroup[groupId] = phase;
    notifyListeners();
  }

  void _throwIfCancelled(String groupId) {
    if (_cancelRequested.contains(groupId)) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.cancelled,
        'Cancelled',
      );
    }
  }

  Future<DirectorDecision> _runDirector({
    required String groupId,
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required Set<String> allowedAssistantIds,
    double? temperature,
  }) async {
    final requestId = 'director_${groupId}_${const Uuid().v4()}';
    _activeRequestIdByGroup[groupId] = requestId;

    final tools = DirectorToolService.toolDefinitions(
      allowedAssistantIds: allowedAssistantIds.toList(),
    );
    final toolService = DirectorToolService();
    final handler = toolService.buildHandler(
      requestId: requestId,
      allowedAssistantIds: allowedAssistantIds,
    );
    final forcedToolBody = directorForcedToolChoiceExtraBody(config);

    debugPrint(
      '[GroupChat] director start group=$groupId model=${config.id}/$modelId '
      'tools=${tools.length} forcedToolChoice=$forcedToolBody',
    );

    DirectorDecision? fromChunk;

    try {
      await for (final chunk in sendMessageStream(
        GroupChatStreamRequest(
          config: config,
          modelId: modelId,
          messages: messages,
          tools: tools,
          onToolCall: handler,
          // 导演必须强制 tool_choice，与 thinking mode 互斥；
          // 显式关闭 thinking 避免 API 400。
          thinkingBudget: 0,
          temperature: temperature,
          stream: true,
          requestId: requestId,
          extraBody: forcedToolBody,
        ),
      )) {
        // User cancel only — tool-handler cancelRequest after a decision must
        // NOT be treated as cancelled (lastDecision path below handles it).
        _throwIfCancelled(groupId);

        if (toolService.lastDecision != null) {
          fromChunk = toolService.lastDecision;
          debugPrint(
            '[GroupChat] director decision via handler: ${fromChunk!.toJson()}',
          );
          break;
        }

        // Also accept toolCalls from the stream (some providers surface them
        // before/without awaiting onToolCall completion in edge cases).
        final tcs = chunk.toolCalls;
        if (tcs != null) {
          for (final tc in tcs) {
            final d = DirectorToolService.parseToolCall(tc.name, tc.arguments);
            if (d != null) {
              if (d.isSelectSpeaker &&
                  !allowedAssistantIds.contains(d.assistantId)) {
                debugPrint(
                  '[GroupChat] director tool ignored unknown speaker '
                  '${d.assistantId}',
                );
                continue;
              }
              fromChunk = d;
              toolService.lastDecision = d;
              debugPrint(
                '[GroupChat] director decision via chunk: ${d.toJson()}',
              );
              try {
                ChatApiService.cancelRequest(requestId);
              } catch (e) {
                debugPrint('[GroupChat] cancelRequest after decision: $e');
              }
              break;
            }
          }
        }
        if (fromChunk != null) break;
      }
    } on GroupChatOrchestratorException {
      rethrow;
    } catch (e) {
      if (_cancelRequested.contains(groupId)) {
        throw GroupChatOrchestratorException(
          GroupChatErrorCode.cancelled,
          'Cancelled',
        );
      }
      // Dio / provider cancel after decision is expected (handler stops stream).
      final decided = toolService.lastDecision ?? fromChunk;
      if (decided != null) {
        debugPrint(
          '[GroupChat] director stream error after decision (ok): $e '
          'decision=${decided.toJson()}',
        );
        return decided;
      }
      debugPrint('[GroupChat] director stream error: $e');
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.directorFailed,
        e.toString(),
        e,
      );
    } finally {
      if (_activeRequestIdByGroup[groupId] == requestId) {
        _activeRequestIdByGroup.remove(groupId);
      }
    }

    final decision = fromChunk ?? toolService.lastDecision;
    if (decision == null) {
      debugPrint(
        '[GroupChat] directorNoDecision group=$groupId model=${config.id}/$modelId',
      );
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.directorNoDecision,
        'Director did not call select_speaker or end_round',
      );
    }
    return decision;
  }

  Future<GroupChatMessage> _runMemberTurn({
    required String groupId,
    required String speakerAssistantId,
    required Map<String, String> assistantNames,
    required SettingsProvider appSettings,
  }) async {
    final assistant = resolveAssistant(speakerAssistantId);
    if (assistant == null) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.memberNotFound,
        'Assistant $speakerAssistantId not found',
      );
    }

    final providerKey =
        assistant.chatModelProvider ?? appSettings.currentModelProvider;
    final modelId = assistant.chatModelId ?? appSettings.currentModelId;
    if (providerKey == null ||
        providerKey.isEmpty ||
        modelId == null ||
        modelId.isEmpty) {
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.memberNoModel,
        'Member $speakerAssistantId has no model',
      );
    }

    final timeline = await groupChatService.getMessages(groupId);
    late final GroupMemberGenerationPreparation prepared;
    try {
      prepared = await prepareMemberGeneration(
        groupId: groupId,
        timeline: timeline,
        assistant: assistant,
        assistantNames: assistantNames,
        providerKey: providerKey,
        modelId: modelId,
        settings: appSettings,
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[GroupChatOrchestrator] member preparation failed '
        'group=$groupId member=$speakerAssistantId '
        'provider=$providerKey model=$modelId: $error\n$stackTrace',
      );
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.memberFailed,
        error.toString(),
        error,
      );
    }

    final placeholder = await groupChatService.addMessage(
      GroupChatMessage(
        groupId: groupId,
        role: 'assistant',
        content: '',
        speakerAssistantId: speakerAssistantId,
        modelId: modelId,
        providerId: providerKey,
        isStreaming: true,
      ),
    );

    final requestId = placeholder.id;
    _activeRequestIdByGroup[groupId] = requestId;

    try {
      return await runMemberStream(
        placeholder: placeholder,
        assistant: assistant,
        settings: appSettings,
        providerKey: providerKey,
        modelId: modelId,
        prepared: prepared,
        sendMessageStream: sendMessageStream,
        isCancelled: () => _cancelRequested.contains(groupId),
      );
    } catch (error, stackTrace) {
      if (_cancelRequested.contains(groupId)) {
        throw GroupChatOrchestratorException(
          GroupChatErrorCode.cancelled,
          'Cancelled',
        );
      }
      debugPrint(
        '[GroupChatOrchestrator] member stream failed '
        'group=$groupId member=$speakerAssistantId '
        'provider=$providerKey model=$modelId: $error\n$stackTrace',
      );
      throw GroupChatOrchestratorException(
        GroupChatErrorCode.memberFailed,
        error.toString(),
        error,
      );
    } finally {
      if (_activeRequestIdByGroup[groupId] == requestId) {
        _activeRequestIdByGroup.remove(groupId);
      }
    }
  }
}
