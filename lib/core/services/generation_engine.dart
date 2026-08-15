import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../utils/assistant_regex.dart';
import '../../utils/markdown_media_sanitizer.dart';
import '../models/assistant.dart';
import '../models/assistant_regex.dart';
import '../models/reasoning_payload.dart';
import '../models/token_usage.dart';
import '../providers/download_progress_store.dart';
import '../providers/settings_provider.dart';
import 'api/chat_api_service.dart';
import 'chat/chat_service.dart';
import 'workspace/linux_sandbox_service.dart';
import 'streaming_content_notifier.dart';

/// Live status of one generation slot.
enum SlotStatus { running, done, error, cancelled }

/// What kind of activity [GenerationSlot.lastStep] describes.
enum SlotLastStepKind { call, done }

/// The outcome of a waited slot (wait-mode handoff).
class SlotWaitResult {
  const SlotWaitResult({this.text = '', this.cancelled = false, this.error});

  /// The slot's final output (empty when cancelled or errored).
  final String text;

  /// True when the slot was cancelled by the user before completion.
  final bool cancelled;

  /// Non-null when the generation failed.
  final String? error;
}

/// Stream provider hook (defaults to `ChatApiService.sendMessageStream`);
/// injectable for tests.
typedef EngineChatStreamProvider =
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
      required bool stream,
      String? requestId,
      required bool allowImagesApiRouting,
      required bool ocrActive,
      String Function(int received, int requested)? partialImageNotice,
    });

/// One generation target inside a [GenerationRound]: "stream into one
/// pre-created assistant placeholder message row". The caller creates the
/// placeholder (page: version/group/subgroup/speaker control; subagent
/// server: plain placeholder) and passes [assistantMessageId] — the engine
/// never creates message rows. See docs/adr/0028-generation-engine-unified-pipeline.md.
class GenerationSlotRequest {
  const GenerationSlotRequest({
    required this.assistantMessageId,
    required this.apiMessages,
    required this.config,
    required this.modelId,
    this.toolDefs,
    this.onToolCall,
    this.assistant,
    this.thinkingBudget,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.stream = true,
    this.userMediaPaths,
    this.allowImagesApiRouting = true,
    this.ocrActive = false,
    this.extraHeaders,
    this.extraBody,
    this.supportsReasoning = true,
    this.autoCollapseThinking = true,
    this.partialImageNotice,
    this.onContentUpdated,
    this.onStreamTick,
    this.onSlotError,
    this.onSlotComplete,
    this.onUiState,
  });

  final String assistantMessageId;
  final List<Map<String, dynamic>> apiMessages;
  final ProviderConfig config;
  final String modelId;
  final List<Map<String, dynamic>>? toolDefs;
  final ToolCallHandler? onToolCall;

  /// Full assistant object — required for the streaming assistant-regex
  /// transform (headless sub-generations previously skipped it).
  final Assistant? assistant;
  final int? thinkingBudget;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final bool stream;
  final List<String>? userMediaPaths;
  final bool allowImagesApiRouting;
  final bool ocrActive;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
  final bool supportsReasoning;
  final bool autoCollapseThinking;

  /// OpenAI image-generation partial-count notice (passed through to the
  /// provider for the image-mode fallback re-request loop).
  final String Function(int received, int requested)? partialImageNotice;

  /// Called on every paced content publication (the same slice the live
  /// notifier receives) — the page adapter uses it to sync its in-memory
  /// message list. Also called once with the final content at finish/error.
  final void Function(String messageId, String content, int totalTokens)?
  onContentUpdated;

  /// Called on every paced content publication (auto-scroll hook).
  final VoidCallback? onStreamTick;

  /// Called after the slot settled with an error (or a user cancellation that
  /// surfaced as a stream error). The page adapter shows the error surface;
  /// the persisted row already holds the partial/'Error' content.
  final void Function(Object error)? onSlotError;

  /// Called after the slot completed successfully (final content persisted;
  /// [GenerationSlot.finalText] holds it).
  final VoidCallback? onSlotComplete;

  /// Called on every pipeline state change (per chunk + once more at settle
  /// with the final values). The page adapters mirror this snapshot into
  /// their message-row UI maps (reasoning / segments / splits / tool parts) —
  /// the engine owns the state, the page renders it.
  final void Function(GenerationSlotUiState state)? onUiState;
}

/// One per-slot UI snapshot the engine publishes through
/// [GenerationSlotRequest.onUiState]. Immutable; adapters copy it into the
/// page's message-row state maps.
class GenerationSlotUiState {
  const GenerationSlotUiState({
    required this.reasoningText,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    required this.segments,
    required this.contentSplitOffsets,
    required this.reasoningCountAtSplit,
    required this.toolCountAtSplit,
    required this.toolEvents,
    this.geminiThoughtSig,
    required this.totalTokens,
    this.contextTokens,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.durationMs = 0,
    this.truncationReason,
  });

  final String reasoningText;
  final DateTime? reasoningStartAt;

  /// Set only on the settle snapshot (the elapsed thinking time is finalized
  /// when the slot settles).
  final DateTime? reasoningFinishedAt;

  final List<ReasoningSegmentData> segments;
  final List<int> contentSplitOffsets;
  final List<int> reasoningCountAtSplit;
  final List<int> toolCountAtSplit;

  /// Tool events in the persisted `dedupeToolEvents` shape
  /// (id/name/arguments/content/metadata).
  final List<Map<String, dynamic>> toolEvents;

  /// Gemini thought signature captured from the stream, if any.
  final String? geminiThoughtSig;

  /// Consumed totals (sum across request rounds).
  final int totalTokens;

  /// Context semantics: the last round's usage total.
  final int? contextTokens;
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;

  /// Final response duration; 0 on live snapshots.
  final int durationMs;

  /// `max_tokens` / `context_exceeded` when the response was truncated.
  final String? truncationReason;
}

/// Live per-slot state (子代理面板 binding + live rendering).
class GenerationSlot {
  GenerationSlot({
    required this.round,
    required this.assistantMessageId,
    required this.startedAt,
  });

  final GenerationRound round;

  /// The pre-created assistant placeholder row the engine streams into.
  String assistantMessageId;

  final DateTime startedAt;

  SlotStatus status = SlotStatus.running;

  /// Attached by [GenerationEngine.startRound]; null while a wait-mode slot
  /// is prepared but not yet started.
  GenerationSlotRequest? request;

  /// Most recent tool activity: the tool name (call or result), or null
  /// while the slot is purely streaming.
  String? lastStep;
  SlotLastStepKind? lastStepKind;

