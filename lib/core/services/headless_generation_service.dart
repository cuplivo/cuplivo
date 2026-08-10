import 'dart:async';
import 'package:flutter/widgets.dart';

import '../../../features/home/controllers/stream_controller.dart'
    show ReasoningSegmentData, serializeReasoningSegmentsWithSplits;
import '../../../features/home/controllers/streaming_content_notifier.dart';
import '../providers/settings_provider.dart';
import 'api/chat_api_service.dart';
import 'chat/chat_service.dart';

enum SubagentJobStatus { running, done, error, cancelled }

/// What kind of activity [SubagentJob.lastStep] describes.
enum SubagentLastStepKind { call, done }

/// Stream provider hook (defaults to `ChatApiService.sendMessageStream`);
/// injectable for tests.
typedef HeadlessChatStreamProvider =
    Stream<ChatStreamChunk> Function({
      required ProviderConfig config,
      required String modelId,
      required List<Map<String, dynamic>> messages,
      List<Map<String, dynamic>>? tools,
      ToolCallHandler? onToolCall,
      int? thinkingBudget,
      double? temperature,
      double? topP,
      int? maxTokens,
      required bool stream,
      required String requestId,
    });

/// The outcome of a waited sub-generation.
class SubagentWaitResult {
  const SubagentWaitResult({
    this.text = '',
    this.cancelled = false,
    this.error,
  });

  /// The child's final output (empty when cancelled or errored).
  final String text;

  /// True when the job was cancelled by the user before completion.
  final bool cancelled;

  /// Non-null when the generation failed.
  final String? error;
}

/// Live per-job state for the 子代理面板 (subagent panel).
class SubagentJob {
  SubagentJob({
    required this.conversationId,
    required this.startedAt,
    this.parentConversationId,
    this.isWait = false,
    this.targetName,
  });

  final String conversationId;
  final DateTime startedAt;

  /// Conversation that spawned this sub-generation via a handoff (null for
  /// standalone headless generations).
  final String? parentConversationId;

  /// True when spawned by `kelivo_handoff_sync` — only wait-mode jobs are
  /// cascading-cancelled with their parent; fire-and-forget keeps v1 behavior.
  final bool isWait;

  /// Display name of the target assistant (panel header).
  final String? targetName;

  SubagentJobStatus status = SubagentJobStatus.running;

  /// Most recent tool activity: the tool name (call or result), or null
  /// while the child is purely streaming.
  String? lastStep;
  SubagentLastStepKind? lastStepKind;

  /// Cumulative streamed content length.
  int streamedChars = 0;

  /// Cumulative streamed content. Used to seed the page's live notifier on
  /// (re)subscription, because the broadcast chunk stream does not replay.
  final StringBuffer streamedText = StringBuffer();

  /// Count of tool calls made by the child so far (面板 expanded row).
  int toolCallCount = 0;

  /// The page's live-rendering notifier, registered while the child
  /// conversation is being viewed. `_run` updates it per chunk (content +
  /// reasoning); null when nobody is watching. Single state source — the
  /// page no longer keeps its own chunk buffer.
  StreamingContentNotifier? uiNotifier;

  /// The streaming assistant placeholder's message id, set once `addMessage`
  /// lands. The page uses it to key live `StreamingContentNotifier` updates.
  String? assistantMessageId;
}

class HeadlessGenerationService extends ChangeNotifier {
  HeadlessGenerationService({
    required ChatService chatService,
    HeadlessChatStreamProvider? chatStreamProvider,
  }) : this._(chatService, chatStreamProvider);

  HeadlessGenerationService._(
    this._chatService,
    HeadlessChatStreamProvider? chatStreamProvider,
  ) : _chatStreamProvider = chatStreamProvider ?? _defaultChatStreamProvider;

  final ChatService _chatService;
  final HeadlessChatStreamProvider _chatStreamProvider;

