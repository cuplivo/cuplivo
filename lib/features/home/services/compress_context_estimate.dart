import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/compress_context_options.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/utils/token_estimator.dart';

/// Token weight of every message a compression would touch.
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
  final texts = <String>[
    for (final message in messages)
      compressWeightTextForMessage(message, toolEvents: toolEventsFor(message)),
  ];
  try {
    return CompressContextWeights(tokens: await compute(_countTokens, texts));
  } catch (error, stackTrace) {
    FlutterLogger.log(
      '[CompressContext] token estimate failed, falling back to '
      '${CompressContextOptions.charsPerToken} chars/token: $error\n$stackTrace',
      tag: 'CompressContext',
    );
    return CompressContextWeights.fromCharsPerToken([
      for (final text in texts) text.length,
    ]);
  }
}

List<int> _countTokens(List<String> texts) => [
  for (final text in texts) estimateTokens(text),
];
