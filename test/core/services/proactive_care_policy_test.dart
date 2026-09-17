import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat_conversations.dart';
import 'package:Cuplivo/core/services/proactive_care_conversation_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 8, 1, 12);

  Assistant assistant({bool enabled = true, String id = 'a1'}) =>
      Assistant(id: id, name: 'A', enableProactiveCare: enabled);

  Conversation conversation({
    String id = 'c1',
    String? assistantId = 'a1',
    Map<String, dynamic> extras = const {},
  }) => Conversation(
    id: id,
    title: 'T',
    createdAt: now,
    updatedAt: now,
    assistantId: assistantId,
    extras: extras,
  );

  test('effective enablement: override wins, null inherits', () {
    final a = assistant();
    expect(
      ProactiveCareConversationPolicy.isEffectivelyEnabled(
        conversation(
          extras: const {Conversation.proactiveCareEnabledOverrideKey: false},
        ),
        a,
      ),
      isFalse,
    );
    expect(
      ProactiveCareConversationPolicy.isEffectivelyEnabled(conversation(), a),
      isTrue,
    );
    expect(
      ProactiveCareConversationPolicy.isEffectivelyEnabled(
        conversation(),
        assistant(enabled: false),
      ),
      isFalse,
    );
  });

  test('group conversations are not eligible', () {
    final a = assistant();
    final group = conversation(
      extras: const {GroupChatConversations.extrasKindKey: 'group'},
    );
    expect(ProactiveCareConversationPolicy.isEligible(group, a), isFalse);
  });

  test('other assistants conversations are not eligible', () {
    final a = assistant();
    expect(
      ProactiveCareConversationPolicy.isEligible(
        conversation(assistantId: 'a2'),
        a,
      ),
      isFalse,
    );
  });

  test('pending lists only future schedules of eligible conversations', () {
    final a = assistant();
    final due = conversation(
      id: 'due',
    ).setProactiveCareNextMessageAt(now.add(const Duration(minutes: 10)));
    final past = conversation(
      id: 'past',
    ).setProactiveCareNextMessageAt(now.subtract(const Duration(minutes: 10)));
    final none = conversation(id: 'none');
    final result = ProactiveCareConversationPolicy.pending(
      conversations: [due, past, none],
      assistants: [a],
      now: now,
    );
    expect(result.map((t) => t.conversation.id), ['due']);
    expect(result.single.expectedAt, due.proactiveCareNextMessageAt);
  });

  test('extras-backed state round-trips through setters', () {
    final at = now.add(const Duration(hours: 3));
    final conv = conversation()
        .setProactiveCareEnabledOverride(true)
        .setProactiveCareNextMessageAt(at);
    expect(conv.proactiveCareEnabledOverride, isTrue);
    expect(conv.proactiveCareNextMessageAt, at);

    final cleared = conv
        .setProactiveCareEnabledOverride(null)
        .setProactiveCareNextMessageAt(null);
    expect(cleared.proactiveCareEnabledOverride, isNull);
    expect(cleared.proactiveCareNextMessageAt, isNull);
    // Null-valued keys are stripped so extras stays compact.
    expect(
      cleared.extras.containsKey(Conversation.proactiveCareNextMessageAtKey),
      isFalse,
    );
  });

  test('assistant model proactive fields round-trip via JSON', () {
    final at = now.add(const Duration(hours: 3));
    final a = Assistant(
      id: 'a1',
      name: 'A',
      enableProactiveCare: true,
      proactiveCareNextMessageAt: at,
      proactiveCarePrompt: 'P',
      proactiveCareDecisionPrompt: 'D',
      proactiveCareDecisionHistoryMessageLimit: 12,
    );
    final restored = Assistant.fromJson(a.toJson());
    expect(restored.enableProactiveCare, isTrue);
    expect(restored.proactiveCareNextMessageAt, at);
    expect(restored.proactiveCarePrompt, 'P');
    expect(restored.proactiveCareDecisionPrompt, 'D');
    expect(restored.proactiveCareDecisionHistoryMessageLimit, 12);
  });
}
