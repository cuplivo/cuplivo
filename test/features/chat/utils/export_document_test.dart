import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/chat/utils/export_document.dart';

void main() {
  test(
    'a mail row is a divider in the export, never the user’s own message',
    () async {
      final document = await buildExportDocument(
        title: 'Chat',
        messages: [
          ChatMessage(
            id: 'u1',
            role: 'user',
            conversationId: 'c',
            parts: const [TextPart('look at this')],
          ),
          ChatMessage(
            id: 'm1',
            role: 'user',
            conversationId: 'c',
            parts: const [
              SubagentMailPart(
                from: SubagentMailSender.subagent,
                senderConversationId: 'child-1',
              ),
              TextPart('the child found it'),
            ],
          ),
        ],
        roleNameOf: (message) => message.role,
        formatTime: (time) => '12:00',
        includeThinking: false,
        includeTools: false,
        subagentMailLabelOf: (part) => 'Subagent message · auth',
      );

      // The export has the human's message only: the mail row has no speaker here.
      expect(document.messages, hasLength(1));
      expect(
        document.messages.single.blocks.whereType<ExportContextNode>().map(
          (node) => node.text,
        ),
        contains('Subagent message · auth'),
      );
      // And the child's words are not reprinted as the user's.
      expect(
        document.messages
            .expand((message) => message.blocks)
            .whereType<ExportText>()
            .map((block) => block.text),
        isNot(contains('the child found it')),
      );
    },
  );
}