  static Stream<ChatStreamChunk> _defaultChatStreamProvider({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    required bool stream,
    required String requestId,
  }) {
    return ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      tools: tools,
      onToolCall: onToolCall,
      thinkingBudget: thinkingBudget,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      stream: stream,
      requestId: requestId,
    );
  }

  final _chunkControllers = <String, StreamController<ChatStreamChunk>>{};
  final _activeConversations = <String>{};
  final _jobs = <String, _SubagentJobRecord>{};

  bool isActive(String conversationId) =>
      _activeConversations.contains(conversationId);

  Stream<ChatStreamChunk>? chunkStream(String conversationId) =>
      _chunkControllers[conversationId]?.stream;

  /// Live job state for the panel, or null when nothing runs there.
  SubagentJob? jobFor(String conversationId) => _jobs[conversationId]?.job;

  /// Registers the job record SYNCHRONOUSLY, before the handoff engine
  /// returns its `started` JSON to the orchestrator.
  ///
  /// The response travels back through pure microtasks, while the actual
  /// generation (`_run`) suspends on real I/O (memory/worldbook/document
  /// processing) before it can register itself. Without pre-registration,
  /// `waitFor` (called right after the response arrives) would find no
  /// record and fail with `no active sub-generation`.
  void prepareJob({
    required String conversationId,
    String? parentConversationId,
    bool wait = false,
    String? targetName,
  }) {
    _jobs.putIfAbsent(
      conversationId,
      () => _SubagentJobRecord(
        job: SubagentJob(
          conversationId: conversationId,
          startedAt: DateTime.now(),
          parentConversationId: parentConversationId,
          isWait: wait,
          targetName: targetName,
        ),
      ),
    );
  }

  /// Wait-mode sub-jobs spawned by [parentConversationId] (子代理面板 feed).
  List<SubagentJob> waitJobsFor(String parentConversationId) => _jobs.values
      .where(
        (r) =>
            r.job.isWait && r.job.parentConversationId == parentConversationId,
      )
      .map((r) => r.job)
      .toList();

  /// Awaits the sub-generation for [conversationId] and returns its outcome.
  ///
  /// Always resolves — normal, error, and cancel paths all complete the
  /// future; the caller's await must never hang.
  Future<SubagentWaitResult> waitFor(String conversationId) {
    final record = _jobs[conversationId];
    if (record == null) {
      return Future.value(
        const SubagentWaitResult(error: 'no active sub-generation'),
      );
    }
    return record.completer.future;
  }

  void start({
    required String conversationId,
    required String assistantId,
    required List<Map<String, dynamic>> apiMessages,
    required ProviderConfig config,
    required String modelId,
    List<Map<String, dynamic>>? toolDefs,
    ToolCallHandler? onToolCall,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    bool stream = true,
    VoidCallback? onComplete,
    String? parentConversationId,
    bool wait = false,
    String? targetName,
  }) {
    unawaited(
      _run(
        conversationId: conversationId,
        assistantId: assistantId,
        apiMessages: apiMessages,
        config: config,
        modelId: modelId,
        toolDefs: toolDefs,
        onToolCall: onToolCall,
        thinkingBudget: thinkingBudget,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokens,
        stream: stream,
        onComplete: onComplete,
        parentConversationId: parentConversationId,
        wait: wait,
        targetName: targetName,
      ),
    );
  }

  Future<void> _run({
    required String conversationId,
    required String assistantId,
    required List<Map<String, dynamic>> apiMessages,
    required ProviderConfig config,
    required String modelId,
    List<Map<String, dynamic>>? toolDefs,
    ToolCallHandler? onToolCall,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    bool stream = true,
    VoidCallback? onComplete,
    String? parentConversationId,
    bool wait = false,
    String? targetName,
  }) async {
    final controller = StreamController<ChatStreamChunk>.broadcast();
    _chunkControllers[conversationId] = controller;
    _activeConversations.add(conversationId);
    // Reuse the record pre-registered by [prepareJob] (the orchestrator's
    // waitFor already holds its completer future); create on demand for
    // standalone callers.
    final record = _jobs.putIfAbsent(
      conversationId,
      () => _SubagentJobRecord(
        job: SubagentJob(
          conversationId: conversationId,
          startedAt: DateTime.now(),
          parentConversationId: parentConversationId,
          isWait: wait,
          targetName: targetName,
        ),
      ),
    );
    if (record.job.status == SubagentJobStatus.cancelled) {
      // The user cancelled during the engine-side window between
      // prepareJob and this run. The waiter is already resolved with
      // cancelled=true; abort without generating or persisting anything.
      // This return is outside the try/finally below, so clean up here.
      debugPrint(
        '[HeadlessGen] aborting cancelled job $conversationId before start',
      );
      _activeConversations.remove(conversationId);
      await controller.close();
      _chunkControllers.remove(conversationId);
      _jobs.remove(conversationId);
      notifyListeners();
      return;
    }
    notifyListeners();

    String? assistantMessageId;
    final buf = StringBuffer();
    try {
      final assistantMsg = await _chatService.addMessage(
        conversationId: conversationId,
        role: 'assistant',
        content: '',
        isStreaming: true,
      );
      assistantMessageId = assistantMsg.id;
      record.job.assistantMessageId = assistantMsg.id;
      // The page re-syncs its live chunk subscription once the placeholder
      // exists (see HomePageController._syncHeadlessChunks).
      notifyListeners();

      var chunkCount = 0;
      final reasoningBuf = StringBuffer();
      DateTime? reasoningStartAt;
      var hadThinkingBlock = false;
      final contentSplitOffsets = <int>[];
      final reasoningCountAtSplit = <int>[];
      final toolCountAtSplit = <int>[];
      final toolEventsById = <String, Map<String, dynamic>>{};
      await for (final chunk in _chatStreamProvider(
        config: config,
        modelId: modelId,
        messages: apiMessages,
        tools: toolDefs,
        onToolCall: onToolCall,
        thinkingBudget: thinkingBudget,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokens,
        stream: stream,
        requestId: conversationId,
      )) {
        chunkCount++;
        final mid = record.job.assistantMessageId;
        if (chunk.reasoning != null && chunk.reasoning!.isNotEmpty) {
          reasoningStartAt ??= DateTime.now();
          hadThinkingBlock = true;
          reasoningBuf.write(chunk.reasoning);
          if (mid != null) {
            record.job.uiNotifier?.updateReasoning(
              mid,
              reasoningText: reasoningBuf.toString(),
              reasoningStartAt: reasoningStartAt,
            );
          }
        }
        if (chunk.content.isNotEmpty) {
          // Thinking→content boundary (mirrors the page pipeline): record one
          // split so rendering interleaves thinking before this content slice.
          if (hadThinkingBlock && contentSplitOffsets.isEmpty) {
            contentSplitOffsets.add(0);
            reasoningCountAtSplit.add(1);
            toolCountAtSplit.add(toolEventsById.length);
            hadThinkingBlock = false;
          }
          buf.write(chunk.content);
          record.job.streamedChars += chunk.content.length;
          record.job.streamedText.write(chunk.content);
          if (mid != null) {
            record.job.uiNotifier?.updateContent(
              mid,
              buf.toString(),
              chunk.totalTokens,
            );
          }
        }
        if ((chunk.toolCalls ?? const []).isNotEmpty) {
          final first = chunk.toolCalls!.first;
          record.job.lastStep = first.name;
          record.job.lastStepKind = SubagentLastStepKind.call;
          record.job.toolCallCount += chunk.toolCalls!.length;
          for (final c in chunk.toolCalls!) {
            toolEventsById[c.id] = {
              'id': c.id,
              'name': c.name,
              'arguments': c.arguments,
              'content': null,
              if (c.metadata != null && c.metadata!.isNotEmpty)
                'metadata': c.metadata,
            };
          }
          if (mid != null) {
            await _chatService.setToolEvents(
              mid,
              toolEventsById.values.toList(),
            );
          }
        }
        if ((chunk.toolResults ?? const []).isNotEmpty) {
          final first = chunk.toolResults!.first;
          record.job.lastStep = first.name;
          record.job.lastStepKind = SubagentLastStepKind.done;
          for (final r in chunk.toolResults!) {
            toolEventsById[r.id] = {
              'id': r.id,
              'name': r.name,
              'arguments': r.arguments,
              'content': r.content,
              if (r.metadata != null && r.metadata!.isNotEmpty)
                'metadata': r.metadata,
            };
          }
          if (mid != null) {
            await _chatService.setToolEvents(
              mid,
              toolEventsById.values.toList(),
            );
          }
        }
        controller.add(chunk);
      }

      debugPrint(
        '[HeadlessGen] stream done for $conversationId: '
        'chunks=$chunkCount buf.length=${buf.length}',
      );

      final reasoningFinishedAt = reasoningStartAt != null
          ? DateTime.now()
          : null;
      final reasoningSegmentsJson =
          reasoningStartAt != null || contentSplitOffsets.isNotEmpty
          ? serializeReasoningSegmentsWithSplits(
              [
                ReasoningSegmentData()
                  ..text = reasoningBuf.toString()
                  ..startAt = reasoningStartAt
                  ..finishedAt = reasoningFinishedAt
                  ..expanded = false
                  ..toolStartIndex = 0,
              ],
              contentSplitOffsets: contentSplitOffsets,
              reasoningCountAtSplit: reasoningCountAtSplit,
              toolCountAtSplit: toolCountAtSplit,
            )
          : null;

      await _chatService.updateMessage(
        assistantMessageId,
        content: buf.toString(),
        isStreaming: false,
        reasoningText: reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
        reasoningStartAt: reasoningStartAt,
        reasoningFinishedAt: reasoningFinishedAt,
        reasoningSegmentsJson: reasoningSegmentsJson,
      );
      debugPrint(
        '[HeadlessGen] message updated: id=$assistantMessageId '
        'content.length=${buf.length} isStreaming=false',
      );
      record.job.status = SubagentJobStatus.done;
      if (!record.completer.isCompleted) {
        record.completer.complete(SubagentWaitResult(text: buf.toString()));
      }
      onComplete?.call();
    } catch (e) {
      debugPrint('[HeadlessGen] error in $conversationId: $e');
      if (assistantMessageId != null) {
        // Cancellation surfaces as a stream error: persist what streamed so
        // far instead of an Error banner (an early cancel with no content
        // persists an empty message, not a fake failure). Never
        // double-complete the waiter.
        final cancelled = record.job.status == SubagentJobStatus.cancelled;
        await _chatService.updateMessage(
          assistantMessageId,
          content: cancelled ? buf.toString() : 'Error: $e',
          isStreaming: false,
        );
      }
      if (!record.completer.isCompleted) {
        record.job.status = SubagentJobStatus.error;
        record.completer.complete(SubagentWaitResult(error: e.toString()));
      }
    } finally {
      _activeConversations.remove(conversationId);
      await controller.close();
      _chunkControllers.remove(conversationId);
      // The completer is resolved on every path by now (done/error/cancel/
      // abort); drop the record so a long-running session does not retain
      // every sub-generation's full output forever.
      _jobs.remove(conversationId);
      notifyListeners();
    }
  }

  /// Resolves the waiter with an error when the generation fails BEFORE
  /// `_run` registers its stream (e.g. the engine-side message building
  /// threw). Without this the orchestrator's `waitFor` would hang forever —
  /// the ADR's iron rule is that the completion future always resolves.
  void failJob(String conversationId, Object error) {
    final record = _jobs.remove(conversationId);
    if (record != null && !record.completer.isCompleted) {
      record.job.status = SubagentJobStatus.error;
      record.completer.complete(SubagentWaitResult(error: error.toString()));
      debugPrint('[HeadlessGen] failed job $conversationId: $error');
      notifyListeners();
    }
  }

  /// Cancels the sub-generation; the waiter resolves with
  /// [SubagentWaitResult.cancelled] = true.
  ///
  /// Cascading (recursive): when [conversationId] is itself a parent of
  /// wait-mode sub-jobs, those are cancelled too, transitively (a child
  /// waiting on its own wait-mode grandchild unwinds through its cancelled
  /// token once the grandchild's completer resolves). Fire-and-forget
  /// sub-jobs keep v1 behavior and run to completion.
  void cancel(String conversationId) {
    // Collect the whole wait chain reachable from the root (loop to fixpoint:
    // a new id may unlock further children).
    final toCancel = <String>{conversationId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final record in _jobs.values) {
        final parent = record.job.parentConversationId;
        if (record.job.isWait &&
            parent != null &&
            toCancel.contains(parent) &&
            toCancel.add(record.job.conversationId)) {
          changed = true;
        }
      }
    }
    for (final id in toCancel) {
      _cancelOne(id);
    }
  }

  void _cancelOne(String conversationId) {
    ChatApiService.cancelRequest(conversationId);
    final record = _jobs[conversationId];
    if (record != null && !record.completer.isCompleted) {
      record.job.status = SubagentJobStatus.cancelled;
      record.completer.complete(const SubagentWaitResult(cancelled: true));
    }
  }
}

class _SubagentJobRecord {
  _SubagentJobRecord({required this.job});

  final SubagentJob job;
  final Completer<SubagentWaitResult> completer =
      Completer<SubagentWaitResult>();
}
