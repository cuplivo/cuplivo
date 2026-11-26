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

  test('one page stays under the body cap the receiving side enforces', () {
    expect(
      kSyncPageBytes,
      lessThan(kSyncMaxBodyBytes),
      reason:
          'the page budget is derived from the cap, with room for the send '
          'path',
    );
    expect(
      kSyncPageBudgetPercent,
      inInclusiveRange(1, 99),
      reason: 'a share of 0 or 100 makes one of the two bounds meaningless',
    );
    expect(kSyncPageBytes, greaterThan(0));
  });

  test('a page is small enough to be held several times over', () {
    // The send path holds the page's row maps, its JSON text, its UTF-8 buffer
    // and its gzip buffer at once. The old single-push budget was 60% of the
    // cap because of that multiplication; a page has to be far enough below it
    // that four copies stay ordinary memory on a phone.
    expect(
      kSyncPageBytes * 8,
      lessThanOrEqualTo(kSyncMaxBodyBytes * 2),
      reason: 'eight pages must cost no more than two body caps of memory',
    );
  });
}
