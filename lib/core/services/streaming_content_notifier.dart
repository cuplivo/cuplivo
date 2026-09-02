import 'dart:async';

import 'package:flutter/foundation.dart';

import 'logging/flutter_logger.dart';

/// Lightweight tool-height signal for [MessageListView] extent invalidation.
///
/// The list must not compare [oldWidget.toolParts] — that map is mutated in
/// place. This event is the streaming path; a stored signature snapshot covers
/// non-streaming rebuilds.
@immutable
class ToolHeightEvent {
  const ToolHeightEvent({required this.messageId, required this.version});

  final String messageId;
  final int version;
}

/// Lightweight notifier for streaming message content updates.
///
/// This class provides a way to update streaming message content without
/// triggering a full page rebuild. Instead of using ChangeNotifier.notifyListeners()
/// which causes the entire HomePage to rebuild, this uses ValueNotifier
/// so only the specific message widget that's listening will rebuild.
///
/// Usage:
/// 1. StreamController updates content via updateContent()
/// 2. ChatMessageWidget uses ValueListenableBuilder to listen to contentNotifier
/// 3. Only the streaming message widget rebuilds, not the entire page
class StreamingContentNotifier {
  /// Map of message ID to its content notifier.
  /// Each streaming message has its own `ValueNotifier<String>`.
  final Map<String, ValueNotifier<StreamingContentData>> _notifiers =
      <String, ValueNotifier<StreamingContentData>>{};

  /// Coalesced tool-height events. Listeners must not rebuild the page.
  final ValueNotifier<ToolHeightEvent?> toolHeightEvents =
      ValueNotifier<ToolHeightEvent?>(null);

  int _toolHeightVersion = 0;
  final Set<String> _pendingHeightIds = <String>{};
  bool _heightFlushScheduled = false;
  bool _disposed = false;

  /// Get or create a notifier for a message.
  ValueNotifier<StreamingContentData> getNotifier(String messageId) {
    return _notifiers.putIfAbsent(
      messageId,
      () => ValueNotifier<StreamingContentData>(
        const StreamingContentData(content: '', totalTokens: 0),
      ),
    );
  }

  /// Check if a notifier exists for a message.
  bool hasNotifier(String messageId) => _notifiers.containsKey(messageId);

  /// Update content for a streaming message.
  /// This will only notify the specific widget listening to this message's notifier.
  void updateContent(
    String messageId,
    String content,
    int totalTokens, {
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      final next = StreamingContentData(
        content: content,
        totalTokens: totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        promptTokens: promptTokens ?? current.promptTokens,
        completionTokens: completionTokens ?? current.completionTokens,
        cachedTokens: cachedTokens ?? current.cachedTokens,
        durationMs: durationMs ?? current.durationMs,
        translation: current.translation,
      );
      notifier.value = next;
      if (_structureSignatureChanged(current, next)) {
        notifyToolHeightChanged(messageId);
      }
    }
  }

  /// Whether the timeline block structure changed between two streaming
  /// snapshots. Pure text growth keeps the split counter stable — the built
  /// row re-measures itself — but a new thinking or tool block adds rows the
  /// list must be told about, or its extent stays stale.
  static bool _structureSignatureChanged(
    StreamingContentData a,
    StreamingContentData b,
  ) {
    return _splitCount(a.contentSplitOffsets) !=
            _splitCount(b.contentSplitOffsets) ||
        _splitCount(a.reasoningCountAtSplit) !=
            _splitCount(b.reasoningCountAtSplit) ||
        _splitCount(a.toolCountAtSplit) != _splitCount(b.toolCountAtSplit);
  }

  static int _splitCount(List<int>? offsets) => offsets?.length ?? 0;

  /// Update only the live translation for a message. This keeps translation
  /// streaming local to the message row instead of rebuilding HomePage.
  void updateTranslation(String messageId, String translation) {
    final notifier = _notifiers[messageId];
    if (notifier == null) return;
    final current = notifier.value;
    notifier.value = StreamingContentData(
      content: current.content,
      totalTokens: current.totalTokens,
      reasoningText: current.reasoningText,
      reasoningStartAt: current.reasoningStartAt,
      reasoningFinishedAt: current.reasoningFinishedAt,
      contentSplitOffsets: current.contentSplitOffsets,
      reasoningCountAtSplit: current.reasoningCountAtSplit,
      toolCountAtSplit: current.toolCountAtSplit,
      toolPartsVersion: current.toolPartsVersion,
      uiVersion: current.uiVersion,
      promptTokens: current.promptTokens,
      completionTokens: current.completionTokens,
      cachedTokens: current.cachedTokens,
      durationMs: current.durationMs,
      translation: translation,
    );
  }