  /// Cumulative streamed content length.
  int streamedChars = 0;

  /// Cumulative streamed content. Used to seed the page's live notifier on
  /// (re)subscription, because the engine's live updates do not replay.
  final StringBuffer streamedText = StringBuffer();

  /// Count of tool calls made by the slot so far (面板 expanded row).
  int toolCallCount = 0;

  /// The page's live-rendering notifier, registered while the slot's
  /// conversation is being viewed. The engine updates it per chunk (content +
  /// reasoning) through its smooth-pacing ramp; null when nobody is watching.
  StreamingContentNotifier? uiNotifier;

  /// The outcome completer for wait-mode slots.
  final Completer<SlotWaitResult> completer = Completer<SlotWaitResult>();

  /// Set when the slot failed (used to settle the round waiter).
  String? errorText;

  /// The slot's final text (transformed, matching the persisted row), set on
  /// the done/fail paths. The round waiter (`waitFor`) is settled from this —
  /// the tool handler must receive the same text the child conversation
  /// shows, not the raw accumulated buffer.
  String? finalText;

  /// Final UI snapshot (settled state: finished reasoning timings, consumed
  /// usage, duration, truncation), set on the done/fail paths.
  GenerationSlotUiState? finalUiState;

  String get conversationId => round.conversationId;
  String? get parentConversationId => round.parentConversationId;
  bool get isWait => round.isWait;
  String? get targetName => round.targetName;
}

/// One engine execution unit: `startRound({conversationId, slots})`.
///
/// A Round is a transient in-memory token — never persisted; the message rows
/// carry the persisted identity (`groupId`/`version`/`subgroupId`). Single AI
/// = 1-slot Round; Multi-AI = N parallel slots in one Round; subagent = 1-slot
/// Round in the child conversation. See docs/adr/0028-generation-engine-unified-pipeline.md.
class GenerationRound {
  GenerationRound({
    required this.conversationId,
    this.parentConversationId,
    this.isWait = false,
    this.targetName,
  });

  final String conversationId;
  final String? parentConversationId;
  final bool isWait;
  final String? targetName;
  final DateTime startedAt = DateTime.now();

  final List<GenerationSlot> slots = <GenerationSlot>[];
  final Completer<SlotWaitResult> completer = Completer<SlotWaitResult>();

  bool _settled = false;

  bool get isDone => slots.every((s) => s.status != SlotStatus.running);

  /// Resolves the round waiter once every slot has settled. Never throws;
  /// the caller's await must always resolve (ADR-0026 iron rule).
  void maybeSettle() {
    if (_settled || !isDone) return;
    _settled = true;
    final failed = slots.where((s) => s.status == SlotStatus.error).toList();
    if (failed.isNotEmpty) {
      completer.complete(
        SlotWaitResult(error: failed.first.errorText ?? 'failed'),
      );
      return;
    }
    final cancelled = slots
        .where((s) => s.status == SlotStatus.cancelled)
        .toList();
    if (cancelled.isNotEmpty && cancelled.length == slots.length) {
      completer.complete(const SlotWaitResult(cancelled: true));
      return;
    }
    final text = slots
        .where((s) => s.status == SlotStatus.done)
        .map((s) {
          final t = s.finalText;
          if (t != null && t.isNotEmpty) return t;
          return s.streamedText.toString();
        })
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    completer.complete(SlotWaitResult(text: text));
  }
}

/// The single deep module for every tool-bearing conversational generation
/// path (normal chat, Multi-AI, group-chat member turns, subagent handoffs).
///
/// Contract: given pre-created assistant placeholder message rows, consume
/// the provider chunk stream, maintain full per-message state (multi-round
/// reasoning segments/splits, tool events, Gemini thought signatures, inline
/// image sanitization, assistant regex transform), persist throttled per
/// chunk (crash-safe), and render live state (per-slot
/// `StreamingContentNotifier` + smooth pacing). See
/// docs/adr/0028-generation-engine-unified-pipeline.md.
class GenerationEngine extends ChangeNotifier {
  GenerationEngine({
    required this._chatService,
    this._downloadProgressStore,
    EngineChatStreamProvider? streamProvider,
  }) : _streamProvider = streamProvider ?? _defaultStreamProvider;

  final ChatService _chatService;
  final DownloadProgressStore? _downloadProgressStore;
  final EngineChatStreamProvider _streamProvider;

  /// Active round per conversation (round identity = conversation in current
  /// practice: subagent 1-slot child rounds, sequential page rounds).
  final Map<String, GenerationRound> _rounds = <String, GenerationRound>{};

  /// Prepared-but-not-yet-started rounds (wait-mode): registered synchronously
  /// by the engine server before the async pipeline build, so `waitFor` never
  /// races it.
  final Map<String, GenerationRound> _prepared = <String, GenerationRound>{};

  /// Slot index: messageId → slot.
  final Map<String, GenerationSlot> _slots = <String, GenerationSlot>{};

  /// Per-slot pipeline runtime state (buffers, segments, timers, pacing).
  final Map<String, _SlotRuntime> _runtimes = <String, _SlotRuntime>{};

