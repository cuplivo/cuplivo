import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/compress_context_options.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/utils/token_estimator.dart';

/// Token weights of every message a compression would touch.
///
/// Called on demand — the dialog asks for it the first time it shows a keep-N
/// readout, because counting is linear in text volume (measured ~0.1 s/MB) and
/// the default `start` mode never displays one.
///
/// Two columns come out of the same pass: the model-visible text (body, tool
/// call arguments, tool results) plus one [kUnknownImageTokens] charge per image
/// the model receives, and the body-only lines the summarizer reads. Each
/// message is counted as its own line, so the `\n\n` join inside a chunk (one
/// token each) is not charged — far below the result band's resolution.
///
/// The weight texts are assembled on the calling thread (they are plain
/// strings) and counted in one [compute] batch: `compute` degrades to an inline
/// call on the web, where a raw `Isolate.run` would throw. A batch that cannot
/// be counted falls back to the conservative chars-per-token ratio, so the
/// dialog still has a number to show.
Future<CompressContextWeights> estimateCompressContextWeights({
  required List<ChatMessage> messages,
  required List<Map<String, dynamic>> Function(ChatMessage message)
  toolEventsFor,
}) async {
  final visibleTexts = <String>[];
  final summaryTexts = <String>[];
  final imageCounts = <int>[];
  for (final message in messages) {
    final events = toolEventsFor(message);
    visibleTexts.add(compressWeightTextForMessage(message, toolEvents: events));
    summaryTexts.add(conversationLineForCompression(message) ?? '');
    imageCounts.add(
      compressWeightImageCountForMessage(message, toolEvents: events),
    );
  }
  final messageCount = messages.length;

  /// Per-message model weights: counted text plus the images it carries.
  List<int> withImages(List<int> textTokens) => [
    for (var i = 0; i < messageCount; i++)
      textTokens[i] + imageCounts[i] * kUnknownImageTokens,
  ];

  try {
    // One batch for both columns: a second [compute] would spawn a second
    // isolate for work the first one is already walking.
    final counted = await compute(_countTokens, [
      ...visibleTexts,
      ...summaryTexts,
    ]);
    return CompressContextWeights(
      modelTokens: withImages(counted.sublist(0, messageCount)),
      summaryInputTokens: counted.sublist(messageCount),
    );
  } catch (error, stackTrace) {
    FlutterLogger.log(
      '[CompressContext] token estimate failed, falling back to '
      '${CompressContextOptions.charsPerToken} chars/token: $error\n$stackTrace',
      tag: 'CompressContext',
    );
    return CompressContextWeights(
      modelTokens: withImages(
        CompressContextWeights.tokensFromChars([
          for (final text in visibleTexts) text.length,
        ]),
      ),
      summaryInputTokens: CompressContextWeights.tokensFromChars([
        for (final text in summaryTexts) text.length,
      ]),
    );
  }
}

List<int> _countTokens(List<String> texts) => [
  for (final text in texts) estimateTokens(text),
];
