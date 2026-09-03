import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/chat/models/tool_ui_part.dart';
import 'package:Cuplivo/features/chat/widgets/tool_approval_binding.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';

void main() {
  group('pendingApprovalRequestFor', () {
    test('returns the matching request while it is still pending', () {
      final service = ToolApprovalService();
      final future = service.requestApproval(
        toolCallId: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo one'},
      );

      const part = ToolUIPart(
        id: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo one'},
        loading: true,
      );
      final request = pendingApprovalRequestFor(service, part);

      expect(request, isNotNull);
      expect(request!.toolCallId, 'call-1');
      expect(request.toolName, 'shell');

      service.approve('call-1');
      return future;
    });

    test('returns null for a resolved part even when a request pends', () {
      final service = ToolApprovalService();
      service.requestApproval(
        toolCallId: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo one'},
      );

      const part = ToolUIPart(
        id: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo one'},
        content: 'done',
        loading: false,
      );
      final request = pendingApprovalRequestFor(service, part);

      expect(request, isNull);
    });

    test('returns null for an id-less part with a same-named request', () {
      final service = ToolApprovalService();
      service.requestApproval(
        toolCallId: 'shell_1725000000000',
        toolName: 'shell',
        arguments: {'command': 'echo blank'},
      );

      const part = ToolUIPart(
        id: '',
        toolName: 'shell',
        arguments: {'command': 'echo blank'},
        loading: true,
      );
      final request = pendingApprovalRequestFor(service, part);

      expect(request, isNull);
    });

    test('matches a whitespace-padded part id against the trimmed key', () {
      final service = ToolApprovalService();
      service.requestApproval(
        toolCallId: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo padded'},
      );

      const part = ToolUIPart(
        id: ' call-1 ',
        toolName: 'shell',
        arguments: {'command': 'echo padded'},
        loading: true,
      );
      final request = pendingApprovalRequestFor(service, part);

      expect(request, isNotNull);
      expect(request!.toolCallId, 'call-1');
    });

    test('returns null for a non-matching id', () {
      final service = ToolApprovalService();
      service.requestApproval(
        toolCallId: 'call-other',
        toolName: 'shell',
        arguments: {'command': 'echo other'},
      );

      const part = ToolUIPart(
        id: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo one'},
        loading: true,
      );
      final request = pendingApprovalRequestFor(service, part);

      expect(request, isNull);
    });

    test('returns null once the request was resolved', () {
      final service = ToolApprovalService();
      service.requestApproval(
        toolCallId: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo one'},
      );
      service.deny('call-1', 'not now');

      const part = ToolUIPart(
        id: 'call-1',
        toolName: 'shell',
        arguments: {'command': 'echo one'},
        loading: true,
      );
      final request = pendingApprovalRequestFor(service, part);

      expect(request, isNull);
    });
  });
}