  static Stream<ChatStreamChunk> _defaultStreamProvider({
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
    bool stream = true,
    String? requestId,
    bool allowImagesApiRouting = true,
    bool ocrActive = false,
    String Function(int received, int requested)? partialImageNotice,
  }) {
    return ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      userMediaPaths: userMediaPaths,
      thinkingBudget: thinkingBudget,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      tools: tools,
      onToolCall: onToolCall,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      stream: stream,
      requestId: requestId,
      allowImagesApiRouting: allowImagesApiRouting,
      ocrActive: ocrActive,
      partialImageNotice: partialImageNotice,
    );
  }

  // ============================================================================
  // Public API
  // ============================================================================

  bool isActive(String conversationId) {
    final round = _rounds[conversationId];
    return round != null && !round.isDone;
  }

  /// True when a WAIT-mode (subagent) round is running in [conversationId].
  /// Page-path rounds (plain chat) are excluded — page adapters react to
  /// completion through their own callbacks, and only subagent rounds need
  /// the page's headless-transition handling.
  bool isWaitActive(String conversationId) {
    final round = _rounds[conversationId];
    return round != null && round.isWait && !round.isDone;
  }

  /// Live slot state for the panel, or null when nothing runs there.
  GenerationSlot? slotFor(String conversationId) {
    final round = _rounds[conversationId];
    if (round == null || round.slots.isEmpty) return null;
    return round.slots.last;
  }

  /// All slots of a conversation's active round (Multi-AI: N slots in one
  /// conversation — the page registers its notifier on every one).
  List<GenerationSlot> slotsFor(String conversationId) =>
      _rounds[conversationId]?.slots.toList() ?? const <GenerationSlot>[];

  /// The slot streaming into [messageId], or null.
  GenerationSlot? slotForMessage(String messageId) => _slots[messageId];

  /// Wait-mode slots spawned by [parentConversationId] (子代理面板 feed).
  /// Prepared-but-not-started rounds participate — the panel must bind from
  /// the dispatch moment, before the async pipeline build completes.
  List<GenerationSlot> waitSlotsFor(String parentConversationId) =>
      <GenerationRound>[..._rounds.values, ..._prepared.values]
          .where(
            (r) => r.isWait && r.parentConversationId == parentConversationId,
          )
          .map((r) => r.slots)
          .expand((s) => s)
          .toList();

  /// Awaits the generation of [conversationId] and returns its outcome.
  ///
  /// Always resolves — normal, error, and cancel paths all complete the
  /// future; the caller's await must never hang (ADR-0026 iron rule).
  Future<SlotWaitResult> waitFor(String conversationId) {
    final round = _rounds[conversationId] ?? _prepared[conversationId];
    if (round == null) {
      return Future.value(
        const SlotWaitResult(error: 'no active sub-generation'),
      );
    }
    return round.completer.future;
  }

  /// Registers the round AND its slot SYNCHRONOUSLY, before the engine server
  /// returns its `started` JSON to the orchestrator.
  ///
  /// The response travels back through pure microtasks, while the actual
  /// generation (`startRound`) suspends on real I/O (memory/worldbook/document
  /// processing) before it can register itself. Without pre-registration,
  /// `waitFor` (called right after the response arrives) would find no round
  /// and fail with `no active sub-generation`. The slot created here is what
  /// the 子代理面板 binds to from the dispatch moment; the placeholder row is
  /// created by the caller BEFORE this call.
  GenerationSlot prepareRound({
    required String conversationId,
    required String assistantMessageId,
    String? parentConversationId,
    bool wait = false,
    String? targetName,
  }) {
    final existing = _prepared[conversationId];
    if (existing != null) {
      // A round is already prepared for this conversation (defensive — each
      // handoff creates a fresh conversation today). Re-registering would
      // orphan the first round's waiter (ADR-0026 iron rule: waitFor must
      // always resolve), so keep the existing one. prepareRound always
      // creates its slot synchronously, so it is non-empty here.
      return existing.slots.first;
    }
    final round = GenerationRound(
      conversationId: conversationId,
      parentConversationId: parentConversationId,
      isWait: wait,
      targetName: targetName,
    );
    final slot = _createSlot(round, assistantMessageId);
    _prepared[conversationId] = round;
    return slot;
  }

  /// Starts a generation round with one or more slots. All records are
  /// registered synchronously; each slot streams into its pre-created
  /// placeholder.
  ///
  /// Reuses a prepared round (wait-mode: the engine server registered it
  /// before the async pipeline build) or a still-present round whose slot was
  /// cancelled before start (the late start aborts on the cancelled status).
  /// Slots are matched by `assistantMessageId` — a request whose slot already
  /// exists (prepared) attaches to it instead of creating a duplicate.
  GenerationRound startRound({
    required String conversationId,
    required List<GenerationSlotRequest> slots,
    String? parentConversationId,
    bool wait = false,
    String? targetName,
  }) {
    final round =
        _prepared.remove(conversationId) ??
        _rounds[conversationId] ??
        GenerationRound(
          conversationId: conversationId,
          parentConversationId: parentConversationId,
          isWait: wait,
          targetName: targetName,
        );
    _rounds[conversationId] = round;

    final runnable = <GenerationSlot>[];
    for (final req in slots) {
      GenerationSlot? slot;
      for (final s in round.slots) {
        if (s.assistantMessageId == req.assistantMessageId) {
          slot = s;
          break;
        }
      }
      slot ??= _createSlot(round, req.assistantMessageId);
      slot.request = req;
      runnable.add(slot);
    }
    try {
      notifyListeners();
    } catch (e) {
      // A listener exception must not abort registration: every slot below
      // still runs and settles, keeping the waitFor iron rule intact.
      debugPrint('[GenerationEngine] startRound listener error: $e');
    }
    for (final slot in runnable) {
      unawaited(_runSlot(round, slot));
    }
    return round;
  }

  GenerationSlot _createSlot(GenerationRound round, String assistantMessageId) {
    final slot = GenerationSlot(
      round: round,
      assistantMessageId: assistantMessageId,
      startedAt: round.startedAt,
    );
    round.slots.add(slot);
    _slots[assistantMessageId] = slot;
    return slot;
  }

  /// Resolves the round waiter with an error when the generation fails
  /// BEFORE `startRound` registers its stream (e.g. the engine-side message
  /// building threw). Without this the orchestrator's `waitFor` would hang
  /// forever — the ADR's iron rule is that the completion future always
  /// resolves.
  void failRound(String conversationId, Object error) {
    final round = _prepared.remove(conversationId);
    if (round == null) {
      debugPrint(
        '[GenerationEngine] failRound for unknown round '
        '$conversationId: $error',
      );
      return;
    }
    for (final slot in round.slots) {
      if (!slot.completer.isCompleted) {
        slot.status = SlotStatus.error;
        slot.errorText = error.toString();
        slot.completer.complete(SlotWaitResult(error: error.toString()));
      }
      _slots.remove(slot.assistantMessageId);
    }
    round.maybeSettle();
    _rounds.remove(round.conversationId);
    debugPrint('[GenerationEngine] failed round $conversationId: $error');
    notifyListeners();
  }

  /// Cancels the generation of [conversationId]; its waiter resolves with
  /// [SlotWaitResult.cancelled] = true.
  ///
  /// Cascading (recursive): when [conversationId] is itself a parent of
  /// wait-mode slots, those are cancelled too, transitively (a child waiting
  /// on its own wait-mode grandchild unwinds through its cancelled token once
  /// the grandchild's completer resolves). Fire-and-forget slots keep v1
  /// behavior and run to completion.
  void cancelConversation(String conversationId) {
    // Collect the whole wait chain reachable from the root (loop to fixpoint:
    // a new id may unlock further children). Prepared-but-not-started rounds
    // (wait-mode) participate too — the cascade must reach a child whose
    // generation is still building its pipeline.
    final allRounds = <GenerationRound>[..._rounds.values, ..._prepared.values];
    final toCancel = <String>{conversationId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final round in allRounds) {
        final parent = round.parentConversationId;
        if (round.isWait &&
            parent != null &&
            toCancel.contains(parent) &&
            toCancel.add(round.conversationId)) {
          changed = true;
        }
      }
    }
    for (final id in toCancel) {
      final rounds = <GenerationRound>[
        if (_rounds[id] != null) _rounds[id]!,
        if (_prepared[id] != null) _prepared[id]!,
      ];
      for (final round in rounds) {
        for (final slot in round.slots) {
          cancelSlot(slot.assistantMessageId);
        }
      }
      // Abort any in-flight workspace download the stopped conversation was
      // running (its raw HttpClient is independent of the Dio CancelToken —
      // ADR-0030).
      _downloadProgressStore?.cancelForConversation(id);
      unawaited(LinuxSandboxService.instance.cancelForConversation(id));
    }
  }

  /// Cancels one slot (Multi-AI thread drop granularity). The slot's round
  /// waiter settles here; the round record itself survives until the stream
  /// unwinds or a late start aborts on the cancelled status.
  void cancelSlot(String messageId) {
    ChatApiService.cancelRequest(messageId);
    final slot = _slots[messageId];
    if (slot == null) return;
    if (!slot.completer.isCompleted) {
      slot.status = SlotStatus.cancelled;
      slot.completer.complete(const SlotWaitResult(cancelled: true));
    }
    slot.round.maybeSettle();
  }

  @override
  void dispose() {
    for (final mid in _slots.keys.toList()) {
      ChatApiService.cancelRequest(mid);
    }
    unawaited(LinuxSandboxService.instance.cancelAll());
    super.dispose();
  }

  // ============================================================================
  // Slot run
  // ============================================================================

  Future<void> _runSlot(GenerationRound round, GenerationSlot slot) async {
    final req = slot.request;
    if (req == null) {
      debugPrint(
        '[GenerationEngine] slot ${slot.assistantMessageId} started '
        'without a request',
      );
      await _cleanupSlot(slot, round);
      return;
    }
    if (slot.status == SlotStatus.cancelled) {
      // The user cancelled during the engine-side window between prepareRound
      // and this run. The waiter is already resolved with cancelled=true;
      // abort without generating — the placeholder was created by the caller,
      // so remove the empty row to preserve "no fake placeholder" semantics.
      debugPrint(
        '[GenerationEngine] aborting cancelled slot ${slot.assistantMessageId} '
        'before start',
      );
      try {
        await _chatService.deleteMessage(slot.assistantMessageId);
      } catch (e) {
        debugPrint('[GenerationEngine] abort cleanup failed: $e');
      }
      await _cleanupSlot(slot, round);
      return;
    }

    final runtime = _SlotRuntime(slot: slot, request: req);
    _runtimes[slot.assistantMessageId] = runtime;
    notifyListeners();

    try {
      await for (final chunk in _streamProvider(
        config: req.config,
        modelId: req.modelId,
        messages: req.apiMessages,
        userMediaPaths: req.userMediaPaths,
        thinkingBudget: req.thinkingBudget,
        temperature: req.temperature,
        topP: req.topP,
        maxTokens: req.maxTokens,
        tools: req.toolDefs,
        onToolCall: req.onToolCall,
        extraHeaders: req.extraHeaders,
        extraBody: req.extraBody,
        stream: req.stream,
        requestId: slot.assistantMessageId,
        allowImagesApiRouting: req.allowImagesApiRouting,
        ocrActive: req.ocrActive,
        partialImageNotice: req.partialImageNotice,
      )) {
        var chunkContent = chunk.content;
        if (chunkContent.isNotEmpty) {
          chunkContent = _captureGeminiThoughtSignature(chunkContent, runtime);
        }
        if (chunk.reasoningDetails != null) {
          runtime.reasoningDetails = chunk.reasoningDetails;
        }
        if (chunk.truncationReason != null) {
          runtime.truncationReason = chunk.truncationReason;
        }
        if ((chunk.reasoning ?? '').isNotEmpty && req.supportsReasoning) {
          _handleReasoningChunk(runtime, chunk.reasoning!);
        }
        if ((chunk.toolCalls ?? const []).isNotEmpty) {
          _handleToolCallsChunk(runtime, chunk.toolCalls!);
        }
        if ((chunk.toolResults ?? const []).isNotEmpty) {
          _handleToolResultsChunk(runtime, chunk.toolResults!);
        }
        if (chunk.totalTokens > 0) {
          runtime.totalTokens = chunk.totalTokens;
        }
        // Last-wins (replace): providers emit the CURRENT round's cumulative
        // usage, so the latest chunk is the exact context at this moment.
        if (chunk.usage != null) {
          runtime.usage = chunk.usage;
          runtime.totalTokens = chunk.usage!.totalTokens;
        }
        if (chunk.consumedUsage != null) {
          runtime.consumedUsage = chunk.consumedUsage;
        }
        if (chunkContent.isNotEmpty) {
          await _handleContentChunk(runtime, chunkContent);
        }
        // Mirror the current pipeline state into the page UI maps (per chunk;
        // idempotent — the adapters re-assign the same values).
        req.onUiState?.call(runtime.buildUiState());
      }

      await _finishSlot(runtime, round);
    } catch (e) {
      debugPrint('[GenerationEngine] error in ${slot.assistantMessageId}: $e');
      await _failSlot(runtime, round, e);
    } finally {
      await _cleanupSlot(slot, round);
    }
  }

  // ============================================================================
  // Chunk handlers (mirror the page pipeline semantics)
  // ============================================================================

  void _handleReasoningChunk(_SlotRuntime rt, String reasoning) {
    rt.hadThinkingBlock = true;
    rt.reasoningStartAt ??= DateTime.now();
    rt.reasoningBuf.write(reasoning);

    final initialExpanded = !rt.request.autoCollapseThinking;
    // A new segment starts when reasoning resumes AFTER tools (multi-round
    // chain-of-thought: think → tool → think). Mirrors
    // stream_controller.handleReasoningChunk.
    final hasToolsAfterLastSegment =
        rt.segments.isNotEmpty && rt.toolEventsById.isNotEmpty;
    final last = rt.segments.isNotEmpty ? rt.segments.last : null;
    if (last == null) {
      rt.segments.add(
        ReasoningSegmentData()
          ..text = reasoning
          ..startAt = DateTime.now()
          ..expanded = initialExpanded
          ..toolStartIndex = rt.toolEventsById.length,
      );
    } else if (hasToolsAfterLastSegment && last.finishedAt != null) {
      rt.segments.add(
        ReasoningSegmentData()
          ..text = reasoning
          ..startAt = DateTime.now()
          ..expanded = initialExpanded
          ..toolStartIndex = rt.toolEventsById.length,
      );
    } else {
      last.text += reasoning;
      last.startAt ??= DateTime.now();
    }

    // Persist on a 500 ms cadence (issue #232 pattern: full-text reasoning
    // writes are O(n), per-chunk writes would be O(n²)).
    _scheduleReasoningFlush(rt);
    _scheduleLiveReasoning(rt);
  }

  void _handleToolCallsChunk(_SlotRuntime rt, List<ToolCallInfo> calls) {
    rt.hadThinkingBlock = true;
    // Finish any unfinished reasoning segment when tools start.
    _finishOpenSegment(rt);

    final first = calls.first;
    rt.slot.lastStep = first.name;
    rt.slot.lastStepKind = SlotLastStepKind.call;
    rt.slot.toolCallCount += calls.length;
    for (final c in calls) {
      rt.toolEventsById[_toolEventKey(rt, c.id, c.name)] = {
        'id': c.id,
        'name': c.name,
        'arguments': c.arguments,
        'content': null,
        if (c.metadata != null && c.metadata!.isNotEmpty)
          'metadata': c.metadata,
      };
    }
    unawaited(_persistToolEvents(rt));
    _publishLiveToolParts(rt);
  }

  void _handleToolResultsChunk(_SlotRuntime rt, List<ToolResultInfo> results) {
    final first = results.first;
    rt.slot.lastStep = first.name;
    rt.slot.lastStepKind = SlotLastStepKind.done;
    for (final r in results) {
      rt.toolEventsById[_toolEventKey(
        rt,
        r.id,
        r.name,
        matchPlaceholder: true,
      )] = {
        'id': r.id,
        'name': r.name,
        'arguments': r.arguments,
        'content': r.content,
        if (r.metadata != null && r.metadata!.isNotEmpty)
          'metadata': r.metadata,
      };
    }
    unawaited(_persistToolEvents(rt));
    _publishLiveToolParts(rt);
  }

  /// Map key for one tool event. Providers normally echo a `tool_call_id`;
  /// when the id is empty, keep per-name slots so several no-id results with
  /// different content survive (the `dedupeToolEvents` contract), and let a
  /// no-id result complete the OLDEST still-loading placeholder of the same
  /// name (mirrors the pre-engine page pipeline's name-based matching).
  String _toolEventKey(
    _SlotRuntime rt,
    String id,
    String name, {
    bool matchPlaceholder = false,
  }) {
    final trimmed = id.trim();
    if (trimmed.isNotEmpty) return trimmed;
    if (matchPlaceholder) {
      final candidates = rt.toolEventsById.entries
          .where(
            (e) => e.key.startsWith('$name#') && e.value['content'] == null,
          )
          .toList();
      if (candidates.isNotEmpty) return candidates.first.key;
    }
    final counter = (rt.noIdToolCounts[name] ?? 0) + 1;
    rt.noIdToolCounts[name] = counter;
    return '$name#$counter';
  }

  void _finishOpenSegment(_SlotRuntime rt) {
    if (rt.segments.isNotEmpty && rt.segments.last.finishedAt == null) {
      rt.segments.last.finishedAt = DateTime.now();
      if (rt.request.autoCollapseThinking) {
        rt.segments.last.expanded = false;
      }
    }
  }

  Future<void> _persistToolEvents(_SlotRuntime rt) async {
    await _chatService.setToolEvents(
      rt.slot.assistantMessageId,
      dedupeToolEvents(rt.toolEventsById.values.toList()),
    );
  }

  Future<void> _handleContentChunk(_SlotRuntime rt, String chunkContent) async {
    // Thinking→content boundary: record one split per episode (multi-round:
    // every thinking/tool → content transition, not just the first).
    if (rt.hadThinkingBlock) {
      rt.contentSplitOffsets.add(rt.buf.length);
      rt.reasoningCountAtSplit.add(rt.segments.length);
      rt.toolCountAtSplit.add(rt.toolEventsById.length);
      rt.hadThinkingBlock = false;
      // Finish the open reasoning segment when content starts (mirrors
      // finishReasoningOnContent).
      _finishOpenSegment(rt);
    }

    rt.buf.write(chunkContent);
    rt.slot.streamedChars += chunkContent.length;
    rt.slot.streamedText.write(chunkContent);

    var processed = _transformContent(rt, rt.buf.toString());
    if (processed.contains('data:image') && processed.contains('base64,')) {
      processed = await _sanitizeInlineImages(rt, processed);
    }

    rt.currentContent = processed;
    await _chatService.updateMessageSilent(
      rt.slot.assistantMessageId,
      content: processed,
      totalTokens: rt.totalTokens,
    );
    _publishLiveContent(rt);
    _scheduleInlineImageSanitize(rt, processed);
  }

  /// Transform raw accumulated content using assistant regexes (persist
  /// target — mirrors chat_actions._transformAssistantContent).
  String _transformContent(_SlotRuntime rt, String raw) {
    return applyAssistantRegexes(
      raw,
      assistant: rt.request.assistant,
      scope: AssistantRegexScope.assistant,
      target: AssistantRegexTransformTarget.persist,
    );
  }

  static final RegExp _geminiThoughtSigRe = RegExp(
    r'<!--\s*gemini_thought_signatures:.*?-->',
    dotAll: true,
  );

  /// Capture and strip a Gemini thought signature from content; persists it
  /// so follow-up API calls in the conversation can echo it.
  String _captureGeminiThoughtSignature(String content, _SlotRuntime rt) {
    final m = _geminiThoughtSigRe.firstMatch(content);
    if (m != null) {
      final sig = m.group(0) ?? '';
      if (sig.isNotEmpty) {
        rt.geminiThoughtSig = sig;
        unawaited(
          _chatService.setGeminiThoughtSignature(
            rt.slot.assistantMessageId,
            sig,
          ),
        );
        content = content.replaceAll(_geminiThoughtSigRe, '').trimRight();
      }
    }
    return content;
  }

  /// Immediate inline base64 image sanitization (mirrors the page's
  /// `_handleContentChunk` path): replaces the accumulated content when a
  /// sanitization result lands, so later transforms operate on the sanitized
  /// base.
  Future<String> _sanitizeInlineImages(_SlotRuntime rt, String content) async {
    try {
      final sanitized = await MarkdownMediaSanitizer.replaceInlineBase64Images(
        content,
      );
      if (sanitized != content) {
        rt.buf.clear();
        rt.buf.write(sanitized);
        return sanitized;
      }
    } catch (_) {
      // Swallow sanitization errors — the unsanitized content stays.
    }
    return content;
  }

  void _scheduleInlineImageSanitize(_SlotRuntime rt, String content) {
    if (!content.contains('data:image') || !content.contains('base64,')) {
      rt.imageSanitizeTimer?.cancel();
      rt.imageSanitizeTimer = null;
      return;
    }
    rt.imageSanitizeTimer?.cancel();
    rt.imageSanitizeTimer = Timer(_inlineImageSanitizeDelay, () async {
      if (rt.imageSanitizing) return;
      rt.imageSanitizing = true;
      try {
        final sanitized =
            await MarkdownMediaSanitizer.replaceInlineBase64Images(content);
        if (sanitized == content) return;
        rt.buf.clear();
        rt.buf.write(sanitized);
        rt.currentContent = sanitized;
        await _chatService.updateMessageSilent(
          rt.slot.assistantMessageId,
          content: sanitized,
          totalTokens: rt.totalTokens,
        );
        _publishLiveContent(rt);
      } catch (_) {
        // Swallow errors to avoid crashing streaming.
      } finally {
        rt.imageSanitizing = false;
        rt.imageSanitizeTimer = null;
      }
    });
  }

  // ============================================================================
  // Reasoning persistence (500 ms cadence) + live rendering
  // ============================================================================

  static const Duration _reasoningFlushInterval = Duration(milliseconds: 500);

  /// Reasoning live-render cadence (issue #232): the thinking card re-parses
  /// the whole accumulated markdown on every update; ~6-7 fps is plenty for a
  /// thinking preview. The engine coalesces notifier updates to this cadence
  /// (mirrors the pre-engine page `_reasoningUiThrottle`).
  static const Duration _reasoningUiInterval = Duration(milliseconds: 150);

  void _scheduleReasoningFlush(_SlotRuntime rt) {
    rt.reasoningFlushDirty = true;
    rt.reasoningFlushTimer ??= Timer(_reasoningFlushInterval, () {
      rt.reasoningFlushTimer = null;
      if (!rt.reasoningFlushDirty) return;
      rt.reasoningFlushDirty = false;
      unawaited(
        _chatService
            .updateMessageSilent(
              rt.slot.assistantMessageId,
              reasoningText: rt.reasoningBuf.isEmpty
                  ? null
                  : rt.reasoningBuf.toString(),
              reasoningStartAt: rt.reasoningStartAt,
              reasoningSegmentsJson: _serializePayload(rt),
            )
            .catchError((Object e) {
              debugPrint(
                '[GenerationEngine] reasoning flush failed for '
                '${rt.slot.assistantMessageId}: $e',
              );
            }),
      );
    });
  }

  String? _serializePayload(_SlotRuntime rt) {
    if (rt.reasoningBuf.isEmpty &&
        rt.segments.isEmpty &&
        rt.contentSplitOffsets.isEmpty) {
      return null;
    }
    try {
      return serializeReasoningSegmentsWithSplits(
        rt.segments,
        contentSplitOffsets: rt.contentSplitOffsets,
        reasoningCountAtSplit: rt.reasoningCountAtSplit,
        toolCountAtSplit: rt.toolCountAtSplit,
        reasoningDetails: rt.reasoningDetails,
      );
    } catch (e) {
      // Provider-supplied reasoningDetails can be non-serializable; the
      // reasoningText column is independent, so the payload degrades
      // gracefully (recoverable-error convention).
      debugPrint(
        '[GenerationEngine] reasoning payload serialization failed for '
        '${rt.slot.assistantMessageId}: $e',
      );
      return null;
    }
  }

  void _publishLiveReasoning(_SlotRuntime rt) {
    final notifier = rt.slot.uiNotifier;
    if (notifier == null) return;
    final mid = rt.slot.assistantMessageId;
    final text = rt.reasoningBuf.toString();
    // Dedupe by value: the settle path publishes content AND reasoning, and
    // every notifier write re-notifies all listeners — an unchanged reasoning
    // snapshot would double-fire the content listeners with the same frame.
    final current = notifier.getNotifier(mid).value;
    if ((current.reasoningText ?? '') == text &&
        current.reasoningStartAt == rt.reasoningStartAt) {
      return;
    }
    notifier.updateReasoning(
      mid,
      reasoningText: text,
      reasoningStartAt: rt.reasoningStartAt,
      contentSplitOffsets: rt.contentSplitOffsets,
      reasoningCountAtSplit: rt.reasoningCountAtSplit,
      toolCountAtSplit: rt.toolCountAtSplit,
    );
  }

  /// Coalesces thinking-card rebuilds to [_reasoningUiInterval] (issue #232).
  void _scheduleLiveReasoning(_SlotRuntime rt) {
    rt.reasoningUiDirty = true;
    rt.reasoningUiTimer ??= Timer(_reasoningUiInterval, () {
      rt.reasoningUiTimer = null;
      if (!rt.reasoningUiDirty) return;
      rt.reasoningUiDirty = false;
      _publishLiveReasoning(rt);
    });
  }

  /// Flushes the pending reasoning UI update immediately (settle path — the
  /// final thinking state must reach the live card before it is removed).
  void _flushLiveReasoning(_SlotRuntime rt) {
    rt.reasoningUiTimer?.cancel();
    rt.reasoningUiTimer = null;
    rt.reasoningUiDirty = false;
    _publishLiveReasoning(rt);
  }

  void _publishLiveToolParts(_SlotRuntime rt) {
    final notifier = rt.slot.uiNotifier;
    if (notifier == null) return;
    notifier.notifyToolPartsUpdated(
      rt.slot.assistantMessageId,
      contentSplitOffsets: rt.contentSplitOffsets,
      reasoningCountAtSplit: rt.reasoningCountAtSplit,
      toolCountAtSplit: rt.toolCountAtSplit,
    );
  }

  // ============================================================================
  // Smooth pacing ramp (engine-owned, mirrors the page _StreamSmoothState)
  // ============================================================================

  static const Duration _rampInterval = Duration(milliseconds: 50);
  static const int _rampSmoothMinCount = 2;
  static const int _rampSmoothBaseCount = 40;
  static const int _rampSmoothMaxCount = 240;
  static const double _rampSmoothPickRate = 0.1;
  static const int _rampSmoothMoveAverageLength = 10;

  static const Duration _inlineImageSanitizeDelay = Duration(milliseconds: 120);
  void _publishLiveContent(_SlotRuntime rt) {
    rt.pacing.targetContent = rt.currentContent;
    if (rt.rampTimer != null) return;
    rt.rampTimer = Timer.periodic(_rampInterval, (_) {
      final notifier = rt.slot.uiNotifier;
      if (notifier == null) {
        rt.pacing.wasAttached = false;
        return;
      }
      // Attach-event sync: whenever the page (re)attaches its notifier
      // (null → non-null), it seeds the notifier with the FULL accumulated
      // text (or nothing when it attached before any content). Sync the
      // pacing state to what the notifier currently shows so this tick paces
      // only the delta — otherwise it would overwrite the seeded full text
      // with a small prefix (visible shrink-and-retype glitch), or, on a
      // clean attach before content, skip the first slice entirely.
      if (!rt.pacing.wasAttached) {
        rt.pacing.visibleContent = notifier
            .getNotifier(rt.slot.assistantMessageId)
            .value
            .content;
      }
      rt.pacing.wasAttached = true;
      final next = rt.pacing.takeNextContentSlice(
        minCount: _rampSmoothMinCount,
        baseCount: _rampSmoothBaseCount,
        maxCount: _rampSmoothMaxCount,
        pickRate: _rampSmoothPickRate,
        moveAverageLength: _rampSmoothMoveAverageLength,
      );
      if (next == null) return;
      notifier.updateContent(
        rt.slot.assistantMessageId,
        next,
        rt.totalTokens,
        contentSplitOffsets: rt.contentSplitOffsets,
        reasoningCountAtSplit: rt.reasoningCountAtSplit,
        toolCountAtSplit: rt.toolCountAtSplit,
      );
      rt.request.onContentUpdated?.call(
        rt.slot.assistantMessageId,
        next,
        rt.totalTokens,
      );
      rt.request.onStreamTick?.call();
    });
  }

  /// Publishes the FINAL content to the live notifier + the page's list
  /// callback (jump, not paced) — mirrors the page pipeline's finish-path
  /// notifier flush so the UI never shows a stale last slice.
  void _flushLiveContent(_SlotRuntime rt) {
    rt.pacing.targetContent = rt.currentContent;
    rt.pacing.visibleContent = rt.currentContent;
    final notifier = rt.slot.uiNotifier;
    if (notifier != null) {
      notifier.updateContent(
        rt.slot.assistantMessageId,
        rt.currentContent,
        rt.totalTokens,
        contentSplitOffsets: rt.contentSplitOffsets,
        reasoningCountAtSplit: rt.reasoningCountAtSplit,
        toolCountAtSplit: rt.toolCountAtSplit,
      );
    }
    rt.request.onContentUpdated?.call(
      rt.slot.assistantMessageId,
      rt.currentContent,
      rt.totalTokens,
    );
    rt.request.onStreamTick?.call();
  }

  // ============================================================================
  // Finish / fail / cleanup
  // ============================================================================

  Future<void> _finishSlot(_SlotRuntime rt, GenerationRound round) async {
    final slot = rt.slot;
    final reasoningFinishedAt = rt.reasoningStartAt != null
        ? DateTime.now()
        : null;
    _finishOpenSegment(rt);

    final payload = _serializePayload(rt);
    debugPrint(
      '[GenerationEngine] stream done for ${slot.assistantMessageId}: '
      'buf.length=${rt.buf.length}',
    );

    await _chatService.updateMessage(
      slot.assistantMessageId,
      content: rt.currentContent,
      isStreaming: false,
      totalTokens: rt.consumedUsage?.totalTokens ?? rt.totalTokens,
      contextTokens: rt.usage?.totalTokens ?? rt.totalTokens,
      promptTokens: rt.consumedUsage?.promptTokens,
      completionTokens: rt.consumedUsage?.completionTokens,
      cachedTokens: rt.consumedUsage?.cachedTokens,
      reasoningText: rt.reasoningBuf.isEmpty
          ? null
          : rt.reasoningBuf.toString(),
      reasoningStartAt: rt.reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      reasoningSegmentsJson: payload,
      durationMs: DateTime.now().difference(slot.startedAt).inMilliseconds,
    );
    debugPrint(
      '[GenerationEngine] message updated: id=${slot.assistantMessageId} '
      'content.length=${rt.buf.length} isStreaming=false',
    );
    slot.status = SlotStatus.done;
    // finalText is what the round waiter (waitFor) returns — the transformed
    // content the child conversation shows, consistent with the persisted row.
    slot.finalText = rt.currentContent.isNotEmpty
        ? rt.currentContent
        : rt.buf.toString();
    if (!slot.completer.isCompleted) {
      slot.completer.complete(SlotWaitResult(text: slot.finalText!));
    }
    _flushLiveContent(rt);
    _flushLiveReasoning(rt);
    final state = rt.buildUiState(
      reasoningFinishedAt: reasoningFinishedAt,
      durationMs: DateTime.now().difference(slot.startedAt).inMilliseconds,
    );
    slot.finalUiState = state;
    rt.request.onUiState?.call(state);
    rt.request.onSlotComplete?.call();
    round.maybeSettle();
  }

  Future<void> _failSlot(
    _SlotRuntime rt,
    GenerationRound round,
    Object error,
  ) async {
    final slot = rt.slot;
    // Cancellation surfaces as a stream error: persist what streamed so far
    // instead of an Error banner. Genuine errors keep the partial content and
    // fall back to the raw error text only when nothing streamed (page
    // policy — matches the pre-engine chat_actions/group executor behavior).
    // The persisted content is the TRANSFORMED content (what the child
    // conversation showed live) — consistent with the per-chunk path.
    final cancelled = slot.status == SlotStatus.cancelled;
    final content = cancelled
        ? (rt.currentContent.isNotEmpty ? rt.currentContent : rt.buf.toString())
        : (rt.currentContent.isNotEmpty ? rt.currentContent : error.toString());
    _finishOpenSegment(rt);
    await _chatService.updateMessage(
      slot.assistantMessageId,
      content: content,
      isStreaming: false,
      reasoningText: rt.reasoningBuf.isEmpty
          ? null
          : rt.reasoningBuf.toString(),
      reasoningStartAt: rt.reasoningStartAt,
      reasoningFinishedAt: rt.reasoningStartAt != null ? DateTime.now() : null,
      reasoningSegmentsJson: _serializePayload(rt),
    );
    // The round waiter (waitFor) settles from finalText — same content as
    // the persisted row, so the orchestrator reads what the child shows.
    slot.finalText = content;
    _flushLiveContent(rt);
    _flushLiveReasoning(rt);
    final state = rt.buildUiState(
      reasoningFinishedAt: rt.reasoningStartAt != null ? DateTime.now() : null,
      durationMs: DateTime.now().difference(slot.startedAt).inMilliseconds,
    );
    slot.finalUiState = state;
    rt.request.onUiState?.call(state);
    if (!slot.completer.isCompleted) {
      slot.status = SlotStatus.error;
      slot.errorText = error.toString();
      slot.completer.complete(SlotWaitResult(error: error.toString()));
    }
    rt.request.onSlotError?.call(error);
    round.maybeSettle();
  }

  Future<void> _cleanupSlot(GenerationSlot slot, GenerationRound round) async {
    final rt = _runtimes.remove(slot.assistantMessageId);
    rt?.rampTimer?.cancel();
    rt?.reasoningFlushTimer?.cancel();
    rt?.reasoningUiTimer?.cancel();
    rt?.imageSanitizeTimer?.cancel();
    _slots.remove(slot.assistantMessageId);
    round.maybeSettle();
    if (!round.isDone) return;
    // Drop the round + any remaining slot records (cancelled-before-start
    // slots included) so a long-running session does not retain every
    // sub-generation's output forever. The completer is resolved on every
    // path by now (done/error/cancel/abort).
    for (final s in round.slots) {
      _slots.remove(s.assistantMessageId);
    }
    _rounds.remove(round.conversationId);
    notifyListeners();
  }
}

