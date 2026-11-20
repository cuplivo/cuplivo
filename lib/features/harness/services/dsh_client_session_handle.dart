import 'dart:async';
import 'dart:typed_data';

import 'package:Cuplivo/core/dsh/dsh_client.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_errors.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_events.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_models.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_session.dart' as dsh;

import '../state/dsh_gateway.dart';
import 'dsh_client_gateway_mapping.dart';

/// Adapts one followed `DshSessionStore` to the gateway's [DshSessionHandle].
///
/// The client already keeps the authoritative fold (`DshTranscript`: snapshot
/// first, contiguous events, assistant draft, host waterfalls). This class adds
/// only three things: it re-folds `session/control` projection frames into the
/// same transcript (so a title or permission change made from another window is
/// visible without a snapshot), it emits the folded read model as a broadcast
/// stream, and it translates seam calls into the client's prompt/answer RPCs.
class DshClientSessionHandle implements DshSessionHandle {
  DshClientSessionHandle({
    required this.sessionId,
    required this._client,
    required this._store,
    this.onClosed,
  });

  @override
  final String sessionId;

  final dsh.DshClient _client;
  final dsh.DshSessionStore _store;

  /// Told when the caller closes the handle so the gateway can forget it.
  final void Function(String sessionId)? onClosed;

  final StreamController<DshSessionView> _views =
      StreamController<DshSessionView>.broadcast();
  StreamSubscription<void>? _changes;
  DshSessionView? _current;
  DshFailure? _linkFailure;
  bool _closed = false;

  @override
  DshSessionView? get current => _current;

  @override
  Stream<DshSessionView> get views => _views.stream;

  /// Subscribes to the store and emits the first view. Idempotent.
  Future<void> start() {
    if (!_closed) {
      _changes ??= _store.changes.listen((_) => _emit());
      _emit();
    }
    return Future<void>.value();
  }

  void setLinkFailure(DshFailure? failure) {
    if (_closed || _linkFailure == failure) return;
    _linkFailure = failure;
    _emit();
  }

  /// Applied by the gateway for `session/control` projection frames.
  void applyControlChanges(List<dsh.DshSessionControlChange> changes, int seq) {
    if (_closed || changes.isEmpty) return;
    for (final change in changes) {
      _store.transcript.applyProjection(change.key, change.value, seq);
    }
    _emit();
  }

  void _emit() {
    if (_closed || _views.isClosed) return;
    final view = mapDshSessionView(
      sessionId: sessionId,
      store: _store,
      linkFailure: _linkFailure,
    );
    _current = view;
    _views.add(view);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<void> prompt(
    String text, {
    DshPromptMode mode = DshPromptMode.queue,
    List<DshPromptAttachment> attachments = const <DshPromptAttachment>[],
  }) {
    final images = <dsh.DshImageInput>[
      for (final attachment in attachments)
        if (attachment.isImage &&
            attachment.bytes != null &&
            attachment.bytes!.isNotEmpty)
          dsh.DshImageInput(
            bytes: Uint8List.fromList(attachment.bytes!),
            mediaType: attachment.mediaType ?? 'image/png',
            name: attachment.name,
          ),
    ];
    final files = [
      for (final attachment in attachments)
        if (!attachment.isImage && attachment.receiptId.trim().isNotEmpty)
          dsh.DshFileInput(attachment.receiptId),
    ];
    return _run(
      () => _store.prompt(
        dsh.DshPrompt(
          text: text.trim().isEmpty ? null : text,
          images: images,
          files: files,
        ),
        mode: switch (mode) {
          DshPromptMode.queue => 'queue',
          DshPromptMode.steer => 'steer',
        },
      ),
    );
  }

  @override
  Future<DshUploadReceipt> uploadAttachment(
    List<int> bytes, {
    String? name,
    String? mediaType,
  }) async {
    try {
      final receipt = await _store.session.uploadAttachment(
        Uint8List.fromList(bytes),
        name: name,
        mediaType: mediaType,
      );
      return DshUploadReceipt(
        receiptId: receipt.receiptId,
        name: receipt.file?.name ?? receipt.image?.name ?? name,
        mediaType: receipt.image?.mediaType ?? mediaType,
        width: receipt.image?.width,
        height: receipt.image?.height,
      );
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<List<int>> attachmentBytes(DshPromptAttachment attachment) async {
    try {
      final bytes = await _store.session.attachmentBytes(
        dsh.DshImageAttachment(
          attachmentId: attachment.receiptId,
          mediaType: attachment.mediaType ?? 'application/octet-stream',
          bytes: attachment.bytes?.length,
          width: attachment.width,
          height: attachment.height,
          name: attachment.name,
        ),
      );
      return bytes;
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<DshCommandOutcome> executeCommand(String line) async {
    try {
      final execution = await _store.session.executeCommand(line);
      return DshCommandOutcome(
        success: execution.result.success,
        text: execution.result.text,
      );
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<void> cancel() => _run(_store.cancel);

  @override
  Future<void> selectModel(DshModelSelection selection) =>
      _run(() => _store.setModel(mapModelSelectionToClient(selection)));

  @override
  Future<void> initializeDefaultModel(DshModelSelection selection) {
    // The protocol's `session/initializeDefaultModel` is a no-argument
    // bootstrap (it only ensures the deployment default selection exists), not
    // a setter. The seam's parameter is therefore ignored; `selectModel` is
    // what changes a session's next model. See gateway-api.md.
    return _run(_client.catalog.initializeDefaultModel);
  }

  @override
  Future<void> runPermissionCommand(String presetId) =>
      _run(() => _store.setPermission(presetId));

  @override
  Future<void> selectAgentPreset(String presetId) => _run(() async {
    await _client.catalog.selectAgentPreset(sessionId, presetId);
  });

  @override
  Future<void> answerApproval(
    DshApprovalRequest request, {
    required bool approved,
    String? note,
  }) {
    // DSH approvals carry only the decision on the wire; there is no note
    // field, so `note` is accepted for seam symmetry and deliberately dropped.
    return _run(
      () => _store.answerApproval(
        request.id,
        approved
            ? dsh.DshApprovalDecision.allowOnce
            : dsh.DshApprovalDecision.reject,
      ),
    );
  }

  @override
  Future<void> answerQuestions(
    DshQuestionRequest request,
    List<DshQuestionAnswer> answers,
  ) {
    return _run(
      () => _store.answerQuestions(
        request.id,
        mapDshQuestionAnswers(request, answers),
      ),
    );
  }

  @override
  Future<void> rejectQuestions(
    DshQuestionRequest request, {
    String message = 'declined',
  }) {
    // 0.2.2 has no decline waterfall; an empty answer list is the closest
    // wire form (the Host fails the waterfall closed). See gateway-api.md.
    return _run(
      () => _store.answerQuestions(request.id, rejectedDshQuestionAnswers()),
    );
  }

  @override
  Future<void> loadOlder() => _run(() async {
    await _store.loadOlder();
  });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes?.cancel();
    _changes = null;
    await _store.dispose();
    await _views.close();
    onClosed?.call(sessionId);
  }
}
