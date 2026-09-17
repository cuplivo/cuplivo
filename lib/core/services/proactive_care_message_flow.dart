import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/assistant.dart';
import '../models/assistant_regex.dart';
import '../models/conversation.dart';
import '../providers/settings_provider.dart';
import '../../utils/assistant_regex.dart';
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
  });

  final String conversationId;
  final String content;
  final bool notified;
}

/// In-process proactive care ("Ta 的来信") flow on the working-tree stack.
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
/// The fork ran pipeline ② inside a background alarm isolate against raw
/// SQLite. The working tree keeps both pipelines in the main isolate: alarms
/// only raise the notification, and [runDueSchedules] catches up on app
/// start/resume with full provider access. Same data, same outcome, one less
/// schema-coupled headless store.
class ProactiveCareMessageFlow {
  ProactiveCareMessageFlow({
    required this._chatService,
    required this._settings,
    this._memoryStore,
    this._instructionInjectionStore,
    this._worldBookStore,
    ProactiveCareDecisionSender? decisionSender,
    ProactiveCareCareSender? careSender,
    this._decisionTimeout = const Duration(seconds: 45),
  }) : _decisionSender = decisionSender ?? _defaultDecisionSender,
       _careSender = careSender ?? _defaultCareSender;

  final ChatService _chatService;
  final SettingsProvider _settings;
  final MemoryStore? _memoryStore;
  final InstructionInjectionStore? _instructionInjectionStore;
  final WorldBookStore? _worldBookStore;
  final ProactiveCareDecisionSender _decisionSender;
  final ProactiveCareCareSender _careSender;
  final Duration _decisionTimeout;

  static const String decisionModelPrefsKey =
      'proactive_care_decision_model_v1';

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

  /// Resolves the care model: the assistant's own chat model, falling back
  /// to the app-selected model.
  ProactiveCareModelConfig? resolveModelConfig(Assistant assistant) {
    var provKey = assistant.chatModelProvider;
    var modelId = assistant.chatModelId;
    provKey ??= _settings.currentModelProvider;
    modelId ??= _settings.currentModelId;
    if (provKey == null || modelId == null || provKey.isEmpty) return null;
    return ProactiveCareModelConfig(
      config: _settings.getProviderConfig(provKey),
      providerKey: provKey,
      modelId: modelId,
    );
  }

  /// Builds placeholder variables for the persona system prompt.
  Map<String, String> buildPersonaPlaceholders({
    required Assistant assistant,
    required String modelId,
    required String userNickname,
    required DateTime now,
  }) {
    return {
      'nickname': userNickname,
      'char': assistant.name,
      'model': modelId,
      'time': now.toIso8601String(),
      'date': now.toIso8601String().split('T').first,
    };
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
    final apiMessages = <Map<String, dynamic>>[
      for (final m in history) Map<String, dynamic>.of(m),
    ];

    apiMessages.add({
      'role': 'user',
      'content': ProactiveCareService.buildCareUserMessage(
        carePrompt: carePrompt,
        now: now,
      ),
    });

    if (assistant.systemPrompt.trim().isNotEmpty) {
      final vars = buildPersonaPlaceholders(
        assistant: assistant,
        modelId: modelId,
        userNickname: userNickname,
        now: now,
      );
      apiMessages.insert(0, {
        'role': 'system',
        'content': PromptTransformer.replacePlaceholders(
          assistant.systemPrompt,
          vars,
        ),
      });
    }

    if (assistant.enableMemory && _memoryStore != null) {
      try {
        final block = ProactiveCareService.buildMemoriesBlock(
          await _memoryStore.getForAssistant(assistant.id),
        );
        if (block.isNotEmpty) _appendToSystemMessage(apiMessages, block);
      } catch (e) {
        debugPrint('[ProactiveCare] Memory injection failed: $e');
      }
    }

    if (_instructionInjectionStore != null) {
      try {
        final actives = await _instructionInjectionStore.getActives(
          assistantId: assistant.id,
        );
        final prompts = actives
            .map((e) => e.prompt.trim())
            .where((p) => p.isNotEmpty)
            .toList(growable: false);
        if (prompts.isNotEmpty) {
          _appendToSystemMessage(apiMessages, prompts.join('\n\n'));
        }
      } catch (e) {
        debugPrint('[ProactiveCare] Instruction injection failed: $e');
      }
    }

    if (_worldBookStore != null) {
      try {
        final books = await _worldBookStore.getAll();
        final activeIds = await _worldBookStore.getActiveIds(
          assistantId: assistant.id,
        );
        final entries = <String>[];
        for (final book in books) {
          if (!activeIds.contains(book.id)) continue;
          for (final entry in book.entries) {
            final content = entry.content.trim();
            if (content.isEmpty) continue;
            entries.add(content);
          }
        }
        if (entries.isNotEmpty) {
          _appendToSystemMessage(apiMessages, entries.join('\n'));
        }
      } catch (e) {
        debugPrint('[ProactiveCare] World book injection failed: $e');
      }
    }

    _applyMessageLimit(apiMessages, assistant);
    return apiMessages;
  }

