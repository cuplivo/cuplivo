import '../../models/chat_input_data.dart';

/// A one-shot draft handoff for actions launched outside the chat route.
///
/// Settings pages stage a draft, return to the root chat route, and let the
/// existing HomePage instance create the new conversation and restore it.
class ExternalChatDraftHandoff {
  ExternalChatDraftHandoff._();

  static ChatInputData? _pending;

  static void stage(ChatInputData draft) {
    _pending = draft;
  }

  static ChatInputData? take() {
    final draft = _pending;
    _pending = null;
    return draft;
  }
}
