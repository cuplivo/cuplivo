import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/models/group_chat_director_log.dart';
import '../../../core/models/auto_retry_options.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import 'director_context_builder.dart';
import 'director_tool_protocol.dart';

/// Stream source signature used by [DirectorRunner] (injectable for tests).
typedef DirectorStreamSender =
    Stream<ChatStreamChunk> Function({
      required ProviderConfig config,
      required String modelId,
      required List<Map<String, dynamic>> messages,
      List<String>? userMediaPaths,
      int? thinkingBudget,
      double? temperature,
      double? topP,
      int? maxTokens,
      List<Map<String, dynamic>>? tools,
      ToolCallHandler? onToolCall,
      Map<String, String>? extraHeaders,
      Map<String, dynamic>? extraBody,
      bool stream,
      String? requestId,
      bool allowImagesApiRouting,
      bool ocrActive,
      AutoRetryOptions? retryOverride,
    });

typedef DirectorRuntimeLogSink = void Function(GroupChatDirectorRuntimeLog log);

/// Runs one director decision via tool-calling.
///
/// Uses the same transport as normal chat ([ChatApiService.sendMessageStream])
/// with provider-default `tool_choice: auto` (not `required`), so DeepSeek and
/// other OpenAI-compatible hosts that reject forced tools still work.
///
/// Director history is not persisted; each call is assembled from the public
/// conversation transcript.
class DirectorRunner {
  DirectorRunner({
    required this.chatService,
    required this.contextBuilder,
    DirectorStreamSender? sendMessageStream,
  }) : _sendMessageStream =
           sendMessageStream ?? ChatApiService.sendMessageStream;

  final ChatService chatService;
  final DirectorContextBuilder contextBuilder;
  final DirectorStreamSender _sendMessageStream;

  static const temperature = 0.2;
  static const maxTokens = 512;
  static const timeout = Duration(seconds: 45);

