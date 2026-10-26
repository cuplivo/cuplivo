import 'dart:convert';

import '../../utils/mcp_structured_image.dart';
import '../../utils/utf16_safe_cut.dart';
import 'chat_message.dart';
import 'context_operation.dart';
import 'message_part.dart';

enum CompressContextLimitMode { start, recent, unlimited, keepRecent }

class CompressContextOptions {
  const CompressContextOptions({
    required this.mode,
    this.maxChars,
    this.keepUserMessages,
    this.historySource = ContextHistorySource.effective,
    this.includeEditedSummaries = true,
    this.includeAttachmentsAndTools = true,
    this.regenerateExisting = false,
    this.newConversation = false,
  });

  static const int defaultMaxChars = 6000;
  static const int defaultKeepUserMessages = 6;

  /// Hard cap on a single compress request, in UTF-16 code units.
  ///
  /// Even a 1M-context model stays at or below this to avoid AOT / regex /
  /// JSON-encode blow-ups. The effective budget is
  /// `min(safeRequestChars, compressRequestCharBudget(...))`.
  static const int safeRequestChars = 100000;

  /// Assumed context window when model metadata is missing.
  /// 32k is a conservative floor for current small chat models.
  static const int defaultContextWindowTokens = 32000;

  /// Fraction of the context window reserved for the compress prompt
  /// wrapper and the model's completion.
  static const double contextReserveFraction = 0.30;

  /// Conservative chars/token (CJK-heavy), for [compressRequestCharBudget] when
  /// per-message token counting is unavailable.
  static const double charsPerToken = 1.6;

  /// Max binary splits when a compress `generateText` hits a context-length
  /// error. Shared across the whole retry tree (halves + merge).
  static const int contextRetryMaxSplits = 5;

  /// Do not split a request whose resulting half would be shorter than this
  /// (UTF-16 code units). Prevents infinite retry on a still-too-dense input.
  static const int contextRetryMinSplitChars = 512;

  final CompressContextLimitMode mode;
  final int? maxChars;
  final int? keepUserMessages;
  final ContextHistorySource historySource;
  final bool includeEditedSummaries;
  final bool includeAttachmentsAndTools;
  final bool regenerateExisting;
  final bool newConversation;

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'maxChars': maxChars,
    'keep': keepUserMessages,
    'source': historySource.name,
    'includeEdited': includeEditedSummaries,
    'includeAttachmentsAndTools': includeAttachmentsAndTools,
    'regenerateExisting': regenerateExisting,
    'newConversation': newConversation,
  };

  factory CompressContextOptions.fromJson(Map<String, dynamic> json) =>
      CompressContextOptions(
        mode: CompressContextLimitMode.values.byName(json['mode'] as String),
        maxChars: json['maxChars'] as int?,
        keepUserMessages: json['keep'] as int?,
        historySource: ContextHistorySource.values.byName(
          json['source'] as String,
        ),
        includeEditedSummaries: json['includeEdited'] as bool,
        includeAttachmentsAndTools: json['includeAttachmentsAndTools'] != false,
        regenerateExisting: json['regenerateExisting'] == true,
        newConversation: json['newConversation'] as bool,
      );
}

bool isCompressionUserMessage(ChatMessage message) =>
    message.role == 'user' &&
    !ContextOperation.isSummary(message) &&
    !message.id.startsWith('context-note:') &&
    (message.content.trim().isNotEmpty ||
        message.parts.any((part) => part is ImagePart || part is FilePart));

typedef CompressionSelection = ({
  List<ChatMessage> effective,
  List<ChatMessage> retained,
  List<ChatMessage> covered,
  List<ChatMessage> input,
  List<String> dependencies,
  bool needsRegeneration,
});

