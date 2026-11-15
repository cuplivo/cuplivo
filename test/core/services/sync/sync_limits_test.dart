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
}