  Future<DirectorDecision> run({
    required GroupChat group,
    required String newUserContent,
    required List<Assistant> rosterAssistants,
    required String userName,
    required List<String> memberNames,
    required SettingsProvider settings,
    required bool Function(String providerKey, String modelId)
    modelSupportsTools,
    required List<ChatMessage> publicMessages,
    required Map<String, int> versionSelections,
    required Map<String, Assistant> assistantsById,
    String? skipPendingCapMessageId,
    String? excludeTrailingUserMessageId,
    String? sourceMessageId,
    GroupChatDirectorLogTrigger trigger = GroupChatDirectorLogTrigger.user,
    DirectorRuntimeLogSink? onRuntimeLog,
  }) async {
    final startedAt = DateTime.now();
    String? providerKey;
    String? modelId;
    var requestMessageCount = 0;
    var attemptCount = 0;
    final attemptErrors = <String>[];
    String? lastError;
    String? lastFreeText;
    DirectorDecision? decision;
    var runtimeLogEmitted = false;

    void emitRuntimeLog({String? failure}) {
      if (runtimeLogEmitted || onRuntimeLog == null) return;
      runtimeLogEmitted = true;
      // Logging is best-effort: a throwing sink must never break the director
      // flow (it would otherwise mask the real decision or a DirectorSoftError).
      try {
        onRuntimeLog(
          GroupChatDirectorRuntimeLog(
            sourceMessageId: sourceMessageId,
            trigger: trigger,
            startedAt: startedAt,
            finishedAt: DateTime.now(),
            providerKey: providerKey,
            modelId: modelId,
            requestMessageCount: requestMessageCount,
            attemptCount: attemptCount,
            attemptErrors: attemptErrors,
            decisionKind: decision?.kind.name,
            assistantId: decision?.assistantId,
            reason: _clipNullable(decision?.reason, 500),
            fallback: decision?.fallback ?? false,
            freeText: _clipNullable(lastFreeText, 500),
            failure: _clipNullable(failure, 300),
          ),
        );
      } catch (e) {
        debugPrint('[Director] runtime log sink failed: $e');
      }
    }

    try {
      providerKey =
          (group.directorModelProvider ?? settings.currentModelProvider)
              ?.trim();
      modelId = (group.directorModelId ?? settings.currentModelId)?.trim();

      if (providerKey == null ||
          providerKey.isEmpty ||
          modelId == null ||
          modelId.isEmpty) {
        debugPrint('[Director] no model configured');
        emitRuntimeLog(failure: 'no_model');
        throw DirectorSoftError(DirectorSoftErrorKind.noModel);
      }

      if (!modelSupportsTools(providerKey, modelId)) {
        debugPrint('[Director] model lacks tools: $providerKey/$modelId');
        emitRuntimeLog(failure: 'no_tools');
        throw DirectorSoftError(DirectorSoftErrorKind.noTools);
      }

      final config = settings.getProviderConfig(providerKey);
      final assistantIds = rosterAssistants.map((a) => a.id).toList();
      final tools = DirectorTools.definitions(assistantIds);

      final apiMessages = contextBuilder.buildApiMessagesFromPublic(
        group: group,
        publicMessages: publicMessages,
        versionSelections: versionSelections,
        newUserContent: newUserContent,
        rosterAssistants: rosterAssistants,
        userName: userName,
        memberNames: memberNames,
        assistantsById: assistantsById,
        skipPendingCapMessageId: skipPendingCapMessageId,
        excludeTrailingUserMessageId: excludeTrailingUserMessageId,
      );
      requestMessageCount = apiMessages.length;

      final requestStamp = DateTime.now().microsecondsSinceEpoch;

      try {
        attemptCount++;
        final result = await _callOnce(
          config: config,
          modelId: modelId,
          messages: apiMessages,
          tools: tools,
          assistantIds: assistantIds,
          requestId: 'director-${group.id}-$requestStamp',
        );
        decision = result.decision;
        lastFreeText = result.freeText;
      } catch (e) {
        lastError = _describeError(e);
        attemptErrors.add(lastError);
        debugPrint('[Director] first call failed: $e');
      }

      if (decision == null) {
        final retryMessages = List<Map<String, dynamic>>.from(apiMessages)
          ..add({
            'role': 'user',
            'content':
                'You must respond ONLY by calling the tools select_speaker or '
                'end_turn. Do not write free-text answers. '
                'Valid assistant_id values: ${assistantIds.join(', ')}',
          });
        try {
          attemptCount++;
          final result = await _callOnce(
            config: config,
            modelId: modelId,
            messages: retryMessages,
            tools: tools,
            assistantIds: assistantIds,
            requestId: 'director-${group.id}-$requestStamp-retry',
          );
          decision = result.decision;
          lastFreeText = result.freeText ?? lastFreeText;
        } catch (e) {
          lastError = _describeError(e);
          attemptErrors.add(lastError);
          debugPrint('[Director] retry failed: $e');
        }
      }

      if (decision == null && lastFreeText != null && lastFreeText.isNotEmpty) {
        decision = _tryParseFreeTextDecision(lastFreeText, assistantIds);
        if (decision != null) {
          debugPrint(
            '[Director] free-text fallback decision=${decision.kind} '
            'assistant=${decision.assistantId}',
          );
        }
      }

      decision ??= DirectorDecision.end(
        reason: lastError != null
            ? 'fallback_no_tool: $lastError'
            : (lastFreeText != null && lastFreeText.isNotEmpty
                  ? 'fallback_no_tool: free_text=${_clip(lastFreeText, 200)}'
                  : 'fallback_no_tool'),
        fallback: true,
      );
      debugPrint(
        '[Director] decision=${decision.kind} '
        'assistant=${decision.assistantId} fallback=${decision.fallback}',
      );
      emitRuntimeLog(failure: decision.fallback ? lastError : null);
      return decision;
    } catch (e) {
      if (!runtimeLogEmitted) {
        emitRuntimeLog(failure: _describeError(e));
      }
      rethrow;
    }
  }

  Future<({DirectorDecision? decision, String? freeText})> _callOnce({
    required dynamic config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required List<String> assistantIds,
    required String requestId,
  }) async {
    DirectorDecision? decided;
    final freeTextBuf = StringBuffer();
    final completer = Completer<DirectorDecision?>();
    StreamSubscription<ChatStreamChunk>? sub;

    Future<String> onToolCall(
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    }) async {
      if (decided != null) return jsonEncode({'ok': true});
      decided = _parseTool(name, args, assistantIds);
      if (decided != null && !completer.isCompleted) {
        completer.complete(decided);
        // The first valid tool call IS the decision. Cancel the stream right
        // away so the provider cannot keep generating follow-up tool rounds.
        // Keep the result neutral (never "ignored"): a model that reads
        // "ignored" interprets it as a rejected call and retries in a loop.
        unawaited(sub?.cancel());
        ChatApiService.cancelRequest(requestId);
      }
      return jsonEncode({'ok': true});
    }

