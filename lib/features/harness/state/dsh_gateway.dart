import '../models/dsh_remote.dart';
import 'dsh_gateway_models.dart';

export 'dsh_gateway_models.dart';

/// One remote's live link, as the UI state layer and the later home/chat
/// slices use it.
///
/// This file is the *seam*, not the implementation: it deliberately imports no
/// protocol code, and the pure-Dart client under `lib/core/dsh/` is adapted to
/// it in `lib/features/harness/services/`. That keeps the feature layer
/// testable with fakes and keeps `lib/core/dsh/` Flutter-free in both
/// directions.
///
/// Contract for an implementation:
/// - [connect] performs the full login state machine (launch token when
///   present, otherwise the stored cookie) and resolves only once the link is
///   usable; every user-actionable failure is a [DshGatewayException].
/// - [updates] is a broadcast stream of catalog patches and session-control
///   projections for the current generation. A reconnect re-delivers a
///   baseline (a full catalog or a full session snapshot), never a resume —
///   the client's generation contract makes replay impossible.
/// - [disconnect] closes sockets/streams; it is safe to call twice and safe
///   after a failed connect.
/// - Every mutation throws [DshGatewayException] when the link is not ready or
///   the server refuses the call.
abstract interface class DshGateway {
  /// Logs in and returns the first catalog snapshot.
  ///
  /// Exactly one of [launchToken] (a fresh WebUI link) and [storedCookie] (a
  /// reconnect) is normally provided; a cookie wins when both are present.
  Future<DshConnectResult> connect({
    required DshRemote remote,
    String? launchToken,
    String? storedCookie,
  });

  /// Closes the live link. Idempotent.
  Future<void> disconnect();

  /// Reconnects a link that failed after it was ready (a dropped WebSocket, a
  /// server restart) reusing the stored cookie. Emits through
  /// [linkStatusStream]; throws [DshGatewayException] when it cannot retry.
  Future<void> retry();

  /// Link state changes caused by the adapter itself (reconnect, stale,
  /// server-initiated close). The provider mirrors them into its per-remote
  /// status, which is what widgets watch.
  Stream<DshLinkStatus> get linkStatusStream;

  /// Catalog patches and session-control projections for this connection.
  Stream<DshRemoteUpdate> get updates;

  /// Re-reads the whole catalog on a live link (after a server-side change or
  /// after a [DshCatalogInvalidated] patch).
  Future<DshCatalogSnapshot> refreshCatalog();

  /// Writes one of the two general settings the brief exposes.
  Future<void> updateGeneralSettings(DshGeneralSettings settings);

  /// Creates a remote session (R5's `新会话` / a newly tapped owner with no
  /// history).
  Future<DshSessionSummary> createSession({String? workspaceId, String? cwd});

  /// Renames a session (title projection write).
  Future<void> renameSession(String sessionId, String title);

  /// Pins/unpins a session in its workspace.
  Future<void> setSessionPinned(String sessionId, {required bool pinned});

  /// Archives/unarchives a session. DSH has no delete-session RPC.
  Future<void> setSessionArchived(String sessionId, {required bool archived});

  /// Opens one remote session for the chat slice. The caller owns the returned
  /// handle and must close it.
  Future<DshSessionHandle> openSession(String sessionId);

  /// Lists one directory of the session's workspace (right rail 工作区文件).
  Future<List<DshFileEntry>> listFiles(String sessionId, String path);

  /// Reads a text file for the right-rail preview.
  Future<String> readTextFile(String sessionId, String path);

  /// Stats one path before previewing it.
  Future<DshFileStat> statFile(String sessionId, String path);

  /// Reads raw bytes (image/binary preview). Not every host exposes it; a
  /// [DshFailure.unsupported] means the preview should fall back to text.
  Future<List<int>> readFileBytes(String sessionId, String path);
}

/// One open remote session: the seam the chat slice drives.
///
/// The adapter folds the protocol projection into a full [DshSessionView] on
/// every update, so a controller replaces its state and repaints instead of
/// replaying deltas. A reconnect emits a fresh snapshot view; the chat slice
/// never has to resume anything.
abstract interface class DshSessionHandle {
  /// The server's session id; never converted to a Cuplivo id.
  String get sessionId;

  /// The latest complete view (usable before [views] emits).
  DshSessionView? get current;

  /// Broadcast view stream; one emission per applied update.
  Stream<DshSessionView> get views;

  /// Sends a prompt. [mode] chooses queue vs. steer while a turn is running.
  Future<void> prompt(
    String text, {
    DshPromptMode mode = DshPromptMode.queue,
    List<DshPromptAttachment> attachments = const <DshPromptAttachment>[],
  });

  /// Cancels the running turn.
  Future<void> cancel();

  /// Selects the session's next model/reasoning effort.
  Future<void> selectModel(DshModelSelection selection);

  /// Persists a model as the default for new sessions (DSH
  /// `initializeDefaultModel`).
  Future<void> initializeDefaultModel(DshModelSelection selection);

  /// Applies a permission preset through the server's command path.
  Future<void> runPermissionCommand(String presetId);

  /// Answers a pending approval.
  Future<void> answerApproval(
    DshApprovalRequest request, {
    required bool approved,
    String? note,
  });

  /// Answers a pending host question.
  Future<void> answerQuestions(
    DshQuestionRequest request,
    List<DshQuestionAnswer> answers,
  );

  /// Declines a pending host question with a machine-readable reason.
  Future<void> rejectQuestions(
    DshQuestionRequest request, {
    String message = 'declined',
  });

  /// Pages the transcript backwards; new entries arrive through [views] once
  /// the projection has folded them.
  Future<void> loadOlder();

  /// Stops the live subscription for this handle. Idempotent.
  Future<void> close();
}

/// Creates the gateway for one remote id.
///
/// Injected into `DshConnectionsProvider`; the app passes the protocol adapter
/// factory from `lib/features/harness/services/` once the client lands, and
/// `null` until then (connecting then fails with
/// [DshFailure.notConfigured] instead of pretending to work).
typedef DshGatewayFactory = DshGateway Function(String remoteId);