/// Per-slot pipeline runtime state.
class _SlotRuntime {
  _SlotRuntime({required this.slot, required this.request});

  final GenerationSlot slot;
  final GenerationSlotRequest request;

  final StringBuffer buf = StringBuffer();
  final StringBuffer reasoningBuf = StringBuffer();
  DateTime? reasoningStartAt;
  var hadThinkingBlock = false;

  final List<ReasoningSegmentData> segments = <ReasoningSegmentData>[];
  final List<int> contentSplitOffsets = <int>[];
  final List<int> reasoningCountAtSplit = <int>[];
  final List<int> toolCountAtSplit = <int>[];
  final Map<String, Map<String, dynamic>> toolEventsById =
      <String, Map<String, dynamic>>{};

  /// Per-tool counter for synthetic keys of no-id events ([_toolEventKey]).
  final Map<String, int> noIdToolCounts = <String, int>{};

  int totalTokens = 0;
  TokenUsage? usage;
  TokenUsage? consumedUsage;
  dynamic reasoningDetails;

  String currentContent = '';

  /// `max_tokens` / `context_exceeded` when the response was truncated.
  String? truncationReason;

  /// Gemini thought signature captured from the stream, if any.
  String? geminiThoughtSig;

  Timer? reasoningFlushTimer;
  var reasoningFlushDirty = false;

