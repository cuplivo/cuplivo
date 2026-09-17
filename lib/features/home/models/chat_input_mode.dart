/// Input chrome mode for the shared chat input bar.
enum ChatInputMode {
  /// Default 1:1 home chat — model / search / reasoning / MCP as usual.
  normal,

  /// Group chat: hide model, search, reasoning, MCP, multi-AI, and
  /// currentAssistant-bound more-panel actions.
  groupChat,
}