  /// Update reasoning content for a streaming message.
  void updateReasoning(
    String messageId, {
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      final next = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: reasoningText ?? current.reasoningText,
        reasoningStartAt: reasoningStartAt ?? current.reasoningStartAt,
        reasoningFinishedAt: reasoningFinishedAt ?? current.reasoningFinishedAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        promptTokens: current.promptTokens,
        completionTokens: current.completionTokens,
        cachedTokens: current.cachedTokens,
        durationMs: current.durationMs,
        translation: current.translation,
      );
      notifier.value = next;
      if (_structureSignatureChanged(current, next)) {
        notifyToolHeightChanged(messageId);
      }
    }
  }

  /// Notify that tool parts have been updated.
  /// Uses a version counter to trigger rebuild without copying tool data.
  void notifyToolPartsUpdated(
    String messageId, {
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        toolPartsVersion: current.toolPartsVersion + 1,
        uiVersion: current.uiVersion,
        promptTokens: current.promptTokens,
        completionTokens: current.completionTokens,
        cachedTokens: current.cachedTokens,
        durationMs: current.durationMs,
        translation: current.translation,
      );
    }
    notifyToolHeightChanged(messageId);
  }

  /// Emit a coalesced tool-height event. Safe to call without a content notifier.
  void notifyToolHeightChanged(String messageId) {
    if (_disposed || !_pendingHeightIds.add(messageId)) return;
    if (_heightFlushScheduled) return;
    _heightFlushScheduled = true;
    scheduleMicrotask(_flushToolHeightEvents);
  }

  void _flushToolHeightEvents() {
    _heightFlushScheduled = false;
    if (_disposed) return;
    final ids = List<String>.of(_pendingHeightIds);
    _pendingHeightIds.clear();
    for (final id in ids) {
      _toolHeightVersion += 1;
      toolHeightEvents.value = ToolHeightEvent(
        messageId: id,
        version: _toolHeightVersion,
      );
    }
    if (FlutterLogger.enabled) {
      FlutterLogger.log(
        'tool height events flushed: ids=$ids',
        tag: 'TimelineExtent',
      );
    }
  }

  /// Force a rebuild of the streaming message widget.
  /// Used when external state like reasoning expanded changes.
  void forceRebuild(String messageId) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion + 1,
        promptTokens: current.promptTokens,
        completionTokens: current.completionTokens,
        cachedTokens: current.cachedTokens,
        durationMs: current.durationMs,
        translation: current.translation,
      );
    }
  }

  /// Remove notifier when streaming is complete.
  void removeNotifier(String messageId) {
    final notifier = _notifiers.remove(messageId);
    notifier?.dispose();
  }

  /// Clear all notifiers (e.g., when switching conversations).
  void clear() {
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
  }

  /// Dispose all resources.
  void dispose() {
    _disposed = true;
    _pendingHeightIds.clear();
    clear();
    toolHeightEvents.dispose();
  }
}

/// Data class for streaming content.
@immutable
class StreamingContentData {
  const StreamingContentData({
    required this.content,
    required this.totalTokens,
    this.reasoningText,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    this.contentSplitOffsets,
    this.reasoningCountAtSplit,
    this.toolCountAtSplit,
    this.toolPartsVersion = 0,
    this.uiVersion = 0,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.durationMs,
    this.translation,
  });

  final String content;
  final int totalTokens;
  final String? reasoningText;
  final DateTime? reasoningStartAt;
  final DateTime? reasoningFinishedAt;
  final List<int>? contentSplitOffsets;
  final List<int>? reasoningCountAtSplit;
  final List<int>? toolCountAtSplit;

  /// Version counter for tool parts updates. Incrementing this triggers rebuild.
  final int toolPartsVersion;

  /// Version counter for UI state changes (e.g., reasoning expanded toggle).
  final int uiVersion;

  /// Detailed token usage fields.
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final int? durationMs;
  final String? translation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamingContentData &&
          runtimeType == other.runtimeType &&
          content == other.content &&
          totalTokens == other.totalTokens &&
          reasoningText == other.reasoningText &&
          reasoningStartAt == other.reasoningStartAt &&
          reasoningFinishedAt == other.reasoningFinishedAt &&
          listEquals(contentSplitOffsets, other.contentSplitOffsets) &&
          listEquals(reasoningCountAtSplit, other.reasoningCountAtSplit) &&
          listEquals(toolCountAtSplit, other.toolCountAtSplit) &&
          toolPartsVersion == other.toolPartsVersion &&
          uiVersion == other.uiVersion &&
          promptTokens == other.promptTokens &&
          completionTokens == other.completionTokens &&
          cachedTokens == other.cachedTokens &&
          durationMs == other.durationMs &&
          translation == other.translation;

  @override
  int get hashCode =>
      content.hashCode ^
      totalTokens.hashCode ^
      reasoningText.hashCode ^
      reasoningStartAt.hashCode ^
      reasoningFinishedAt.hashCode ^
      Object.hashAll(contentSplitOffsets ?? const <int>[]) ^
      Object.hashAll(reasoningCountAtSplit ?? const <int>[]) ^
      Object.hashAll(toolCountAtSplit ?? const <int>[]) ^
      toolPartsVersion.hashCode ^
      uiVersion.hashCode ^
      promptTokens.hashCode ^
      completionTokens.hashCode ^
      cachedTokens.hashCode ^
      durationMs.hashCode ^
      translation.hashCode;
}
