import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';

import '../../features/home/utils/model_display_helper.dart';
import '../../utils/assistant_regex.dart';
import '../../utils/avatar_cache.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../models/assistant.dart';
import '../models/assistant_regex.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/settings_provider.dart';
import 'api/chat_api_service.dart';
import 'chat/chat_service.dart';
import 'chat/prompt_transformer.dart';
import 'instruction_injection_store.dart';
import 'memory_store.dart';
import 'notification_service.dart';
import 'proactive_care_conversation_policy.dart';
import 'proactive_care_decision_tools.dart';
import 'proactive_care_service.dart';
import 'world_book_store.dart';

/// Sender signature for the silent decision request (injectable for tests).
/// Mirrors the relevant subset of [ChatApiService.generateMessage].
typedef ProactiveCareDecisionSender =
    Future<dynamic> Function({
      required ProviderConfig config,
      required String modelId,
      required List<Map<String, dynamic>> messages,
      required List<Map<String, dynamic>> tools,
      ToolCallHandler? onToolCall,
      int? thinkingBudget,
      double? topP,
      int? maxTokens,
      String? requestId,
      String? conversationId,
    });

/// Sender signature for the silent care reply (injectable for tests).
typedef ProactiveCareCareSender =
    Future<String> Function({
      required ProviderConfig config,
      required String modelId,
      required List<Map<String, dynamic>> messages,
      int? thinkingBudget,
      double? topP,
      int? maxTokens,
      String? conversationId,
    });

/// Resolved model for a silent proactive-care request.
class ProactiveCareModelConfig {
  const ProactiveCareModelConfig({
    required this.config,
    required this.providerKey,
    required this.modelId,
  });

  final ProviderConfig config;
  final String providerKey;
  final String modelId;
}

/// Outcome of one delivered care letter.
class ProactiveCareDelivery {
  const ProactiveCareDelivery({
    required this.conversationId,
    required this.content,
    required this.notified,
    required this.successful,
  });

  final String conversationId;
  final String content;
  final bool notified;

  /// False when generation failed and (at most) a failure notification was
  /// raised instead of a letter.
  final bool successful;
}

/// Proactive care ("Ta的来信") flow on the working-tree stack.
///
/// Two pipelines, both silent (the requests never appear as user messages):
/// ① Decision — after each completed assistant reply, a tool-carrying request
///    asks the model to move or keep the next care time
///    (see [ProactiveCareDecisionTools]).
/// ② Care — when a scheduled time is due, the care prompt is answered from
///    the assistant persona + memories + injections and the reply is
///    persisted directly into the conversation as an assistant message,
///    followed by a local notification.
///
/// The v3.2.1 fork ran pipeline ② inside a background alarm isolate against
/// raw SQLite. Here the Android alarm only wakes the engine; both pipelines
/// always run in the main isolate with full provider access, claiming the
/// schedule atomically through `updateConversationExtras` so a foreground
/// delivery and an alarm-driven one can never double-deliver.
class ProactiveCareMessageFlow {
  ProactiveCareMessageFlow({
    required this.chatService,
    required this.settings,
    this.memoryStore,
    this.instructionInjectionStore,
    this.worldBookStore,
    ProactiveCareDecisionSender? decisionSender,
    ProactiveCareCareSender? careSender,
    this.decisionTimeout = const Duration(seconds: 45),
  }) : decisionSender = decisionSender ?? _defaultDecisionSender,
       careSender = careSender ?? _defaultCareSender;

  final ChatService chatService;
  final SettingsProvider settings;
  final MemoryStore? memoryStore;
  final InstructionInjectionStore? instructionInjectionStore;
  final WorldBookStore? worldBookStore;
  final ProactiveCareDecisionSender decisionSender;
  final ProactiveCareCareSender careSender;
  final Duration decisionTimeout;

  static Future<dynamic> _defaultDecisionSender({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    ToolCallHandler? onToolCall,
    int? thinkingBudget,
    double? topP,
    int? maxTokens,
    bool stream = false,
    String? requestId,
    String? conversationId,
  }) {
    return ChatApiService.generateMessage(
      config: config,
      modelId: modelId,
      messages: messages,
      tools: tools,
      onToolCall: onToolCall,
      thinkingBudget: thinkingBudget,
      topP: topP,
      maxTokens: maxTokens,
      requestId: requestId,
      conversationId: conversationId,
    );
  }

