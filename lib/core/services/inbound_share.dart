import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/chat_input_data.dart';

/// A file shared into Cuplivo from another app, staged by the native layer
/// (Android content:// copy or iOS App Group inbox).
class InboundSharedFile {
  const InboundSharedFile({
    required this.path,
    required this.name,
    required this.mime,
  });

  final String path;
  final String name;
  final String mime;
}

/// One inbound-share payload — everything a single OS share handed to Cuplivo.
///
/// Native stages the binary files and reports local paths; [stagingDir] is the
/// per-share directory to delete once the files have been imported into the
/// app's own upload directory.
class InboundSharePayload {
  const InboundSharePayload({
    this.text,
    this.imagePaths = const <String>[],
    this.files = const <InboundSharedFile>[],
    this.stagingDir,
    this.failedCount = 0,
  });

  final String? text;
  final List<String> imagePaths;
  final List<InboundSharedFile> files;
  final String? stagingDir;

  /// Files the native layer could not copy out of the source app's sandbox
  /// (Android only; iOS stages atomically). Folded into the import outcome so
  /// a partially failed share surfaces the partial warning.
  final int failedCount;

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) &&
      imagePaths.isEmpty &&
      files.isEmpty &&
      failedCount == 0;

  /// Tolerant parse of the native payload map. Returns null when the payload
  /// is absent, malformed, or carries nothing usable.
  static InboundSharePayload? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final map = <String, Object?>{};
    raw.forEach((key, value) => map[key.toString()] = value);

    final rawText = map['text'];
    final text = rawText is String && rawText.trim().isNotEmpty
        ? rawText
        : null;

    final imagePaths = <String>[];
    final rawImages = map['images'];
    if (rawImages is List) {
      for (final entry in rawImages) {
        if (entry is String && entry.isNotEmpty) imagePaths.add(entry);
      }
    }

    final files = <InboundSharedFile>[];
    final rawFiles = map['files'];
    if (rawFiles is List) {
      for (final entry in rawFiles) {
        if (entry is! Map) continue;
        final path = entry['path'];
        if (path is! String || path.isEmpty) continue;
        final rawName = entry['name'];
        final name = rawName is String && rawName.trim().isNotEmpty
            ? rawName.trim()
            : path.split(RegExp(r'[\\/]')).last;
        final rawMime = entry['mime'];
        files.add(
          InboundSharedFile(
            path: path,
            name: name,
            mime: rawMime is String ? rawMime.trim() : '',
          ),
        );
      }
    }

    final rawStaging = map['stagingDir'];
    final stagingDir = rawStaging is String && rawStaging.isNotEmpty
        ? rawStaging
        : null;

    final rawFailed = map['failed'];
    final failedCount = rawFailed is int && rawFailed > 0 ? rawFailed : 0;

    final payload = InboundSharePayload(
      text: text,
      imagePaths: imagePaths,
      files: files,
      stagingDir: stagingDir,
      failedCount: failedCount,
    );
    return payload.isEmpty ? null : payload;
  }
}

/// Where an inbound share should land, given the current composer/conversation.
enum InboundShareLanding {
  /// The composer already holds content — append to it in place.
  mergeIntoCurrent,

  /// The current conversation is a pristine draft — populate its composer.
  populateCurrentDraft,

  /// Start a fresh conversation and populate its composer.
  newConversation,
}

/// Pure landing decision (see CONTEXT.md → Inbound Share). Never discards
/// unsent composer content: a non-empty composer always wins.
InboundShareLanding decideInboundShareLanding({
  required bool composerHasContent,
  required bool conversationIsPristine,
}) {
  if (composerHasContent) return InboundShareLanding.mergeIntoCurrent;
  if (conversationIsPristine) return InboundShareLanding.populateCurrentDraft;
  return InboundShareLanding.newConversation;
}

/// Merges shared text into the composer text, appending on a new line. An
/// empty incoming value leaves the existing text untouched.
String mergeInboundShareText(String existing, String? incoming) {
  final incomingText = (incoming ?? '').trim();
  if (incomingText.isEmpty) return existing;
  if (existing.trim().isEmpty) return incomingText;
  return '$existing\n$incomingText';
}

/// Folds an inbound share into an existing composer snapshot, preserving every
/// field the draft carries (quote, quick instructions, routing, body extras).
ChatInputData mergeInboundShareIntoInput(
  ChatInputData draft,
  ChatInputData incoming,
) {
  return draft.copyWith(
    text: mergeInboundShareText(draft.text, incoming.text),
    imagePaths: [...draft.imagePaths, ...incoming.imagePaths],
    documents: [...draft.documents, ...incoming.documents],
  );
}

/// Platform bridge for the OS share target (Android `ACTION_SEND`, iOS Share
/// Extension). Mirrors `AndroidProcessText`: a cold-start pull plus a
/// warm-delivery broadcast stream.
class InboundShare {
  InboundShare._();

  static const MethodChannel _channel = MethodChannel('app.inbound_share');
  static final StreamController<InboundSharePayload> _controller =
      StreamController<InboundSharePayload>.broadcast();
  static bool _initialized = false;

  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onShare') return;
      final payload = InboundSharePayload.fromMap(call.arguments);
      if (payload != null) _controller.add(payload);
    });
  }

  static Stream<InboundSharePayload> get stream => _controller.stream;

  /// Cold-start share staged before the Flutter engine was ready. One-shot:
  /// the native side clears its pending reference after this call.
  static Future<InboundSharePayload?> getInitialPayload() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getInitialShare');
      return InboundSharePayload.fromMap(result);
    } catch (error, stackTrace) {
      debugPrint('[InboundShare] getInitialShare failed: $error\n$stackTrace');
      return null;
    }
  }
}
