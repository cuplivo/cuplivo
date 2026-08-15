import 'dart:async';

import '../../providers/settings_provider.dart';
import 'chat_api_service.dart';

/// Stream sender signature used by [PlainTextCollector].
typedef PlainTextStreamSender =
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
    });

/// Layer-① no-tool text-stream collector (ADR-0028): a thin wrapper over
/// [ChatApiService.sendMessageStream] that accumulates `chunk.content` into
/// plain text, optionally reporting the accumulated buffer per chunk or at a
/// caller-provided cadence.
///
/// Consumers: OCR, translation, translate page, ProactiveCare care reply.
/// Non-streaming utility calls (chat suggestions, title generation) stay on
/// `generateText`, which is already shared.
class PlainTextCollector {
  PlainTextCollector({PlainTextStreamSender? sendMessageStream})
    : _sendMessageStream =
          sendMessageStream ?? ChatApiService.sendMessageStream;

  final PlainTextStreamSender _sendMessageStream;

  /// Runs the stream and returns the accumulated text.
  ///
  /// [onAccumulated] fires per non-empty chunk with the full accumulated
  /// buffer (live-update hook for streaming UI). When [updateInterval] is
  /// provided, callbacks are coalesced to that cadence and flushed once after
  /// a successful stream.
  Future<String> collect({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userMediaPaths,
    int? thinkingBudget,
    double? topP,
    int? maxTokens,
    bool stream = true,
    bool allowImagesApiRouting = true,
    bool ocrActive = false,
    String? requestId,
    Duration? updateInterval,
    void Function(String accumulated)? onAccumulated,
  }) async {
    final buffer = StringBuffer();
    Timer? pendingUpdate;
    var streamCompleted = false;
    var collectDone = false;
    String? lastEmitted;
    Object? callbackError;
    StackTrace? callbackStackTrace;

    void emitAccumulated() {
      // A one-shot Timer whose callback event is already queued still runs
      // after collect() finished; the flag makes those late callbacks no-ops.
      if (collectDone || onAccumulated == null || buffer.isEmpty) return;
      final value = buffer.toString();
      if (value == lastEmitted) return;
      lastEmitted = value;
      onAccumulated(value);
    }

    void captureCallbackError(Object e, StackTrace st) {
      callbackError ??= e;
      callbackStackTrace ??= st;
    }

    void scheduleAccumulated() {
      if (collectDone || onAccumulated == null) return;
      final interval = updateInterval;
      if (interval == null || interval <= Duration.zero) {
        emitAccumulated();
        return;
      }
      if (pendingUpdate != null) return;
      pendingUpdate = Timer(interval, () {
        pendingUpdate = null;
        try {
          emitAccumulated();
        } on Object catch (e, st) {
          // Exceptions from a Timer callback cannot propagate to the caller
          // that awaited collect(); capture them and rethrow at the
          // collect() boundary so existing try/catch stays effective.
          captureCallbackError(e, st);
        }
      });
    }

    try {
      await for (final chunk in _sendMessageStream(
        config: config,
        modelId: modelId,
        messages: messages,
        userMediaPaths: userMediaPaths,
        thinkingBudget: thinkingBudget,
        temperature: null,
        topP: topP,
        maxTokens: maxTokens,
        tools: null,
        onToolCall: null,
        extraHeaders: null,
        extraBody: null,
        stream: stream,
        requestId: requestId,
        allowImagesApiRouting: allowImagesApiRouting,
        ocrActive: ocrActive,
      )) {
        if (chunk.content.isEmpty) continue;
        buffer.write(chunk.content);
        scheduleAccumulated();
      }
      streamCompleted = true;
    } on Object catch (_) {
      // Surface a previously captured callback error in preference to the
      // stream error so interval-mode callers keep the same catchable
      // semantics as the per-chunk path.
      if (callbackError != null) {
        Error.throwWithStackTrace(callbackError!, callbackStackTrace!);
      }
      rethrow;
    } finally {
      pendingUpdate?.cancel();
      pendingUpdate = null;
      try {
        if (streamCompleted &&
            updateInterval != null &&
            updateInterval > Duration.zero) {
          emitAccumulated();
        }
      } on Object catch (e, st) {
        captureCallbackError(e, st);
      }
      collectDone = true;
    }
    if (callbackError != null) {
      Error.throwWithStackTrace(callbackError!, callbackStackTrace!);
    }
    return buffer.toString();
  }
}