  Timer? reasoningUiTimer;
  var reasoningUiDirty = false;

  Timer? rampTimer;
  final _SlotPacingState pacing = _SlotPacingState();

  Timer? imageSanitizeTimer;
  var imageSanitizing = false;

  /// Builds the current UI snapshot the page adapters mirror into their
  /// message-row state maps. [reasoningFinishedAt]/[durationMs] carry real
  /// values only on the settle snapshot (finish/fail paths).
  GenerationSlotUiState buildUiState({
    DateTime? reasoningFinishedAt,
    int durationMs = 0,
  }) {
    final consumed = consumedUsage;
    final lastUsage = usage;
    return GenerationSlotUiState(
      reasoningText: reasoningBuf.toString(),
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      segments: List<ReasoningSegmentData>.of(segments),
      contentSplitOffsets: List<int>.of(contentSplitOffsets),
      reasoningCountAtSplit: List<int>.of(reasoningCountAtSplit),
      toolCountAtSplit: List<int>.of(toolCountAtSplit),
      toolEvents: List<Map<String, dynamic>>.of(toolEventsById.values),
      geminiThoughtSig: geminiThoughtSig,
      totalTokens: consumed?.totalTokens ?? totalTokens,
      contextTokens: lastUsage?.totalTokens ?? totalTokens,
      promptTokens: consumed?.promptTokens,
      completionTokens: consumed?.completionTokens,
      cachedTokens: consumed?.cachedTokens,
      durationMs: durationMs,
      truncationReason: truncationReason,
    );
  }
}

