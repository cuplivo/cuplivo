import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/services/tool_approval_service.dart';

void main() {
  group('ToolApprovalService', () {
    test('approve and deny complete the pending request', () async {
      final service = ToolApprovalService();
      final future = service.requestApproval(
        toolCallId: 'call_1',
        toolName: 'kelivo_delete',
        arguments: const {'path': '/tmp/x'},
      );

      expect(service.isPending('call_1'), isTrue);
      service.deny('call_1', 'not now');

      final result = await future.timeout(const Duration(seconds: 1));
      expect(result.approved, isFalse);
      expect(result.denyReason, 'not now');
      expect(service.pendingRequests, isEmpty);
    });

    test(
      'cancelForConversation resolves only matching requests (子代理面板 ✕)',
      () async {
        final service = ToolApprovalService();
        final childFuture = service.requestApproval(
          toolCallId: 'child_call',
          toolName: 'kelivo_delete',
          arguments: const {'path': '/child/x'},
          conversationId: 'child-conv',
        );
        final otherFuture = service.requestApproval(
          toolCallId: 'other_call',
          toolName: 'kelivo_delete',
          arguments: const {'path': '/other/x'},
          conversationId: 'other-conv',
        );

        service.cancelForConversation('child-conv');

        final childResult = await childFuture.timeout(
          const Duration(seconds: 1),
        );
        expect(childResult.approved, isFalse);
        expect(childResult.denyReason, 'cancelled');
        expect(service.pendingRequests.keys, ['other_call']);

        // The other conversation's request stays answerable.
        service.approve('other_call');
        final otherResult = await otherFuture.timeout(
          const Duration(seconds: 1),
        );
        expect(otherResult.approved, isTrue);
      },
    );

    test('cancelForConversation is a no-op when nothing matches', () {
      final service = ToolApprovalService();
      service.requestApproval(
        toolCallId: 'call_1',
        toolName: 'kelivo_delete',
        arguments: const {'path': '/x'},
        conversationId: 'other-conv',
      );

      service.cancelForConversation('missing-conv');

      expect(service.pendingRequests.keys, ['call_1']);
    });
  });
}
