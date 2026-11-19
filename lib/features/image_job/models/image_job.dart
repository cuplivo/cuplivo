/// One in-flight image generation, owned by the message part that asked for it.
///
/// A job never outlives its message: [conversationId] / [messageId] /
/// [toolCallId] are the owner, and the persisted mirror of its state lives in
/// that message part's payload (see `ImagePart.state` / `ImagePart.jobId`).
///
/// States are a closed set: `queued -> running -> completed | failed`.
///
/// Nothing cancels a job (there is no cancel entry in the UI, by decision), and a
/// process that dies takes its jobs with it — a fresh process has no live job to
/// mark, and the renderer derives `ImagePartState.interrupted` from a persisted
/// `pending` part with no job behind it. So the enum deliberately has no
/// `cancelled` / `interrupted`: a state nothing can produce is a table a future
/// editor will trust and then wait for.
library;

enum ImageJobState {
  queued,
  running,
  completed,
  failed;

  bool get isTerminal => switch (this) {
    ImageJobState.completed || ImageJobState.failed => true,
    ImageJobState.queued || ImageJobState.running => false,
  };
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
    this.mime,
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

  /// The type the backend actually returned. The promised path keeps a `.png`
  /// name because the model already wrote that exact uri into the reply, so this
  /// is the only place the real type survives — readers must not infer it from
  /// the extension.
  final String? mime;

  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// Only the lifecycle fields move; the owner and the promised path are fixed.
  ImageJob copyWith({
    ImageJobState? state,
    Object? error = _unset,
    Object? errorCode = _unset,
    Object? resultUri = _unset,
    Object? mime = _unset,
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
      mime: identical(mime, _unset) ? this.mime : mime as String?,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }

  @override
  String toString() => 'ImageJob($id, $state)';
}

/// What a successful runner hands back: the bytes now exist at [uri].
final class ImageJobOutcome {
  const ImageJobOutcome({required this.uri, this.mime});

  final String uri;

  /// The type the backend returned. The job carries the asset id already, so
  /// repeating it here would be a second source for the same fact.
  final String? mime;
}

/// How long a job took, never negative.
///
/// `startedAt` and `finishedAt` are wall-clock readings, so a clock step
/// backwards (NTP, a manual change) makes the difference negative — and that is
/// not cosmetic: `ImagePart` decodes a negative `durationMs` as
/// `invalid_duration`, so the whole part hydrates as `MalformedPart` and the
/// picture stops rendering for good. Clamped where it is computed.
Duration? jobDuration(ImageJob job) {
  final finished = job.finishedAt;
  if (finished == null) return null;
  final started = job.startedAt ?? job.createdAt;
  final elapsed = finished.difference(started);
  return elapsed.isNegative ? Duration.zero : elapsed;
}