  static Future<String> _defaultCareSender({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    int? thinkingBudget,
    double? topP,
    int? maxTokens,
    String? conversationId,
  }) async {
    final result = await ChatApiService.generateMessage(
      config: config,
      modelId: modelId,
      messages: messages,
      thinkingBudget: thinkingBudget,
      topP: topP,
      maxTokens: maxTokens,
      conversationId: conversationId,
    );
    return result.text;
  }

  /// Resolves the care model for a conversation: the conversation's own
  /// override, else the assistant's model, else the app-selected model
  /// (the same chain as normal chat).
  ProactiveCareModelConfig? resolveModelConfig(
    Assistant assistant, {
    Conversation? conversation,
  }) {
    final resolved = resolveChatModel(
      settings,
      conversation: conversation,
      assistant: assistant,
    );
    final provKey = resolved.providerKey;
    final modelId = resolved.modelId;
    if (provKey == null || provKey.isEmpty || modelId == null) return null;
    return ProactiveCareModelConfig(
      config: settings.getProviderConfig(provKey),
      providerKey: provKey,
      modelId: modelId,
    );
  }

  /// Resolves the decision model: the dedicated proactive-care decision
  /// model when configured, else the same model the letter itself would use.
  ProactiveCareModelConfig? resolveDecisionModelConfig(
    Assistant assistant, {
    Conversation? conversation,
  }) {
    final decisionProvider = settings.proactiveCareDecisionModelProvider;
    final decisionModel = settings.proactiveCareDecisionModelId;
    if (decisionProvider != null &&
        decisionProvider.isNotEmpty &&
        decisionModel != null) {
      return ProactiveCareModelConfig(
        config: settings.getProviderConfig(decisionProvider),
        providerKey: decisionProvider,
        modelId: decisionModel,
      );
    }
    return resolveModelConfig(assistant, conversation: conversation);
  }

