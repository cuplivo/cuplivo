/// Owns the whole life of "a picture the reply promised".
///
/// One place decides all four things that must agree:
///
/// * which `provider + model` draws it (assistant choice, then the global
///   default — never the conversation, never the text model);
/// * where the bytes will land, fixed at creation so the `uri` the model was
///   handed never moves;
/// * what the message shows meanwhile, which is an [ImagePart] whose `state`
///   says pending / failed / cancelled / completed;
/// * when a late runner result must be thrown away (cancel / interrupt).
///
/// The durable mirror of a job is its [ImagePart]: the part is what the
/// renderer reads, what the outbox skips, and what a restart explains. The
/// in-memory job is the live handle on the same thing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/serial_queue.dart';
import '../models/image_job.dart';
import 'image_backends.dart';
import 'image_job_manager.dart';
import 'image_model_resolver.dart';

/// What [ImageJobCoordinator.begin] produced: a job, or a reason there is none.
sealed class ImageJobStart {
  const ImageJobStart();

  /// What the tool answers with: a promise, or an error the model can relay.
  Map<String, dynamic> toToolResult();
}

final class ImageJobStarted extends ImageJobStart {
  const ImageJobStarted(this.job);

  final ImageJob job;

  /// Exactly what the tool returns: three fields, no picture, no base64.
  @override
  Map<String, dynamic> toToolResult() => <String, dynamic>{
    'status': 'pending',
    'asset_id': job.assetId,
    'uri': job.uri,
  };
}

final class ImageJobRefused extends ImageJobStart {
  const ImageJobRefused(this.code, this.message);

  /// Machine-readable reason, so the model can tell the user what to fix.
  final String code;
  final String message;

  @override
  Map<String, dynamic> toToolResult() => <String, dynamic>{
    'error': code,
    'message': message,
  };
}

/// Builds the backend for one resolved `provider + model`.
typedef ImageBackendFactory =
    ImageBackend Function(ProviderConfig config, String modelId);

/// The coordinator above [context], or null when this subtree has none.
///
/// Look it up by its own type: `read<ImageJobCoordinator?>()` asks the provider
/// tree for a *nullable* provider, finds nothing, and silently answers null —
/// which made the card believe it had no job, so it never ticked and never
/// refreshed when the bytes landed.
ImageJobCoordinator? imageJobCoordinatorOf(BuildContext context) {
  try {
    return context.read<ImageJobCoordinator>();
  } catch (_) {
    return null;
  }
}

class ImageJobCoordinator extends ChangeNotifier {
  ImageJobCoordinator(
    this._settings,
    this._chat, {
    ImageBackendFactory? backendFactory,
    ImageJobManager? manager,
    DateTime Function()? clock,
  }) : _backendFactory = backendFactory ?? imageBackendFor,
       _clock = clock ?? DateTime.now {
    this.manager = manager ?? ImageJobManager(_run, clock: _clock);
    this.manager.addListener(_mirror);
  }

  final SettingsProvider _settings;
  final ChatService _chat;
  final ImageBackendFactory _backendFactory;
  final DateTime Function() _clock;

  /// Late-initialised: the runner handed to it is [\_run], which needs `this`.
  late final ImageJobManager manager;

  /// What each job's last mirrored [ImagePart] said, so a notification storm
  /// cannot rewrite the same row.
  final Map<String, ImageJobState> _written = <String, ImageJobState>{};

  final Map<String, ModelBinding> _bindings = <String, ModelBinding>{};
  final Map<String, List<ImageReference>> _references =
      <String, List<ImageReference>>{};

  /// The live job behind [assetId], if any. The renderer uses this to tell
  /// "still painting" from "the app died while painting".
  ImageJob? jobForAsset(String? assetId) {
    final id = assetId?.trim() ?? '';
    if (id.isEmpty) return null;
    for (final job in manager.jobs) {
      if (job.assetId == id) return job;
    }
    return null;
  }