/// Content slice pacing for the live notifier (pure state machine — the same
/// ramp the page pipeline used, now engine-owned).
class _SlotPacingState {
  String targetContent = '';
  String visibleContent = '';

  /// True while the page's notifier is attached. Tracks null→non-null
  /// transitions so the ramp syncs to the seeded full text on EVERY
  /// (re)attach, not just before the first content chunk.
  var wasAttached = false;
  final List<int> _recentPickCounts = <int>[];

  String? takeNextContentSlice({
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
    required int moveAverageLength,
  }) {
    if (targetContent == visibleContent) return null;
    if (!targetContent.startsWith(visibleContent)) {
      visibleContent = targetContent;
      _recentPickCounts.clear();
      return visibleContent;
    }

    final backlog = targetContent.length - visibleContent.length;
    if (backlog <= 0) return null;
    final pickCount = _nextPickCount(
      backlog: backlog,
      minCount: minCount,
      baseCount: baseCount,
      maxCount: maxCount,
      pickRate: pickRate,
      moveAverageLength: moveAverageLength,
    );
    final nextLength = math.min(
      targetContent.length,
      visibleContent.length + pickCount,
    );
    visibleContent = targetContent.substring(0, nextLength);
    return visibleContent;
  }

  int _nextPickCount({
    required int backlog,
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
    required int moveAverageLength,
  }) {
    if (backlog <= minCount) return backlog;

    final rawPick = _rawPickCount(
      backlog: backlog,
      minCount: minCount,
      baseCount: baseCount,
      maxCount: maxCount,
      pickRate: pickRate,
    );
    _recentPickCounts.add(rawPick);
    if (_recentPickCounts.length > moveAverageLength) {
      _recentPickCounts.removeAt(0);
    }

    final average =
        _recentPickCounts.reduce((a, b) => a + b) / _recentPickCounts.length;
    return average.round().clamp(minCount, backlog).toInt();
  }

  int _rawPickCount({
    required int backlog,
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
  }) {
    if (backlog <= minCount) return backlog;

    double effectivePickRate;
    if (backlog < baseCount) {
      effectivePickRate = pickRate * backlog / baseCount;
    } else if (backlog >= maxCount) {
      effectivePickRate = math.max((backlog - baseCount) / backlog, pickRate);
    } else {
      final t = (backlog - baseCount) / (maxCount - baseCount);
      effectivePickRate = pickRate + (0.5 - pickRate) * t;
    }

    return math.max(minCount, (backlog * effectivePickRate).round());
  }
}
