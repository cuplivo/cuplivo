abstract interface class ChatTranscriptViewport {
  bool get isReady;
  bool get isNearBottom;
  bool get isUserScrolling;
  String? get firstVisibleMessageId;

  Future<void> scrollToMessage(String messageId, {String block = 'nearest'});

  Future<void> scrollToTop();

  Future<void> scrollToBottom();
}
