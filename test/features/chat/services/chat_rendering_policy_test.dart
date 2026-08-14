import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/services/chat_rendering_policy.dart';

void main() {
  final normal = Conversation(title: 'normal');
  final group = Conversation(
    title: 'group',
    conversationKind: Conversation.kindGroup,
  );

  test('native preference is always effective', () {
    for (final platform in TargetPlatform.values) {
      expect(
        ChatRenderingPolicy.effectiveEngine(
          requested: ChatRenderingEngine.native,
          platform: platform,
          conversation: normal,
          hasMultiAiContent: false,
          hasInteractiveTool: false,
          rendererFailed: false,
        ),
        ChatRenderingEngine.native,
      );
    }
  });

  test('WebView is eligible only on first-release platforms', () {
    for (final platform in const <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      expect(
        ChatRenderingPolicy.effectiveEngine(
          requested: ChatRenderingEngine.webView,
          platform: platform,
          conversation: normal,
          hasMultiAiContent: false,
          hasInteractiveTool: false,
          rendererFailed: false,
        ),
        ChatRenderingEngine.webView,
      );
    }
    for (final platform in const <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      expect(
        ChatRenderingPolicy.effectiveEngine(
          requested: ChatRenderingEngine.webView,
          platform: platform,
          conversation: normal,
          hasMultiAiContent: false,
          hasInteractiveTool: false,
          rendererFailed: false,
        ),
        ChatRenderingEngine.native,
      );
    }
  });

  test('unsupported conversation states use native', () {
    for (final state
        in <
          ({
            Conversation? conversation,
            bool failed,
            bool interactive,
            bool multiAi,
          })
        >[
          (
            conversation: group,
            failed: false,
            interactive: false,
            multiAi: false,
          ),
          (
            conversation: normal,
            failed: false,
            interactive: false,
            multiAi: true,
          ),
          (
            conversation: normal,
            failed: true,
            interactive: false,
            multiAi: false,
          ),
          (
            conversation: normal,
            failed: false,
            interactive: true,
            multiAi: false,
          ),
          (
            conversation: null,
            failed: false,
            interactive: false,
            multiAi: false,
          ),
        ]) {
      expect(
        ChatRenderingPolicy.effectiveEngine(
          requested: ChatRenderingEngine.webView,
          platform: TargetPlatform.android,
          conversation: state.conversation,
          hasMultiAiContent: state.multiAi,
          hasInteractiveTool: state.interactive,
          rendererFailed: state.failed,
        ),
        ChatRenderingEngine.native,
      );
    }
  });
}