    try {
      final stream = _sendMessageStream(
        config: config,
        modelId: modelId,
        messages: messages,
        tools: tools,
        onToolCall: onToolCall,
        temperature: temperature,
        maxTokens: maxTokens,
        stream: false,
        requestId: requestId,
        // DirectorRunner has its own retry loop; an additional auto-retry
        // would multiply attempts (own-loop x backoff) on free-tier limits.
        retryOverride: const AutoRetryOptions.defaults(),
      );

      sub = stream.listen(
        (chunk) {
          if (chunk.content.isNotEmpty) {
            freeTextBuf.write(chunk.content);
          }
          if (decided != null) return;
          final calls = chunk.toolCalls;
          if (calls == null || calls.isEmpty) return;
          for (final c in calls) {
            final args = Map<String, dynamic>.from(c.arguments);
            decided = _parseTool(c.name, args, assistantIds);
            if (decided != null) {
              if (!completer.isCompleted) completer.complete(decided);
              // Same immediate stop as onToolCall: no follow-up tool rounds.
              unawaited(sub?.cancel());
              ChatApiService.cancelRequest(requestId);
              break;
            }
          }
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(decided);
        },
        cancelOnError: true,
      );

      final decision = await completer.future.timeout(
        timeout,
        onTimeout: () {
          unawaited(sub?.cancel());
          ChatApiService.cancelRequest(requestId);
          debugPrint('[Director] timeout');
          throw TimeoutException('director timeout');
        },
      );
      final freeText = freeTextBuf.toString().trim();
      return (decision: decision, freeText: freeText.isEmpty ? null : freeText);
    } catch (e) {
      debugPrint('[Director] _callOnce error: $e');
      rethrow;
    }
  }

  DirectorDecision? _parseTool(
    String name,
    Map<String, dynamic> args,
    List<String> assistantIds,
  ) {
    final normalized = name.trim().toLowerCase().replaceAll('-', '_');
    if (normalized == DirectorTools.endTurn ||
        normalized.endsWith(DirectorTools.endTurn)) {
      return DirectorDecision.end(reason: args['reason']?.toString());
    }
    if (normalized == DirectorTools.selectSpeaker ||
        normalized.endsWith(DirectorTools.selectSpeaker)) {
      final id =
          args['assistant_id']?.toString() ??
          args['assistantId']?.toString() ??
          args['id']?.toString();
      if (id == null || !assistantIds.contains(id)) {
        debugPrint('[Director] invalid assistant_id=$id args=$args');
        return null;
      }
      return DirectorDecision.speak(id, reason: args['reason']?.toString());
    }
    return null;
  }

  DirectorDecision? _tryParseFreeTextDecision(
    String text,
    List<String> assistantIds,
  ) {
    final lower = text.toLowerCase();
    if (lower.contains('end_turn') ||
        lower.contains('no assistant') ||
        lower.contains('nobody') ||
        lower.contains('silence')) {
      return DirectorDecision.end(reason: 'free_text_end_turn', fallback: true);
    }
    for (final id in assistantIds) {
      if (text.contains(id)) {
        return DirectorDecision.speak(id, reason: 'free_text_id_match');
      }
    }
    return null;
  }

  static String _describeError(Object error) {
    // Dio errors can embed request URLs, headers, or response bodies that may
    // include private conversation content or API keys. Only stable, non-
    // sensitive fields are kept so runtime logs never leak request internals.
    if (error is DioException) {
      final status = error.response?.statusCode;
      return status == null
          ? error.type.name
          : '${error.type.name} (HTTP $status)';
    }
    if (error is TimeoutException) return 'timeout';
    return _clip(error.toString(), 300);
  }

  static String _clip(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  static String? _clipNullable(String? value, int max) {
    if (value == null || value.trim().isEmpty) return null;
    return _clip(value, max);
  }
}

enum DirectorSoftErrorKind { noModel, noTools }

class DirectorSoftError implements Exception {
  DirectorSoftError(this.kind);
  final DirectorSoftErrorKind kind;

  @override
  String toString() => 'DirectorSoftError($kind)';
}