/// The options preview and the actual task use the same range selection.
CompressionSelection selectCompressionHistory(
  List<ChatMessage> messages,
  List<ContextOperation> operations,
  CompressContextOptions options,
) {
  final effective = ContextHistory.resolve(messages, operations);
  final keep = options.mode == CompressContextLimitMode.keepRecent
      ? options.keepUserMessages ??
            CompressContextOptions.defaultKeepUserMessages
      : 0;
  final retained = keep == 0
      ? <ChatMessage>[]
      : selectKeepRecentMessages(effective, keep);
  final prefix = effective.take(effective.length - retained.length).toList();
  final dependencies = prefix
      .where(ContextOperation.isSummary)
      .map((m) => m.id.substring(ContextOperation.summaryPrefix.length))
      .toList();
  final groups = <String>{
    for (final message in prefix)
      if (!ContextOperation.isSummary(message)) ContextHistory.group(message),
    for (final operation in operations)
      if (dependencies.contains(operation.id)) ...operation.sourceGroups,
  };
  final expanded = ContextHistory.compressionInput(
    messages,
    operations,
    source: options.historySource,
    includeEditedSummaries: options.includeEditedSummaries,
  );
  return (
    effective: effective,
    retained: retained,
    covered: messages
        .where((m) => groups.contains(ContextHistory.group(m)))
        .toList(),
    dependencies: dependencies,
    needsRegeneration:
        prefix.isNotEmpty &&
        prefix.every(ContextOperation.isSummary) &&
        options.historySource == ContextHistorySource.effective &&
        !options.regenerateExisting,
    input: expanded.where((message) {
      if (groups.contains(ContextHistory.group(message))) return true;
      final operation = operations
          .where(
            (op) =>
                message.id == op.summaryMessageId ||
                message.id == 'context-note:${op.id}',
          )
          .firstOrNull;
      return operation != null && operation.sourceGroups.every(groups.contains);
    }).toList(),
  );
}

/// Resolve the model that [HomeViewModel.compressContext] will call.
///
/// Chain: compress → summary → title → assistant chat → global default.
/// Provider and model id are resolved independently (same as the existing
/// `??` chain) so a half-set pair can still mix with a later fallback.
({String? providerKey, String? modelId}) resolveCompressContextModel({
  String? compressProvider,
  String? compressModelId,
  String? summaryProvider,
  String? summaryModelId,
  String? titleProvider,
  String? titleModelId,
  String? assistantProvider,
  String? assistantModelId,
  String? currentProvider,
  String? currentModelId,
}) {
  return (
    providerKey:
        compressProvider ??
        summaryProvider ??
        titleProvider ??
        assistantProvider ??
        currentProvider,
    modelId:
        compressModelId ??
        summaryModelId ??
        titleModelId ??
        assistantModelId ??
        currentModelId,
  );
}

/// Per-request UTF-16 budget for one compress `generateText` call.
///
/// Formula:
///   window = contextWindowTokens ?? defaultContextWindowTokens (32k)
///   usableTokens = window * (1 - reserveFraction)   // 30% reserved
///   chars = floor(usableTokens * charsPerToken)     // 1.6, CJK-heavy
///   budget = min(safeRequestChars, max(1, chars))
///
/// A 32k window → 22400 usable tokens → 35840 chars.
/// A 128k+ window is larger but still capped at [safeRequestChars].
int compressRequestCharBudget({
  int? contextWindowTokens,
  int safeRequestChars = CompressContextOptions.safeRequestChars,
  int defaultContextWindowTokens =
      CompressContextOptions.defaultContextWindowTokens,
  double reserveFraction = CompressContextOptions.contextReserveFraction,
  double charsPerToken = CompressContextOptions.charsPerToken,
}) {
  final window = (contextWindowTokens == null || contextWindowTokens <= 0)
      ? defaultContextWindowTokens
      : contextWindowTokens;
  final chars = (window * (1.0 - reserveFraction) * charsPerToken).floor();
  if (chars < 1) return 1;
  return chars < safeRequestChars ? chars : safeRequestChars;
}

String buildCompressContextContent(
  String joined,
  CompressContextOptions options,
) {
  if (options.mode == CompressContextLimitMode.unlimited ||
      options.mode == CompressContextLimitMode.keepRecent) {
    return joined;
  }
  final maxChars = options.maxChars ?? CompressContextOptions.defaultMaxChars;
  if (maxChars <= 0 || joined.length <= maxChars) return joined;
  return switch (options.mode) {
    CompressContextLimitMode.start => truncateHeadUtf16Safe(joined, maxChars),
    CompressContextLimitMode.recent => joined.substring(
      utf16SafeTailStart(joined, joined.length - maxChars),
    ),
    CompressContextLimitMode.unlimited ||
    CompressContextLimitMode.keepRecent => joined,
  };
}

