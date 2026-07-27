import '../../models/director_session.dart';
import '../chat/group_chat_service.dart';

/// Thin facade over [GroupChatService] director session APIs.
///
/// Keeps orchestrator code free of direct service method names and makes
/// unit tests easy to fake.
class DirectorSessionStore {
  DirectorSessionStore(this._service);

  final GroupChatService _service;

  Future<DirectorSession?> get(String groupId) =>
      _service.getDirectorSession(groupId);

  Future<DirectorSession> ensure(String groupId) =>
      _service.ensureDirectorSession(groupId);

  Future<DirectorSession> put(DirectorSession session) =>
      _service.putDirectorSession(session);

  Future<DirectorSession> updateStatus(
    String groupId,
    String status, {
    String? errorText,
    bool clearError = false,
    String? triggerUserMessageId,
    bool clearTrigger = false,
    List<Map<String, dynamic>>? messages,
    Map<String, dynamic>? state,
  }) async {
    final existing = await ensure(groupId);
    return put(
      existing.copyWith(
        status: status,
        errorText: errorText,
        clearErrorText: clearError,
        triggerUserMessageId: triggerUserMessageId,
        clearTriggerUserMessageId: clearTrigger,
        messages: messages,
        state: state,
        updatedAt: DateTime.now(),
      ),
    );
  }
}