  /// Builds placeholder variables for the persona system prompt.
  Map<String, String> buildPersonaPlaceholders({
    required Assistant assistant,
    required String modelId,
    required String userNickname,
    required DateTime now,
  }) {
    return {
      '{nickname}': userNickname,
      '{assistant_name}': assistant.name,
      '{model_id}': modelId,
      '{model_name}': modelId,
      '{time}':
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
      '{date}':
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}',
      '{cur_datetime}': now.toIso8601String(),
    };
  }

  String _buildPersonaPrompt({
    required Assistant assistant,
    required String modelId,
    required String userNickname,
    required DateTime now,
  }) {
    if (assistant.systemPrompt.trim().isEmpty) return '';
    final vars = buildPersonaPlaceholders(
      assistant: assistant,
      modelId: modelId,
      userNickname: userNickname,
      now: now,
    );
    return PromptTransformer.replacePlaceholders(assistant.systemPrompt, vars);
  }

  /// Assembles the silent care request: persona system + memories +
  /// instruction injections + world book entries + history + the care
  /// prompt as the final user turn, tail-limited to the assistant's context
  /// window.
  Future<List<Map<String, dynamic>>> buildCareApiMessages({
    required Assistant assistant,
    required String modelId,
    required String userNickname,
    required List<Map<String, dynamic>> history,
    required String carePrompt,
    required DateTime now,
  }) async {
    final systemBlocks = <String>[];
    final persona = _buildPersonaPrompt(
      assistant: assistant,
      modelId: modelId,
      userNickname: userNickname,
      now: now,
    );
    if (persona.isNotEmpty) systemBlocks.add(persona);

    final store = memoryStore;
    if (assistant.enableMemory && store != null) {
      try {
        final block = ProactiveCareService.buildMemoriesBlock(
          await store.getForAssistant(assistant.id),
        );
        if (block.isNotEmpty) systemBlocks.add(block);
      } catch (e) {
        debugPrint('[ProactiveCare] Memory injection failed: $e');
      }
    }

    final injectionStore = instructionInjectionStore;
    if (injectionStore != null) {
      try {
        final actives = await injectionStore.getActives(
          assistantId: assistant.id,
        );
        final prompts = actives
            .map((e) => e.prompt.trim())
            .where((p) => p.isNotEmpty)
            .toList(growable: false);
        if (prompts.isNotEmpty) systemBlocks.add(prompts.join('\n\n'));
      } catch (e) {
        debugPrint('[ProactiveCare] Instruction injection failed: $e');
      }
    }

    final bookStore = worldBookStore;
    if (bookStore != null) {
      try {
        final books = await bookStore.getAll();
        final activeIds = await bookStore.getActiveIds(
          assistantId: assistant.id,
        );
        final entries = [
          for (final b in books)
            if (activeIds.contains(b.id))
              for (final e in b.entries)
                if (e.content.trim().isNotEmpty) e.content.trim(),
        ];
        if (entries.isNotEmpty) systemBlocks.add(entries.join('\n'));
      } catch (e) {
        debugPrint('[ProactiveCare] World book injection failed: $e');
      }
    }

    final apiMessages = <Map<String, dynamic>>[
      if (systemBlocks.isNotEmpty)
        {'role': 'system', 'content': systemBlocks.join('\n\n')},
      for (final m in history) Map<String, dynamic>.of(m),
      {
        'role': 'user',
        'content': ProactiveCareService.buildCareUserMessage(
          carePrompt: carePrompt,
          now: now,
        ),
      },
    ];

    _applyMessageLimit(apiMessages, assistant);
    return apiMessages;
  }

  /// Keeps the trailing [Assistant.contextMessageSize] messages; the system
  /// message (when first) is preserved.
  static void _applyMessageLimit(
    List<Map<String, dynamic>> apiMessages,
    Assistant assistant,
  ) {
    final limit = assistant.contextMessageSize;
    if (apiMessages.length <= limit) return;
    final hasSystem = apiMessages.first['role'] == 'system';
    final system = hasSystem ? apiMessages.first : null;
    final tail = apiMessages.sublist(apiMessages.length - (limit - 1));
    apiMessages
      ..clear()
      ..addAll([if (system != null) system, ...tail]);
  }

  /// Sends the silent care request and returns the regex-transformed reply.
  Future<String> requestCareReply({
    required ProviderConfig config,
    required String modelId,
    required Assistant assistant,
    required List<Map<String, dynamic>> apiMessages,
    String? conversationId,
  }) async {
    final text = await careSender(
      config: config,
      modelId: modelId,
      messages: apiMessages,
      thinkingBudget: assistant.thinkingBudget,
      topP: assistant.topP,
      maxTokens: assistant.maxTokens,
      conversationId: conversationId,
    );
    return applyAssistantRegexes(
      text,
      assistant: assistant,
      scope: AssistantRegexScope.assistant,
      target: AssistantRegexTransformTarget.persist,
    ).trim();
  }

  /// Silently asks the decision model for the next care time via tool calls.
  /// Returns null when the model keeps the current time, declines, fails, or
  /// returns an invalid/past time.
  Future<DateTime?> decideNextCareTime({
    required ProviderConfig config,
    required String modelId,
    required Assistant assistant,
    required String userNickname,
    required List<Map<String, dynamic>> history,
    required String decisionPrompt,
    String? conversationId,
    required DateTime? currentNextCareTime,
  }) async {
    if (history.isEmpty) return null;
    final now = DateTime.now();

    final personaPrompt = _buildPersonaPrompt(
      assistant: assistant,
      modelId: modelId,
      userNickname: userNickname,
      now: now,
    );
    String memoriesBlock = '';
    {
      final store = memoryStore;
      if (assistant.enableMemory && store != null) {
        try {
          memoriesBlock = ProactiveCareService.buildMemoriesBlock(
            await store.getForAssistant(assistant.id),
          );
        } catch (e) {
          debugPrint('[ProactiveCare] Decision memories load failed: $e');
        }
      }
    }

    final configuredLimit = assistant.proactiveCareDecisionHistoryMessageLimit;
    final effectiveHistory =
        configuredLimit == null || history.length <= configuredLimit
        ? history
        : history.sublist(history.length - configuredLimit);

    final apiMessages = ProactiveCareService.buildDecisionApiMessages(
      decisionPrompt: decisionPrompt,
      currentNextCareTime: currentNextCareTime,
      now: now,
      history: effectiveHistory,
      personaPrompt: personaPrompt,
      memoriesBlock: memoriesBlock,
    );
    final tools = ProactiveCareDecisionTools.definitions();
    final requestId =
        'proactive-care-decision-${assistant.id}-${now.microsecondsSinceEpoch}';

    final first = await _callDecisionOnce(
      config: config,
      modelId: modelId,
      messages: apiMessages,
      tools: tools,
      assistant: assistant,
      conversationId: conversationId,
      requestId: requestId,
    );
    if (first.decided) return first.time;

    // One retry with an explicit tool-only directive (Director pattern).
    final retryMessages = List<Map<String, dynamic>>.from(apiMessages)
      ..add({
        'role': 'user',
        'content': ProactiveCareService.builtinDecisionToolOnlyDirective,
      });
    final second = await _callDecisionOnce(
      config: config,
      modelId: modelId,
      messages: retryMessages,
      tools: tools,
      assistant: assistant,
      conversationId: conversationId,
      requestId: '$requestId-retry',
    );
    if (second.decided) return second.time;
    return null;
  }

  /// One decision attempt. `decided == true` means a recognized tool call
  /// settled the outcome (`time` may still be null = keep current time).
  Future<({bool decided, DateTime? time})> _callDecisionOnce({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required Assistant assistant,
    String? conversationId,
    required String requestId,
  }) async {
    var decided = false;
    DateTime? decisionTime;

    void maybeDecide(String name, Map<String, dynamic> args) {
      if (decided) return;
      if (ProactiveCareDecisionTools.isKeepTime(name)) {
        decided = true;
        decisionTime = null;
      } else if (ProactiveCareDecisionTools.isUpdateTime(name)) {
        decided = true;
        // Validate against a fresh clock: the footer `now` can be stale by
        // the time a tool call arrives.
        decisionTime = ProactiveCareDecisionTools.parseUpdateTimeArgs(
          args,
          now: DateTime.now(),
        );
      }
      // Unknown tool names stay undecided.
    }

    try {
      await decisionSender(
        config: config,
        modelId: modelId,
        messages: messages,
        tools: tools,
        onToolCall: (name, args, {toolCallId}) async {
          maybeDecide(name, args);
          // Keep the result neutral — never 'ignored' (models retry-loop).
          return jsonEncode({'ok': true});
        },
        thinkingBudget: assistant.thinkingBudget,
        topP: assistant.topP,
        maxTokens: assistant.maxTokens,
        requestId: requestId,
        conversationId: conversationId,
      ).timeout(decisionTimeout);
    } catch (e) {
      debugPrint('[ProactiveCare] Decision call failed: $e');
    }
    return (decided: decided, time: decisionTime);
  }

  /// Converts persisted messages into the plain `{role, content}` shape the
  /// silent requests consume. Only completed, non-empty user/assistant
  /// turns participate.
  static List<Map<String, dynamic>> historyFromMessages(
    List<ChatMessage> messages,
  ) {
    return [
      for (final m in messages)
        if ((m.role == 'user' || m.role == 'assistant') &&
            !m.isStreaming &&
            m.content.trim().isNotEmpty)
          {'role': m.role, 'content': m.content},
    ];
  }

  /// Delivers the one schedule an alarm (or the due-check) selected: claims
  /// it atomically, runs the care pipeline, persists the assistant reply,
  /// raises a notification and asks the decision model for the next time.
  ///
  /// Returns null when the claim lost the race (nothing was scheduled at
  /// [expectedAt] any more); otherwise the delivery outcome (which may be a
  /// failed generation with a failure notification).
  Future<ProactiveCareDelivery?> runSchedule({
    required String conversationId,
    required DateTime expectedAt,
    required List<Assistant> assistants,
    required String userNickname,
    String? carePromptFallback,
    String? decisionPromptFallback,
    String? failureNotificationBody,
    int? notificationId,
  }) async {
    final conversation = chatService.getConversation(conversationId);
    if (conversation == null) return null;
    final id = conversation.assistantId;
    if (id == null) return null;
    final assistant = assistants.where((a) => a.id == id).firstOrNull;
    if (assistant == null) return null;
    if (!ProactiveCareConversationPolicy.isEligible(conversation, assistant)) {
      return null;
    }

    final claimed = await _claimSchedule(conversationId, expectedAt);
    if (claimed == null) return null;

    final model = resolveModelConfig(assistant, conversation: claimed);
    if (model == null) {
      debugPrint('[ProactiveCare] No chat model configured; letter skipped');
      return _notifyFailure(
        conversationId: conversationId,
        assistant: assistant,
        failureNotificationBody: failureNotificationBody,
        notificationId: notificationId,
      );
    }

    final history = historyFromMessages(
      await chatService.loadMessages(claimed.id),
    );
    final carePrompt = assistant.proactiveCarePrompt.trim().isNotEmpty
        ? assistant.proactiveCarePrompt
        : (carePromptFallback ?? '');

    String reply = '';
    try {
      final apiMessages = await buildCareApiMessages(
        assistant: assistant,
        modelId: model.modelId,
        userNickname: userNickname,
        history: history,
        carePrompt: carePrompt,
        now: DateTime.now(),
      );
      reply = await requestCareReply(
        config: model.config,
        modelId: model.modelId,
        assistant: assistant,
        apiMessages: apiMessages,
        conversationId: claimed.id,
      );
    } catch (e) {
      debugPrint('[ProactiveCare] Care reply failed: $e');
    }

    if (reply.isEmpty) {
      return _notifyFailure(
        conversationId: conversationId,
        assistant: assistant,
        failureNotificationBody: failureNotificationBody,
        notificationId: notificationId,
      );
    }

    await chatService.addMessage(
      conversationId: claimed.id,
      role: 'assistant',
      content: reply,
      providerId: model.providerKey,
      modelId: model.modelId,
    );

    var notified = false;
    try {
      await NotificationService.showProactiveCareLetter(
        id:
            notificationId ??
            NotificationService.proactiveCareIdFor(conversationId),
        conversationId: claimed.id,
        title: assistant.name,
        body: reply,
        largeIconPath: await resolveProactiveCareNotificationIconPath(
          assistant,
          notificationId ??
              NotificationService.proactiveCareIdFor(conversationId),
        ),
      );
      notified = true;
    } catch (e) {
      debugPrint('[ProactiveCare] Notification failed: $e');
    }

    await _decideAndStoreNextTime(
      conversation: claimed,
      assistant: assistant,
      model: model,
      userNickname: userNickname,
      history: history,
      decisionPromptFallback: decisionPromptFallback,
    );

    return ProactiveCareDelivery(
      conversationId: claimed.id,
      content: reply,
      notified: notified,
      successful: true,
    );
  }

  Future<ProactiveCareDelivery> _notifyFailure({
    required String conversationId,
    required Assistant assistant,
    required String? failureNotificationBody,
    int? notificationId,
  }) async {
    var notified = false;
    final body = failureNotificationBody?.trim() ?? '';
    if (body.isNotEmpty) {
      try {
        await NotificationService.showProactiveCareLetter(
          id:
              notificationId ??
              NotificationService.proactiveCareIdFor(conversationId),
          conversationId: conversationId,
          title: assistant.name,
          body: body,
        );
        notified = true;
      } catch (e) {
        debugPrint('[ProactiveCare] Failure notification failed: $e');
      }
    }
    return ProactiveCareDelivery(
      conversationId: conversationId,
      content: '',
      notified: notified,
      successful: false,
    );
  }

  /// Best-effort next-time decision after a delivered (or failed) letter;
  /// failures only log — the conversation simply stays unscheduled until
  /// the next reply re-runs the decision pipeline.
  Future<void> _decideAndStoreNextTime({
    required Conversation conversation,
    required Assistant assistant,
    required ProactiveCareModelConfig model,
    required String userNickname,
    required List<Map<String, dynamic>> history,
    String? decisionPromptFallback,
  }) async {
    try {
      final decisionModel = resolveDecisionModelConfig(
        assistant,
        conversation: conversation,
      );
      if (decisionModel == null) return;
      final decisionPrompt =
          assistant.proactiveCareDecisionPrompt.trim().isNotEmpty
          ? assistant.proactiveCareDecisionPrompt
          : (decisionPromptFallback ?? '');
      final nextAt = await decideNextCareTime(
        config: decisionModel.config,
        modelId: decisionModel.modelId,
        assistant: assistant,
        userNickname: userNickname,
        history: history,
        decisionPrompt: decisionPrompt,
        conversationId: conversation.id,
        currentNextCareTime: null,
      );
      if (nextAt != null) {
        await chatService.updateConversationExtras(conversation.id, (extras) {
          extras[Conversation.proactiveCareNextMessageAtKey] = nextAt
              .toIso8601String();
          return extras;
        });
      }
    } catch (e) {
      debugPrint('[ProactiveCare] Next-time decision failed: $e');
    }
  }

  /// Delivers every due care letter for all eligible conversations (app
  /// start / resume catch-up). Returns the delivered outcomes.
  Future<List<ProactiveCareDelivery>> runDueSchedules({
    required List<Assistant> assistants,
    required String userNickname,
    String? carePromptFallback,
    String? decisionPromptFallback,
    String? failureNotificationBody,
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now();
    final delivered = <ProactiveCareDelivery>[];

    final candidates = chatService
        .getAllConversations()
        .where((c) {
          final at = c.proactiveCareNextMessageAt;
          return at != null && !at.isAfter(current);
        })
        .toList(growable: false);

    final assistantsById = {for (final a in assistants) a.id: a};

    for (final conversation in candidates) {
      final assistantId = conversation.assistantId;
      final assistant = assistantId == null
          ? null
          : assistantsById[assistantId];
      if (assistant == null) continue;
      if (!ProactiveCareConversationPolicy.isEligible(
        conversation,
        assistant,
      )) {
        continue;
      }
      try {
        final outcome = await runSchedule(
          conversationId: conversation.id,
          expectedAt: conversation.proactiveCareNextMessageAt!,
          assistants: assistants,
          userNickname: userNickname,
          carePromptFallback: carePromptFallback,
          decisionPromptFallback: decisionPromptFallback,
          failureNotificationBody: failureNotificationBody,
        );
        if (outcome != null) delivered.add(outcome);
      } catch (e) {
        debugPrint('[ProactiveCare] Due delivery failed: $e');
      }
    }
    return delivered;
  }

  /// Atomically consumes the persisted schedule: clears the stored next time
  /// only when it still matches [expectedAt]. Returns the updated
  /// conversation, or null when the claim lost the race.
  Future<Conversation?> _claimSchedule(
    String conversationId,
    DateTime expectedAt,
  ) async {
    Conversation? claimed;
    try {
      await chatService.updateConversationExtras(conversationId, (extras) {
        final current = extras[Conversation.proactiveCareNextMessageAtKey];
        if (current is String &&
            DateTime.tryParse(current) == expectedAt &&
            claimed == null) {
          claimed = Conversation(
            id: conversationId,
            title: '',
            extras: {...extras},
          );
          extras.remove(Conversation.proactiveCareNextMessageAtKey);
        }
        return extras;
      });
    } on StateError catch (e) {
      // conversation_not_found — the conversation vanished mid-flight.
      debugPrint('[ProactiveCare] Claim failed: $e');
      return null;
    }
    if (claimed == null) return null;
    // Re-read the real conversation record for title and the rest.
    final fresh = chatService.getConversation(conversationId);
    return fresh ?? claimed;
  }
}

/// Resolves the assistant avatar path for the notification large icon.
/// Android API 24+ automatically masks notification large icons to circles.
/// Returns null for emoji/initial-letter avatars or missing files.
Future<String?> resolveProactiveCareNotificationIconPath(
  Assistant assistant, [
  int? notificationId,
]) async {
  if (!Platform.isAndroid) return null;
  final avatar = assistant.avatar?.trim() ?? '';
  if (avatar.isEmpty) return null;

  try {
    if (avatar.startsWith('http://') || avatar.startsWith('https://')) {
      final cached = await AvatarCache.getPath(avatar);
      if (cached != null && File(cached).existsSync()) return cached;
    } else if (avatar.startsWith('/') || avatar.contains(':')) {
      final fixed = SandboxPathResolver.fix(avatar);
      if (File(fixed).existsSync()) return fixed;
    }
  } catch (e) {
    debugPrint('[ProactiveCare] Avatar resolve failed: $e');
  }
  return null;
}