String? conversationLineForCompression(ChatMessage message) {
  if (message.content.trim().isEmpty) return null;
  return '${message.role == "assistant" ? "Assistant" : "User"}: ${message.content}';
}

/// Incremental start/recent window. Walks messages and stops at [maxChars]
/// without first joining the full history.
String buildBoundedConversationText(
  List<ChatMessage> messages, {
  required CompressContextLimitMode mode,
  required int maxChars,
}) {
  if (maxChars <= 0) return '';
  if (mode == CompressContextLimitMode.recent) {
    return _buildRecentBoundedConversationText(messages, maxChars);
  }
  return _buildStartBoundedConversationText(messages, maxChars);
}

String _buildStartBoundedConversationText(
  List<ChatMessage> messages,
  int maxChars,
) {
  final buf = StringBuffer();
  for (final message in messages) {
    if (message.content.trim().isEmpty) continue;
    final prefix = message.role == 'assistant' ? 'Assistant: ' : 'User: ';
    final sep = buf.isEmpty ? '' : '\n\n';
    final remaining = maxChars - buf.length;
    if (remaining <= 0) break;
    final head = '$sep$prefix';
    if (head.length >= remaining) {
      buf.write(truncateHeadUtf16Safe(head, remaining));
      break;
    }
    final contentBudget = remaining - head.length;
    final content = message.content.length <= contentBudget
        ? message.content
        : truncateHeadUtf16Safe(message.content, contentBudget);
    buf
      ..write(head)
      ..write(content);
    if (message.content.length > contentBudget) break;
  }
  return buf.toString();
}

String _buildRecentBoundedConversationText(
  List<ChatMessage> messages,
  int maxChars,
) {
  final parts = <String>[];
  var used = 0;
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message.content.trim().isEmpty) continue;
    final prefix = message.role == 'assistant' ? 'Assistant: ' : 'User: ';
    final sepLen = parts.isEmpty ? 0 : 2;
    final remaining = maxChars - used - sepLen;
    if (remaining <= 0) break;
    final lineLen = prefix.length + message.content.length;
    if (lineLen <= remaining) {
      parts.add('$prefix${message.content}');
      used += lineLen + sepLen;
      continue;
    }
    final tail = _utf16SafeTailOfPrefixed(prefix, message.content, remaining);
    if (tail.isNotEmpty) parts.add(tail);
    break;
  }
  return parts.reversed.join('\n\n');
}

String _utf16SafeTailOfPrefixed(String prefix, String content, int maxChars) {
  final total = prefix.length + content.length;
  if (total <= maxChars) return '$prefix$content';
  if (maxChars <= 0) return '';
  if (maxChars <= content.length) {
    final start = utf16SafeTailStart(content, content.length - maxChars);
    return content.substring(start);
  }
  final prefixKeep = maxChars - content.length;
  final start = utf16SafeTailStart(prefix, prefix.length - prefixKeep);
  return '${prefix.substring(start)}$content';
}

/// Pack formatted messages into chunks of at most [maxChars].
/// Prefers message boundaries; a single over-long line is UTF-16-safe split.
List<String> chunkMessagesForCompression(
  List<ChatMessage> messages, {
  required int maxChars,
}) {
  if (maxChars <= 0) return const <String>[];
  final chunks = <String>[];
  final current = StringBuffer();

  void flush() {
    if (current.isEmpty) return;
    chunks.add(current.toString());
    current.clear();
  }

  for (final message in messages) {
    final line = conversationLineForCompression(message);
    if (line == null) continue;
    if (line.length > maxChars) {
      flush();
      chunks.addAll(splitUtf16SafeChunks(line, maxChars));
      continue;
    }
    final extra = current.isEmpty ? line.length : line.length + 2;
    if (current.isNotEmpty && current.length + extra > maxChars) {
      flush();
    }
    if (current.isNotEmpty) current.write('\n\n');
    current.write(line);
  }
  flush();
  return chunks;
}