  /// Mirrored parts for [messageId].
  ///
  /// The live stream cannot know about a job it did not create — the tool that
  /// created it answered mid-flight — so the reply's part list takes these from
  /// here. After a restart this is empty and the persisted parts (written by
  /// [_mirror]) are what the message shows.
  List<ImagePart> partsFor(String messageId) {
    final parts = <ImagePart>[];
    for (final job in manager.jobs) {
      if (job.messageId != messageId) continue;
      parts.add(_partFor(job));
    }
    return parts;
  }

  /// Creation: idempotent, refuses what it cannot do, and starts the picture.
  ///
  /// [messageId] is normally omitted: tools run inside the reply that is being
  /// generated, and that reply is found by its own streaming flag. Retry passes
  /// it explicitly because it runs long after the stream ended.
  Future<ImageJobStart> begin({
    required String conversationId,
    required String toolCallId,
    required String prompt,
    Assistant? assistant,
    String? messageId,
    String? aspectRatio,
    List<String> referenceImageIds = const <String>[],
  }) async {
    final text = prompt.trim();
    if (text.isEmpty) {
      return const ImageJobRefused(
        'empty_prompt',
        'A picture needs a prompt describing what to draw.',
      );
    }

    final targetMessageId =
        messageId ?? _generatingAssistantMessageId(conversationId);
    if (targetMessageId == null) {
      return const ImageJobRefused(
        'no_target_message',
        'A picture needs the reply it belongs to; there is none in progress.',
      );
    }

    final resolved = resolveImageModelFor(_settings, assistant);
    final binding = resolved.binding;
    if (binding == null) {
      return const ImageJobRefused(
        'image_model_not_configured',
        'No image model is configured. Ask the user to pick one in '
            'Settings → Default model → Image model.',
      );
    }
    // A text model can be stored in the drawing row by an import or a sync even
    // though no picker offers it. Refusing here names the problem, instead of
    // spending a provider round-trip on a chat model that was never going to
    // return a picture.
    if (!SettingsProvider.canDrawPictures(
      _settings.getProviderConfig(binding.providerId),
      binding.modelId,
    )) {
      return const ImageJobRefused(
        'image_model_cannot_draw',
        'That model cannot draw pictures. Ask the user to pick an image model '
            'in Settings → Default model → Image model.',
      );
    }

    final references = <ImageReference>[];
    if (referenceImageIds.isNotEmpty) {
      final known = <String, ImagePart>{};
      for (final message in _chat.getMessages(conversationId)) {
        for (final part in message.parts) {
          if (part is! ImagePart || part.state != null) continue;
          if (part.unavailable) continue;
          final key = (part.assetId ?? '').trim();
          if (key.isNotEmpty) known[key] = part;
        }
      }
      for (final raw in referenceImageIds) {
        final id = raw.trim();
        if (id.isEmpty) continue;
        final part = known[id];
        if (part == null) {
          return const ImageJobRefused(
            'reference_not_in_conversation',
            'Only images from this conversation can be referenced.',
          );
        }
        references.add(ImageReference(uri: part.uri, mime: part.mime));
      }
    }

    final idemKey = _idempotencyKey(
      conversationId: conversationId,
      messageId: targetMessageId,
      toolCallId: toolCallId,
      prompt: text,
      aspectRatio: aspectRatio,
      references: referenceImageIds,
    );
    final existing = manager.byId(idemKey);
    if (existing != null) {
      // Same call, same picture: a re-render or a remount must not pay twice.
      return ImageJobStarted(existing);
    }

    final assetId = _assetIdFor(idemKey);
    final uri = await _allocateAsset(assetId);
    final job = manager.create(
      idempotencyKey: idemKey,
      conversationId: conversationId,
      messageId: targetMessageId,
      toolCallId: toolCallId,
      prompt: text,
      assetId: assetId,
      uri: uri,
      aspectRatio: aspectRatio,
    );
    _bindings[job.id] = binding;
    _references[job.id] = references;
    manager.start(job.id);
    return ImageJobStarted(job);
  }

  /// The model that will draw the next picture, for the panel header.
  ModelBinding? bindingFor(String jobId) => _bindings[jobId];

