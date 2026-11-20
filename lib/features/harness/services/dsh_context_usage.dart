import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/home/services/context_usage_service.dart';

/// Maps the Host's `contextPressure` projection to the shared context ring's
/// snapshot.
///
/// DSH reports a single honest pressure number
/// (`{pressureTokens, projectedTokens, contextWindow}`), not Cuplivo's twelve
/// assembled buckets, so this mapping deliberately leaves every bucket at zero
/// and marks the state `exact`: the Host computed the total itself. The ring's
/// ratio and the sheet's two-segment bar (used vs free window) are therefore
/// real values, never a fabricated composition.
///
/// The used value follows the Host's own meter: `projectedTokens` when the
/// projection has one (the next request's expected size), otherwise
/// `pressureTokens` (the current transcript). This is the same precedence the
/// official composer ring applies to the same projection.
///
/// Returns null when the projection is absent or has no window, which hides the
/// ring instead of guessing a denominator.
ContextUsageSnapshot? dshContextUsageSnapshot({
  required DshContextPressure? pressure,
  required String remoteId,
  required String sessionId,
  String? providerKey,
  String? modelId,
  DateTime? computedAt,
}) {
  if (pressure == null || !pressure.hasWindow) return null;
  final window = pressure.contextWindow!;
  if (window <= 0) return null;
  final rawUsed = pressure.projectedTokens ?? pressure.pressureTokens ?? 0;
  final used = rawUsed < 0 ? 0 : rawUsed;
  return ContextUsageSnapshot(
    state: ContextUsageState.exact,
    buckets: const ContextUsageBuckets(),
    usedTokens: used,
    contextWindow: window,
    conversationId: 'dsh:$remoteId:$sessionId',
    revision: 0,
    providerKey: providerKey ?? '',
    modelId: modelId ?? '',
    assistantId: null,
    computedAt: computedAt ?? DateTime.now(),
  );
}
