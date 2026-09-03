import '../../home/services/tool_approval_service.dart';
import '../models/tool_ui_part.dart';

/// The approval request (if any) currently pending for [part], or null.
///
/// The pending request is keyed by the same stream tool-call id as the part:
/// each provider passes its per-call id to both the emitted chunk (which
/// becomes [ToolUIPart.id]) and the tool handler (which keys the approval
/// request). Binding strictly by that id — never by tool name — keeps past
/// and parallel same-name tool calls non-interactive.
///
/// A part without an id can never be pending: live parts always carry a
/// non-empty id because every provider synthesizes one, approvals exist only
/// during runtime, and restored messages are never pending.
ToolApprovalRequest? pendingApprovalRequestFor(
  ToolApprovalService approvalService,
  ToolUIPart part,
) {
  if (!part.loading) return null;
  final partId = part.id.trim();
  if (partId.isEmpty) return null;
  return approvalService.pendingRequests[partId];
}