/// Pack already-formatted texts (chunk summaries) into budget-sized groups.
List<String> chunkPlainTexts(List<String> texts, {required int maxChars}) {
  if (maxChars <= 0) return const <String>[];
  final chunks = <String>[];
  final current = StringBuffer();

  void flush() {
    if (current.isEmpty) return;
    chunks.add(current.toString());
    current.clear();
  }

  for (final text in texts) {
    if (text.isEmpty) continue;
    if (text.length > maxChars) {
      flush();
      chunks.addAll(splitUtf16SafeChunks(text, maxChars));
      continue;
    }
    final extra = current.isEmpty ? text.length : text.length + 2;
    if (current.isNotEmpty && current.length + extra > maxChars) {
      flush();
    }
    if (current.isNotEmpty) current.write('\n\n');
    current.write(text);
  }
  flush();
  return chunks;
}

/// Build the per-request compress payloads.
///
/// start/recent: incremental character window (never joins the full history),
/// then split only if the window itself exceeds [safeRequestChars].
/// keepRecent/unlimited: message-boundary chunks at [safeRequestChars] so
/// older content is not dropped and no single request is unbounded.
List<String> buildCompressRequestContents(
  List<ChatMessage> messages,
  CompressContextOptions options, {
  int safeRequestChars = CompressContextOptions.safeRequestChars,
}) {
  if (options.mode == CompressContextLimitMode.start ||
      options.mode == CompressContextLimitMode.recent) {
    final maxChars = options.maxChars ?? CompressContextOptions.defaultMaxChars;
    final bounded = buildBoundedConversationText(
      messages,
      mode: options.mode,
      maxChars: maxChars,
    );
    if (bounded.trim().isEmpty) return const <String>[];
    if (bounded.length <= safeRequestChars) return [bounded];
    return splitUtf16SafeChunks(bounded, safeRequestChars);
  }
  return chunkMessagesForCompression(messages, maxChars: safeRequestChars);
}

/// Index where the kept (verbatim) region starts: the position of the
/// [keepUserMessages]-th user message counted from the end.
///
/// A message counts the same way the keep count and the dialog's round total
/// count it — [isCompressionUserMessage], which includes attachment-only
/// inputs. The kept region therefore always begins on a user message, so an
/// assistant reply is never separated from the request that produced it.
///
/// Leading summaries stay outside the retained region, so an explicit
/// original-history reread can regenerate them even when every raw user
/// message is retained.
///
/// Returns 0 when the requested count covers every user message (nothing is
/// left to summarize), and null when the list holds no user message at all
/// (nothing can be kept).
int? keepRecentStartIndex(List<ChatMessage> messages, int keepUserMessages) {
  if (keepUserMessages <= 0) return null;
  final userIndices = <int>[];
  for (var i = 0; i < messages.length; i++) {
    if (isCompressionUserMessage(messages[i])) {
      userIndices.add(i);
    }
  }
  if (userIndices.isEmpty) return null;
  if (userIndices.length <= keepUserMessages) return 0;
  return userIndices[userIndices.length - keepUserMessages];
}

/// Select the trailing messages from [keepRecentStartIndex] to the end.
List<ChatMessage> selectKeepRecentMessages(
  List<ChatMessage> messages,
  int keepUserMessages,
) {
  final start = keepRecentStartIndex(messages, keepUserMessages);
  if (start == null) return const <ChatMessage>[];
  if (start == 0) {
    return messages.skipWhile(ContextOperation.isSummary).toList();
  }
  return messages.sublist(start);
}

/// Number of user messages in a collapsed list (role 'user', non-empty
/// content) — the count that [selectKeepRecentMessages] counts against.
int countUserMessages(List<ChatMessage> messages) {
  return messages.where(isCompressionUserMessage).length;
}

