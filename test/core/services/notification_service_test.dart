import 'package:Cuplivo/core/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('proactive care notification payload', () {
    test('round-trips a versioned conversation target', () {
      final result = parseProactiveCareNotificationPayload(
        buildProactiveCareNotificationPayload('conversation-1'),
      );

      expect(result.kind, ProactiveCareNotificationPayloadKind.proactiveCare);
      expect(result.conversationId, 'conversation-1');
    });

    test('rejects malformed proactive payloads', () {
      for (final payload in <String?>[
        null,
        '',
        'not-json',
        '[]',
        '{"type":"proactiveCare","version":2,"conversationId":"c1"}',
        '{"type":"proactiveCare","version":1,"conversationId":""}',
      ]) {
        expect(
          parseProactiveCareNotificationPayload(payload).kind,
          ProactiveCareNotificationPayloadKind.malformed,
          reason: 'payload: $payload',
        );
      }
    });

    test('identifies another notification type as non-proactive', () {
      final result = parseProactiveCareNotificationPayload(
        '{"type":"chatCompletion","version":1}',
      );

      expect(result.kind, ProactiveCareNotificationPayloadKind.nonProactive);
      expect(result.conversationId, isNull);
    });
  });

  group('ProactiveCareNotificationTargetBuffer', () {
    test('keeps one latest target until a consumer is attached', () {
      final buffer = ProactiveCareNotificationTargetBuffer();
      final consumed = <String>[];
      final owner = Object();

      buffer.add('conversation-1');
      buffer.add('conversation-2');
      expect(buffer.pendingConversationId, 'conversation-2');

      buffer.attach(owner, consumed.add);
      expect(consumed, ['conversation-2']);
      expect(buffer.pendingConversationId, isNull);

      buffer.attach(owner, consumed.add);
      expect(consumed, ['conversation-2']);
    });

    test('forwards warm targets once and buffers again after detach', () {
      final buffer = ProactiveCareNotificationTargetBuffer();
      final consumed = <String>[];
      final owner = Object();

      buffer.attach(owner, consumed.add);
      buffer.add('warm-1');
      buffer.add('warm-2');
      expect(consumed, ['warm-1', 'warm-2']);

      buffer.detach(Object());
      buffer.add('warm-3');
      expect(consumed, ['warm-1', 'warm-2', 'warm-3']);

      buffer.detach(owner);
      buffer.add('cold-again');
      expect(buffer.pendingConversationId, 'cold-again');
      expect(consumed, ['warm-1', 'warm-2', 'warm-3']);
    });
  });
}
