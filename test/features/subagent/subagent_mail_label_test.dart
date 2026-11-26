import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/subagent/widgets/subagent_mail_notice.dart';
import 'package:Cuplivo/l10n/app_localizations_en.dart';

void main() {
  test('the mail label names the sender side in each conversation', () {
    final l10n = AppLocalizationsEn();
    const fromChild = SubagentMailPart(
      from: SubagentMailSender.subagent,
      senderConversationId: 'child-1',
    );
    const fromParent = SubagentMailPart(
      from: SubagentMailSender.delegator,
      senderConversationId: 'parent-1',
    );

    // The child's row lives in the parent: it is the subagent speaking.
    expect(
      subagentMailLabelText(l10n, fromChild, 'auth'),
      'Subagent message · auth',
    );
    // The parent's row lives in the child: calling it a subagent message would
    // invert who spoke.
    expect(
      subagentMailLabelText(l10n, fromParent, 'Chat'),
      'Delegator message · Chat',
    );
    // No conversation title yet: the side alone is still correct.
    expect(subagentMailLabelText(l10n, fromChild, '  '), 'Subagent message');
  });
}
