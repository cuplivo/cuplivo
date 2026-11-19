import 'package:Cuplivo/core/services/sync/sync_limits.dart';
import 'package:flutter_test/flutter_test.dart';

/// The limits whose value another limit depends on, and the relationships the
/// module docs claim — `sync_limits.dart`'s library comment names this file as
/// the proof, so it exists and proves them.
///
/// Every assertion states a *relationship*, never the numbers again: raising a
/// base cap must keep the derived ones consistent, and a change that breaks a
/// relationship therefore has to break this file on purpose.
void main() {
  test('the ledger cap is ten workspaces at the per-workspace file cap', () {
    expect(kMaxWorkspaceLedgerEntries, 10 * kMaxWorkspaceFiles);
  });

  test('the listener answers one whole peer fan-out plus spare headroom', () {
    expect(kMaxPingsInFlight, kMaxPeerEndpoints + 2);
    expect(
      kSyncProbeConcurrency,
      kMaxPeerEndpoints,
      reason: 'a peer\'s whole address memory is one probe wave',
    );
    expect(
      kMaxPingsInFlight,
      greaterThanOrEqualTo(kSyncProbeConcurrency),
      reason: 'the asking side must never trip its own listener',
    );
  });

  test('a reverse dial cannot cost more than the address memory', () {
    expect(kMaxReverseDialCandidates, lessThanOrEqualTo(kMaxPeerEndpoints));
  });

  test('one push stays under the body cap the receiving side enforces', () {
    expect(
      kSyncDeltaByteBudget,
      lessThan(kSyncMaxBodyBytes),
      reason: 'the budget is derived from the cap, with room for the send path',
    );
    expect(
      kSyncDeltaBudgetPercent,
      inInclusiveRange(1, 99),
      reason: 'a share of 0 or 100 makes one of the two bounds meaningless',
    );
    expect(kSyncDeltaByteBudget, lessThanOrEqualTo(kSyncMaxBodyBytes));
  });

  test('a conversation is at most half a push, and two of them still fit', () {
    expect(
      kSyncMaxConversationBytes,
      greaterThan(0),
      reason: 'a cap of zero would send nothing at all',
    );
    expect(
      2 * kSyncMaxConversationBytes,
      lessThanOrEqualTo(kSyncDeltaByteBudget),
      reason: 'one conversation may not displace the rest of the round',
    );
  });
}
