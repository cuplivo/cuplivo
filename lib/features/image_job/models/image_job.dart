/// One in-flight image generation, owned by the message part that asked for it.
///
/// A job never outlives its message: [conversationId] / [messageId] /
/// [toolCallId] are the owner, and the persisted mirror of its state lives in
/// that message part's payload (see `ImagePart.state` / `ImagePart.jobId`).
///
/// States are a closed set. `queued -> running -> completed | failed` and any
/// non-terminal state can move to `cancelled` or `interrupted`:
///
/// * `cancelled`  – the user cancelled; a late runner result is discarded.
/// * `interrupted` – the app died while the job was live; terminal, never
///   resumed automatically.
library;

enum ImageJobState {
  queued,
  running,
  completed,
  failed,
  cancelled,
  interrupted;

  bool get isTerminal => switch (this) {
    ImageJobState.completed ||
    ImageJobState.failed ||
    ImageJobState.cancelled ||
    ImageJobState.interrupted => true,
    ImageJobState.queued || ImageJobState.running => false,
  };

  /// Whether the placeholder for this job should still show progress.
  bool get isActive => !isTerminal;
}

const Object _unset = Object();

final class ImageJob {
  const ImageJob({
    required this.id,
    required this.conversationId,
    required this.messageId,
    required this.toolCallId,
    required this.idempotencyKey,
    required this.prompt,
    required this.assetId,
    required this.uri,
    required this.createdAt,
    this.aspectRatio,
    this.state = ImageJobState.queued,
    this.error,
    this.errorCode,
    this.resultUri,
    this.startedAt,
    this.finishedAt,
  });

  /// Stable across re-renders: the idempotency key *is* the identity.
  final String id;
  final String conversationId;
  final String messageId;
  final String toolCallId;
  final String idempotencyKey;
  final String prompt;
  final String? aspectRatio;

  /// The asset the job was promised at call time. Bytes land when the runner
  /// finishes; until then [uri] is a path that does not exist yet.
  final String assetId;
  final String uri;

  final ImageJobState state;

  /// What went wrong, in words a person can act on (shown on the card). The
  /// category lives in [errorCode]; this is the sentence.
  final String? error;

  /// `timeout` or `provider_error`, for code that branches on the kind.
  final String? errorCode;
  final String? resultUri;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// Only the lifecycle fields move; the owner and the promised path are fixed.
  ImageJob copyWith({
    ImageJobState? state,
    Object? error = _unset,
    Object? errorCode = _unset,
    Object? resultUri = _unset,
    DateTime? startedAt,
    DateTime? finishedAt,
  }) {
    return ImageJob(
      id: id,
      conversationId: conversationId,
      messageId: messageId,
      toolCallId: toolCallId,
      idempotencyKey: idempotencyKey,
      prompt: prompt,
      aspectRatio: aspectRatio,
      assetId: assetId,
      uri: uri,
      createdAt: createdAt,
      state: state ?? this.state,
      error: identical(error, _unset) ? this.error : error as String?,
      errorCode: identical(errorCode, _unset)
          ? this.errorCode
          : errorCode as String?,
      resultUri: identical(resultUri, _unset)
          ? this.resultUri
          : resultUri as String?,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }

  @override
  String toString() => 'ImageJob($id, $state)';
}

/// What a successful runner hands back: the bytes now exist at [uri].
final class ImageJobOutcome {
  const ImageJobOutcome({required this.uri, this.assetId, this.mime});

  final String uri;
  final String? assetId;
  final String? mime;
}
