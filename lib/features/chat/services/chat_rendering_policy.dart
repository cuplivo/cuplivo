import 'package:flutter/foundation.dart';

import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';

class ChatRenderingPolicy {
  const ChatRenderingPolicy._();

  static bool supportsWebView(TargetPlatform platform) {
    return platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.macOS;
  }

  static ChatRenderingEngine effectiveEngine({
    required ChatRenderingEngine requested,
    required TargetPlatform platform,
    required Conversation? conversation,
    required bool hasMultiAiContent,
    required bool hasInteractiveTool,
    required bool rendererFailed,
  }) {
    if (requested != ChatRenderingEngine.webView ||
        !supportsWebView(platform) ||
        conversation == null ||
        conversation.conversationKind != Conversation.kindNormal ||
        hasMultiAiContent ||
        hasInteractiveTool ||
        rendererFailed) {
      return ChatRenderingEngine.native;
    }
    return ChatRenderingEngine.webView;
  }
}