/// Conservative detector for provider context-window / prompt-too-long errors.
///
/// Providers surface overflow as an HTTP / provider exception whose
/// `toString()` includes the API body. Only phrases that strongly indicate
/// an input-token overflow match; generic `max_tokens` config errors do not.
bool isContextLengthError(Object error) {
  final lower = error.toString().toLowerCase();
  const phrases = <String>[
    'context_length',
    'context length',
    'context window',
    'maximum context',
    'max context',
    'too many tokens',
    'prompt is too long',
    'prompt too long',
    'input is too long',
    'input too long',
    'reduce the length of the messages',
    'reduce the length of the prompt',
    'exceeds the maximum number of tokens',
  ];
  if (phrases.any(lower.contains)) return true;
  if (lower.contains('max_tokens') &&
      (lower.contains('exceed') ||
          lower.contains('too long') ||
          lower.contains('too many') ||
          lower.contains('over'))) {
    return true;
  }
  return false;
}

class _ContextSplitBudget {
  _ContextSplitBudget(this.remaining);

  int remaining;

  bool get canSplit => remaining > 0;

  void consume() {
    remaining--;
  }
}

/// Summarize [text], UTF-16-safely splitting and retrying on context-length
/// errors. [summarize] is the injected generate call (chunk or merge).
///
/// On overflow: split in half, summarize each half, then summarize the
/// joined pair (same merge path as multi-chunk). Stops when [maxSplits]
/// is exhausted or a half would be below [minSplitChars]. Other errors
/// are rethrown immediately.
Future<String> summarizeWithContextRetry(
  String text, {
  required Future<String> Function(String text) summarize,
  int maxSplits = CompressContextOptions.contextRetryMaxSplits,
  int minSplitChars = CompressContextOptions.contextRetryMinSplitChars,
  void Function(Object error, StackTrace stackTrace, String text)? onSplitRetry,
}) {
  return _summarizeWithContextRetry(
    text,
    summarize: summarize,
    budget: _ContextSplitBudget(maxSplits),
    minSplitChars: minSplitChars,
    onSplitRetry: onSplitRetry,
  );
}

Future<String> _summarizeWithContextRetry(
  String text, {
  required Future<String> Function(String text) summarize,
  required _ContextSplitBudget budget,
  required int minSplitChars,
  required void Function(Object error, StackTrace stackTrace, String text)?
  onSplitRetry,
}) async {
  try {
    return await summarize(text);
  } catch (e, st) {
    if (!isContextLengthError(e) || !budget.canSplit) {
      rethrow;
    }
    final halves = splitUtf16SafeHalves(text);
    if (halves == null ||
        halves.left.length < minSplitChars ||
        halves.right.length < minSplitChars) {
      rethrow;
    }
    budget.consume();
    onSplitRetry?.call(e, st, text);
    final left = await _summarizeWithContextRetry(
      halves.left,
      summarize: summarize,
      budget: budget,
      minSplitChars: minSplitChars,
      onSplitRetry: onSplitRetry,
    );
    final right = await _summarizeWithContextRetry(
      halves.right,
      summarize: summarize,
      budget: budget,
      minSplitChars: minSplitChars,
      onSplitRetry: onSplitRetry,
    );
    return _summarizeWithContextRetry(
      '$left\n\n$right',
      summarize: summarize,
      budget: budget,
      minSplitChars: minSplitChars,
      onSplitRetry: onSplitRetry,
    );
  }
}