  /// `providerId::modelId` the job resolved to, in the spelling the panel reads
  /// back after a restart.
  String? _modelKeyFor(ImageJob job) {
    final binding = _bindings[job.id];
    return binding == null ? null : '${binding.providerId}::${binding.modelId}';
  }

  @override
  void dispose() {
    manager
      ..removeListener(_mirror)
      ..dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Running one picture
  // -------------------------------------------------------------------------

  Future<ImageJobOutcome> _run(ImageJob job) async {
    final binding = _bindings[job.id];
    if (binding == null) {
      throw StateError('no model binding for job ${job.id}');
    }
    final config = _settings.getProviderConfig(binding.providerId);
    final backend = _backendFactory(config, binding.modelId);
    final result = await backend.generate(
      ImageGenerationRequest(
        prompt: job.prompt,
        aspectRatio: job.aspectRatio,
        references: _references[job.id] ?? const <ImageReference>[],
      ),
    );
    await _writeBytes(job.uri, result.bytes);
    return ImageJobOutcome(
      uri: job.uri,
      assetId: job.assetId,
      mime: result.mime,
    );
  }

  /// Every transition passes through here exactly once (the manager notifies
  /// only on a real state change), so the mirror cannot disagree with the job.
  void _mirror() {
    var changed = false;
    for (final job in manager.jobs) {
      if (_written[job.id] == job.state) continue;
      _written[job.id] = job.state;
      unawaited(_persist(_partFor(job)));
      changed = true;
    }
    if (changed) notifyListeners();
  }

  ImagePart _partFor(ImageJob job) {
    final state = switch (job.state) {
      ImageJobState.completed => null,
      ImageJobState.failed => ImagePartState.failed,
      ImageJobState.queued || ImageJobState.running => ImagePartState.pending,
    };
    return ImagePart(
      uri: job.resultUri ?? job.uri,
      // The real type, so a JPEG/WebP is not re-sent to a model as `image/png`
      // just because the promised path ends in `.png`.
      mime: job.mime,
      assetId: job.assetId,
      jobId: job.id,
      state: state,
      prompt: job.prompt,
      model: _modelKeyFor(job),
      failureReason: state == ImagePartState.failed ? job.error : null,
      // Kept on the part, not only in the job: the job map dies with the
      // process, and the header should still say how long it took.
      durationMs: _durationOf(job)?.inMilliseconds,
    );
  }

  Duration? _durationOf(ImageJob job) {
    final finished = job.finishedAt;
    final started = job.startedAt ?? job.createdAt;
    if (finished == null) return null;
    return finished.difference(started);
  }

  /// The authoritative shape of a reply's parts, for a writer about to commit
  /// them.
  ///
  /// A reply is written from a snapshot taken while it streamed, so a picture
  /// that finished between the snapshot and the commit comes back as `pending`.
  /// Nothing would repair that afterwards: the mirror has already recorded
  /// `completed`, and no further transition is coming — so the picture would be
  /// skipped by every outbound walk (no bytes) and read as "interrupted" after a
  /// restart, while its file sits on disk. The renderer's rule applies to the
  /// writer too: a live job's state beats a frozen copy.
  List<MessagePart> freshenParts(List<MessagePart> parts) =>
      freshenImageParts(parts, manager.byId, _partFor);

  /// Replace the part carrying this asset, or append it when the message has
  /// none yet.
  ///
  /// Writes for one message are chained, never concurrent. `_persist` rebuilds
  /// the *whole* parts list, so two transitions of the same reply that both read
  /// the same pre-image would each write a list that omits the other's part — and
  /// `_mirror`'s dedupe (`_written[job.id] == job.state`) means nothing would
  /// ever put the missing one back. Chaining makes the second read see the first
  /// write. Residual window: the streaming reply writes its own parts outside this
  /// chain, so a chunk landing between our read and our write can still be
  /// overwritten by our (slightly older) snapshot.
  Future<void> _persist(ImagePart part) {
    final jobId = part.jobId;
    final job = jobId == null ? null : manager.byId(jobId);
    if (job == null) return Future<void>.value();
    final messageId = job.messageId;
    final conversationId = job.conversationId;
    return _writes
        .run(messageId, () => _writePart(conversationId, messageId, part))
        .catchError((Object error) {
          // A failed write must not leave the dedupe claiming this state was
          // persisted: clearing it lets the next notify try again.
          _written.remove(jobId);
        });
  }

  /// One chain per message id, so two transitions of the same reply cannot write
  /// a parts list built from the same pre-image.
  final SerialQueue _writes = SerialQueue();

  Future<void> _writePart(
    String conversationId,
    String messageId,
    ImagePart part,
  ) async {
    // Read *inside* the chain: this is the list that is actually stored now.
    final message = _messageById(conversationId, messageId);
    if (message == null) return;
    final next = <MessagePart>[];
    var replaced = false;
    for (final existing in message.parts) {
      if (existing is ImagePart && existing.assetId == part.assetId) {
        next.add(part);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) next.add(part);
    if (listEquals(next, message.parts)) return;
    await _chat.updateMessage(messageId, parts: next);
  }

  ChatMessage? _messageById(String conversationId, String messageId) {
    for (final message in _chat.getMessages(conversationId)) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  /// The assistant reply that is being generated right now.
  ///
  /// A tool call only ever runs inside one, so the streaming flag is the honest
  /// answer; the newest assistant message is the fallback for a tool that runs
  /// just after the row stopped being marked streaming.
  String? _generatingAssistantMessageId(String conversationId) {
    final messages = _chat.getMessages(conversationId);
    for (final message in messages.reversed) {
      if (message.role == 'assistant' && message.isStreaming) return message.id;
    }
    for (final message in messages.reversed) {
      if (message.role == 'assistant') return message.id;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Files and ids
  // -------------------------------------------------------------------------

  /// The promised path, fixed before the first byte exists.
  ///
  /// It keeps a `.png` name whatever the backend returns: the model already
  /// wrote this exact uri into the reply, so the bytes must land here and
  /// nowhere else. Decoding goes by content, and the part carries the real mime.
  Future<String> _allocateAsset(String assetId) async {
    final dir = await AppDirectories.getImagesDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final path = '${dir.path}${Platform.pathSeparator}$assetId.png';
    return SandboxPathResolver.canonicalize(path);
  }

  Future<void> _writeBytes(String uri, Uint8List bytes) async {
    final path = SandboxPathResolver.fix(uri);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// Stable across re-renders, distinct per explicit retry.
  String _idempotencyKey({
    required String conversationId,
    required String messageId,
    required String toolCallId,
    required String prompt,
    String? aspectRatio,
    required List<String> references,
  }) {
    final parts = <String>[
      conversationId,
      messageId,
      toolCallId,
      prompt,
      aspectRatio ?? 'auto',
      ...references,
    ];
    return sha256.convert(utf8.encode(parts.join('\u0000'))).toString();
  }

  /// `img_` + 20 hex, the same shape every other image handle in the app has.
  String _assetIdFor(String idempotencyKey) =>
      'img_${sha256.convert(utf8.encode(idempotencyKey)).toString().substring(0, 20)}';
}

/// [freshenParts]'s rule, pure: hand it the parts and how to answer "what does
/// this job say now" and it returns the list a writer should commit.
///
/// Kept out of the coordinator so it can be tested without a `ChatService`; the
/// interesting cases are all about disagreement, not about the wiring.
List<MessagePart> freshenImageParts(
  List<MessagePart> parts,
  ImageJob? Function(String jobId) jobFor,
  ImagePart Function(ImageJob job) partFor,
) {
  var changed = false;
  final out = <MessagePart>[];
  for (final part in parts) {
    final jobId = part is ImagePart ? part.jobId : null;
    final job = jobId == null ? null : jobFor(jobId);
    if (job == null) {
      out.add(part);
      continue;
    }
    final live = partFor(job);
    if (live.state == (part as ImagePart).state &&
        live.uri == part.uri &&
        live.mime == part.mime) {
      out.add(part);
      continue;
    }
    // The job wins: the snapshot is older than the state it describes.
    out.add(live);
    changed = true;
  }
  return changed ? out : parts;
}