  static void _appendToSystemMessage(
    List<Map<String, dynamic>> apiMessages,
    String content,
  ) {
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      apiMessages[0]['content'] =
          '${(apiMessages[0]['content'] ?? '') as String}\n\n$content';
    } else {
      apiMessages.insert(0, {'role': 'system', 'content': content});
    }
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
    final text = await _careSender(
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

    var personaPrompt = '';
    if (assistant.systemPrompt.trim().isNotEmpty) {
      final vars = buildPersonaPlaceholders(
        assistant: assistant,
        modelId: modelId,
        userNickname: userNickname,
        now: now,
      );
      personaPrompt = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
    }
    String memoriesBlock = '';
    if (assistant.enableMemory && _memoryStore != null) {
      try {
        memoriesBlock = ProactiveCareService.buildMemoriesBlock(
          await _memoryStore.getForAssistant(assistant.id),
        );
      } catch (e) {
        debugPrint('[ProactiveCare] Decision memories load failed: $e');
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
      await _decisionSender(
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
      ).timeout(_decisionTimeout);
    } catch (e) {
      debugPrint('[ProactiveCare] Decision call failed: $e');
    }
    return (decided: decided, time: decisionTime);
  }

  /// Converts persisted messages into the plain `{role, content}` shape the
  /// silent requests consume.
  static List<Map<String, dynamic>> historyFromMessages(
    List<ChatMessageLike> messages,
  ) {
    return [
      for (final m in messages) {'role': m.role, 'content': m.content},
    ];
  }

  /// Claims and delivers every due schedule: for each eligible conversation
  /// whose next care time is not after [now], consumes the schedule, runs
  /// the care pipeline, persists the assistant reply, raises a notification
  /// and asks the decision model for the next time. Returns the delivered
  /// letters.
  Future<List<ProactiveCareDelivery>> runDueSchedules({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
    required String userNickname,
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now();
    final delivered = <ProactiveCareDelivery>[];

    final candidates = conversations.where((c) {
      final at = c.proactiveCareNextMessageAt;
      return at != null && !at.isAfter(current);
    });

    for (final conversation in candidates) {
      final assistant = assistants.firstWhereOrNull(
        (a) =>
            a.id == conversation.assistantId &&
            ProactiveCareConversationPolicy.isEligible(conversation, a),
      );
      if (assistant == null) continue;

      final model = resolveModelConfig(assistant);
      if (model == null) continue;

      // Claim: consume the schedule first so a concurrent runner cannot
      // double-deliver.
      final expectedAt = conversation.proactiveCareNextMessageAt!;
      final claimed = await _claimSchedule(conversation.id, expectedAt);
      if (claimed == null) continue;

      final history = await _chatService.loadMessages(claimed.id);
      final apiHistory = historyFromMessages(
        history.map((m) => ChatMessageLike(m.role, m.content)).toList(),
      );
      final apiMessages = await buildCareApiMessages(
        assistant: assistant,
        modelId: model.modelId,
        userNickname: userNickname,
        history: apiHistory,
        carePrompt: assistant.proactiveCarePrompt,
        now: current,
      );

      String reply = '';
      try {
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

      if (reply.isNotEmpty) {
        await _chatService.addMessage(
          conversationId: claimed.id,
          role: 'assistant',
          content: reply,
          providerId: model.providerKey,
          modelId: model.modelId,
        );
        var notified = false;
        try {
          await NotificationService.showProactiveCareLetter(
            conversationId: claimed.id,
            title: assistant.name,
            body: reply,
          );
          notified = true;
        } catch (e) {
          debugPrint('[ProactiveCare] Notification failed: $e');
        }
        delivered.add(
          ProactiveCareDelivery(
            conversationId: claimed.id,
            content: reply,
            notified: notified,
          ),
        );
      }

      // Ask the decision model for the next time (best effort).
      try {
        final nextAt = await decideNextCareTime(
          config: model.config,
          modelId: model.modelId,
          assistant: assistant,
          userNickname: userNickname,
          history: apiHistory,
          decisionPrompt: assistant.proactiveCareDecisionPrompt,
          conversationId: claimed.id,
          currentNextCareTime: null,
        );
        if (nextAt != null) {
          await _chatService.updateConversationExtras(claimed.id, (extras) {
            extras[Conversation.proactiveCareNextMessageAtKey] = nextAt
                .toIso8601String();
            return extras;
          });
        }
      } catch (e) {
        debugPrint('[ProactiveCare] Next-time decision failed: $e');
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
    await _chatService.updateConversationExtras(conversationId, (extras) {
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
    if (claimed == null) return null;
    // Re-read the real conversation record for title and the rest.
    final fresh = _chatService.getConversation(conversationId);
    return fresh ?? claimed;
  }
}

/// Minimal {role, content} view of a persisted chat message for the silent
/// history shape.
class ChatMessageLike {
  const ChatMessageLike(this.role, this.content);

  final String role;
  final String content;
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