/// The text one message contributes to the compression readout's estimate.
///
/// The readout answers "how many tokens does this conversation cost", so it
/// counts what the model would see for the message: its body, plus every tool
/// call and tool result. It is deliberately *not* the text a compression
/// request carries — that stays body-only ([conversationLineForCompression]) —
/// so counting tool payloads here never makes a request larger.
///
/// Images are counted separately ([compressWeightImageCountForMessage]): the
/// model receives them as image parts, not as the markdown line a tool result
/// carries, so that line is stripped here exactly like `ToolResultContent`
/// strips it before sending.
String compressWeightTextForMessage(
  ChatMessage message, {
  required List<Map<String, dynamic>> toolEvents,
}) {
  final buffer = StringBuffer(message.content);
  for (final event in toolEvents) {
    final name = (event['name'] ?? '').toString().trim();
    buffer
      ..write('\n\n')
      ..write(name.isEmpty ? '[tool]' : '[$name]');
    final arguments = event['arguments'];
    if (arguments is Map && arguments.isNotEmpty) {
      try {
        buffer
          ..write('\n')
          ..write(jsonEncode(arguments));
      } catch (_) {
        // An argument map that cannot be encoded is not worth failing an
        // estimate over; the result below is usually the heavier half anyway.
      }
    } else if (arguments != null) {
      // Streamed JSON that never finished parsing is persisted as a raw
      // String (stream_chunk_handler.dart); dropping it would silently
      // uncount this call's arguments.
      final raw = arguments.toString();
      if (raw.trim().isNotEmpty) {
        buffer
          ..write('\n')
          ..write(raw);
      }
    }
    var result = toolResultContentForModel(event['content']?.toString());
    for (final uri in _toolResultImageUris(event)) {
      result = result.replaceAll(
        '![](${encodeMarkdownImageDestination(uri)})',
        '',
      );
    }
    if (result.trim().isNotEmpty) {
      buffer
        ..write('\n')
        ..write(result);
    }
  }
  return buffer.toString();
}

/// Images the model receives from one message: its attached image parts plus
/// the typed images of its tool results.
///
/// Only `metadata.mcpResult.imageUris` counts, because that is exactly what
/// `ToolResultContent` turns into image input — also when a later request
/// rebuilds the turn from history. The older envelope's `imageUris` and a
/// result's markdown `![...](path)` line never become image parts, so they stay
/// what they are: text the model reads.
///
/// Whether the target model accepts image input is not consulted: a model
/// without vision receives a text marker instead, and charging the image anyway
/// errs high rather than promising a saving that is not there.
int compressWeightImageCountForMessage(
  ChatMessage message, {
  required List<Map<String, dynamic>> toolEvents,
}) {
  var count = 0;
  for (final part in message.parts) {
    if (part is ImagePart && !part.unavailable && part.uri.trim().isNotEmpty) {
      count++;
    }
  }
  for (final event in toolEvents) {
    count += _toolResultImageUris(event).length;
  }
  return count;
}

/// Typed image URIs of one tool event, in `ToolResultContent`'s reading.
List<String> _toolResultImageUris(Map<String, dynamic> event) {
  final metadata = event['metadata'];
  if (metadata is! Map) return const <String>[];
  return mcpResultImageUris(
    readMcpResultMetadata(metadata.cast<String, dynamic>()),
  );
}

/// What one compression costs before and after, in tokens.
class CompressContextSplit {
  const CompressContextSplit({
    required this.totalTokens,
    required this.keptTokens,
    required this.summaryInputTokens,
  });

  /// Share of the summarized span assumed to survive as the summary. Both ends
  /// are shown as a band, so the assumption stays visible instead of reading as
  /// a measurement.
  static const double minSummaryFraction = 0.10;
  static const double maxSummaryFraction = 0.30;

  /// Tokens of the whole compressed span, as the model sees it.
  final int totalTokens;

  /// Tokens that stay verbatim, as the model sees them.
  final int keptTokens;

  /// Tokens of the summarized span **as the summarizer reads it** — bodies
  /// only. Deliberately not `totalTokens - keptTokens`: tool payloads are model
  /// tokens that never enter a compression request, so applying the summary
  /// fraction to the tool-inclusive mass understates the reduction.
  final int summaryInputTokens;

  int get minResultTokens => _withSummary(minSummaryFraction);
  int get maxResultTokens => _withSummary(maxSummaryFraction);

  /// Midpoint of the result band: the one number the readout reduces by.
  int get midResultTokens => ((minResultTokens + maxResultTokens) / 2).round();

  /// Whole-percent reduction from [totalTokens] to [midResultTokens]; 0 when
  /// there is nothing to compress, or nothing to measure.
  int get reductionPercent {
    if (totalTokens <= 0 || summaryInputTokens <= 0) return 0;
    return ((totalTokens - midResultTokens) / totalTokens * 100).round();
  }

  int _withSummary(double fraction) =>
      keptTokens + (summaryInputTokens * fraction).round();
}
