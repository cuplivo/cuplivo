import 'package:Cuplivo/core/services/sync/sync_merge.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The workspace content decision table, exercised as a pure function: both
/// devices run this same code over the same three views (their own index, the
/// peer's table, the ledger), so every case here is also a statement about what
/// the *other* side computes.
void main() {
  const me = 'device-a';
  const peer = 'device-b';

  WorkspaceFileStamp stamp(int size, int mtimeMs) =>
      WorkspaceFileStamp(size: size, mtimeMs: mtimeMs);

  SyncAgreedFile agreed(WorkspaceFileStamp mine, WorkspaceFileStamp theirs) =>
      SyncAgreedFile(mine, theirs);

  WorkspaceFileAction actionOf(List<WorkspaceFilePlan> plan, String path) =>
      plan.firstWhere((item) => item.path == path).action;

  List<WorkspaceFilePlan> plan({
    Map<String, WorkspaceFileStamp> mine = const {},
    Map<String, WorkspaceFileStamp> peers = const {},
    Map<String, SyncAgreedFile> baseline = const {},
    String myDeviceId = me,
    String peerDeviceId = peer,
  }) => planWorkspaceContent(
    mine: mine,
    peers: peers,
    baseline: baseline,
    myDeviceId: myDeviceId,
    peerDeviceId: peerDeviceId,
  );

  group('planWorkspaceContent', () {
    test('a file both sides hold identically is nothing', () {
      final plans = plan(
        mine: {'a.txt': stamp(3, 100)},
        peers: {'a.txt': stamp(3, 100)},
      );
      expect(actionOf(plans, 'a.txt'), WorkspaceFileAction.none);
    });

    test('a file only this device has is offered, never deleted anywhere', () {
      // No ledger entry: the peer may never have had it, which is the only
      // reading under which a file may not be deleted.
      expect(
        actionOf(plan(mine: {'a.txt': stamp(3, 100)}), 'a.txt'),
        WorkspaceFileAction.iSend,
      );
    });

    test('a file only the peer has is fetched', () {
      expect(
        actionOf(plan(peers: {'a.txt': stamp(3, 100)}), 'a.txt'),
        WorkspaceFileAction.peerSends,
      );
    });

    test('one changed side moves, and the other awaits it', () {
      final baseline = {'a.txt': agreed(stamp(3, 100), stamp(3, 100))};
      expect(
        actionOf(
          plan(
            mine: {'a.txt': stamp(3, 200)},
            peers: {'a.txt': stamp(3, 100)},
            baseline: baseline,
          ),
          'a.txt',
        ),
        WorkspaceFileAction.iSend,
        reason: 'this device edited it: the peer has to come and get it',
      );
      expect(
        actionOf(
          plan(
            mine: {'a.txt': stamp(3, 100)},
            peers: {'a.txt': stamp(4, 100)},
            baseline: baseline,
          ),
          'a.txt',
        ),
        WorkspaceFileAction.peerSends,
        reason: 'the peer edited it: this device fetches it',
      );
    });

    test('both changed is decided by mtime, and a tie by deviceId', () {
      final baseline = {'a.txt': agreed(stamp(3, 100), stamp(3, 100))};
      Map<String, WorkspaceFileStamp> both(int mineMtime, int peerMtime) => {
        'a.txt': stamp(3, mineMtime),
      };
      // Mine newer / peer newer.
      expect(
        actionOf(
          plan(
            mine: both(300, 100),
            peers: {'a.txt': stamp(3, 200)},
            baseline: baseline,
          ),
          'a.txt',
        ),
        WorkspaceFileAction.iWin,
      );
      expect(
        actionOf(
          plan(
            mine: both(200, 100),
            peers: {'a.txt': stamp(3, 300)},
            baseline: baseline,
          ),
          'a.txt',
        ),
        WorkspaceFileAction.peerWins,
      );
      // Same mtime on both: the higher deviceId wins, and both peers compute
      // the same verdict without talking to each other.
      final tied = plan(
        mine: {'a.txt': stamp(3, 200)},
        peers: {'a.txt': stamp(4, 200)},
        baseline: baseline,
      );
      expect(actionOf(tied, 'a.txt'), WorkspaceFileAction.peerWins);
      final tiedTheOtherWay = plan(
        mine: {'a.txt': stamp(4, 200)},
        peers: {'a.txt': stamp(3, 200)},
        baseline: baseline,
        myDeviceId: peer,
        peerDeviceId: me,
      );
      expect(
        actionOf(tiedTheOtherWay, 'a.txt'),
        WorkspaceFileAction.iWin,
        reason: 'the verdict follows the ids, not the role: device-b wins here',
      );
    });

    test('a deletion is announced by absence, and an edit beats it', () {
      final baseline = {'a.txt': agreed(stamp(3, 100), stamp(3, 100))};
      // Deleted here, unchanged there: the peer deletes.
      expect(
        actionOf(
          plan(peers: {'a.txt': stamp(3, 100)}, baseline: baseline),
          'a.txt',
        ),
        WorkspaceFileAction.peerDeletes,
      );
      // Deleted here, edited there: the edit survives and comes back.
      expect(
        actionOf(
          plan(peers: {'a.txt': stamp(3, 400)}, baseline: baseline),
          'a.txt',
        ),
        WorkspaceFileAction.peerSends,
      );
      // Deleted there, unchanged here: this device deletes.
      expect(
        actionOf(
          plan(mine: {'a.txt': stamp(3, 100)}, baseline: baseline),
          'a.txt',
        ),
        WorkspaceFileAction.iDelete,
      );
      // Deleted there, edited here: this device keeps it and offers it back.
      expect(
        actionOf(
          plan(mine: {'a.txt': stamp(3, 400)}, baseline: baseline),
          'a.txt',
        ),
        WorkspaceFileAction.iSend,
      );
    });

    test('a ledger pair whose halves differ is agreement, not a conflict', () {
      // What a receiver records when its filesystem rounded the mtime it was
      // asked to set: both sides talked about the same bytes with different
      // stamps. Reading this as a conflict would transfer the file back and
      // forth for the life of the pairing.
      final plans = plan(
        mine: {'a.txt': stamp(3, 100)},
        peers: {'a.txt': stamp(3, 140)},
        baseline: {'a.txt': agreed(stamp(3, 100), stamp(3, 140))},
      );
      expect(actionOf(plans, 'a.txt'), WorkspaceFileAction.none);
    });

    test('two identical stamps agree even when the ledger says otherwise', () {
      // The session after a conflict: the winner never advanced its own entry,
      // so its baseline still describes the version both sides had *before* the
      // transfer. Reading that as "both changed again" would transfer the same
      // bytes every session for the life of the pairing.
      final plans = plan(
        mine: {'a.txt': stamp(6, 300)},
        peers: {'a.txt': stamp(6, 300)},
        baseline: {'a.txt': agreed(stamp(3, 100), stamp(3, 100))},
      );
      expect(actionOf(plans, 'a.txt'), WorkspaceFileAction.none);
    });

    test('both sides gone drops the entry', () {
      final plans = plan(
        baseline: {'a.txt': agreed(stamp(3, 100), stamp(3, 100))},
      );
      expect(actionOf(plans, 'a.txt'), WorkspaceFileAction.bothDeleted);
    });

    test('nothing known and nothing on either side is nothing at all', () {
      expect(plan(), isEmpty);
    });
  });

  group('advanceWorkspaceBaseline', () {
    test('agreement is written down, with both stamps', () {
      final mine = {'a.txt': stamp(3, 100)};
      final ledger = advanceWorkspaceBaseline(
        mine: mine,
        peers: const {'a.txt': WorkspaceFileStamp(size: 3, mtimeMs: 140)},
        baseline: const {},
        plan: const [WorkspaceFilePlan('a.txt', WorkspaceFileAction.none)],
        landed: const {},
        deleted: const {},
      );
      expect(ledger['a.txt']!.mine, stamp(3, 100));
      expect(ledger['a.txt']!.peer, stamp(3, 140));
    });

    test('a fetched file is recorded from what actually landed', () {
      final ledger = advanceWorkspaceBaseline(
        mine: const {},
        peers: const {'a.txt': WorkspaceFileStamp(size: 3, mtimeMs: 140)},
        baseline: const {},
        plan: const [WorkspaceFilePlan('a.txt', WorkspaceFileAction.peerSends)],
        landed: const {'a.txt': WorkspaceFileStamp(size: 3, mtimeMs: 96)},
        deleted: const {},
      );
      expect(
        ledger['a.txt']!.mine,
        stamp(3, 96),
        reason: 'the local stamp after landing is the true one',
      );
      expect(ledger['a.txt']!.peer, stamp(3, 140));
    });

    test('a fetch that did not land keeps the previous entry', () {
      final prior = {'a.txt': agreed(stamp(3, 100), stamp(3, 100))};
      final ledger = advanceWorkspaceBaseline(
        mine: const {},
        peers: const {'a.txt': WorkspaceFileStamp(size: 3, mtimeMs: 140)},
        baseline: prior,
        plan: const [WorkspaceFilePlan('a.txt', WorkspaceFileAction.peerSends)],
        landed: const {},
        deleted: const {},
      );
      expect(ledger['a.txt'], prior['a.txt']);
    });

    test('an offer never writes an entry: only the peer can confirm it', () {
      // The send side cannot know whether the fetch landed, and an entry that
      // claimed it did would turn the peer's next silence into a deletion.
      final prior = {'a.txt': agreed(stamp(3, 100), stamp(3, 100))};
      for (final action in [
        WorkspaceFileAction.iSend,
        WorkspaceFileAction.iWin,
        WorkspaceFileAction.peerDeletes,
      ]) {
        final ledger = advanceWorkspaceBaseline(
          mine: const {'a.txt': WorkspaceFileStamp(size: 3, mtimeMs: 500)},
          peers: const {},
          baseline: prior,
          plan: [WorkspaceFilePlan('a.txt', action)],
          landed: const {},
          deleted: const {},
        );
        expect(ledger['a.txt'], prior['a.txt'], reason: '$action');
      }
      final fresh = advanceWorkspaceBaseline(
        mine: const {'a.txt': WorkspaceFileStamp(size: 3, mtimeMs: 500)},
        peers: const {},
        baseline: const {},
        plan: const [WorkspaceFilePlan('a.txt', WorkspaceFileAction.iSend)],
        landed: const {},
        deleted: const {},
      );
      expect(fresh, isEmpty, reason: 'a first offer has no prior to keep');
    });

    test(
      'a delete that happened drops the entry, one that failed keeps it',
      () {
        final prior = {'a.txt': agreed(stamp(3, 100), stamp(3, 100))};
        List<WorkspaceFilePlan> plans() => const [
          WorkspaceFilePlan('a.txt', WorkspaceFileAction.iDelete),
        ];
        final removed = advanceWorkspaceBaseline(
          mine: const {},
          peers: const {},
          baseline: prior,
          plan: plans(),
          landed: const {},
          deleted: const {'a.txt'},
        );
        expect(removed, isEmpty);
        final stuck = advanceWorkspaceBaseline(
          mine: const {'a.txt': WorkspaceFileStamp(size: 3, mtimeMs: 100)},
          peers: const {},
          baseline: prior,
          plan: plans(),
          landed: const {},
          deleted: const {},
        );
        expect(stuck['a.txt'], prior['a.txt']);
      },
    );
  });

  group('capWorkspaceLedger', () {
    Map<String, SyncAgreedFile> table(int entries) => {
      for (var i = 0; i < entries; i++)
        'f$i.txt': agreed(stamp(1, i), stamp(1, i)),
    };

    test('a ledger inside the cap is returned untouched', () {
      final ledger = {'w1': table(2)};
      expect(capWorkspaceLedger(ledger, maxEntries: 4), same(ledger));
    });

    test('past the cap, whole workspaces go — never half of one', () {
      final ledger = {'w1': table(2), 'w2': table(2), 'w3': table(1)};
      final capped = capWorkspaceLedger(ledger, maxEntries: 4);
      expect(capped.keys, ['w1', 'w2']);
      expect(capped['w1']!.length, 2);
    });
  });

  group('the ledger the two sides keep', () {
    // Promoted from the review probe that opened the second round (`probe_review_1030_test.dart`),
    // which refuted the hypothesis "a rounded mtime makes the pair re-transfer
    // forever" and pinned the real dependency instead: only the *puller* can
    // record what the pair agreed, and losing its record re-opens the transfer.
    test('the puller closes the loop, and losing its record re-opens it', () {
      const sent = WorkspaceFileStamp(size: 4096, mtimeMs: 1700000000000);
      const olderOnB = WorkspaceFileStamp(size: 100, mtimeMs: 1699999000000);
      // What B's filesystem makes of the mtime A advertised — a coarse-granularity
      // volume rounds it down, so the bytes are A's and the stamp is not.
      const asLandedOnB = WorkspaceFileStamp(
        size: 4096,
        mtimeMs: 1699999998000,
      );

      // Session 1: B holds an older copy, A's version wins, B fetches it.
      final aPlan1 = plan(
        mine: const {'f': sent},
        peers: const {'f': olderOnB},
        baseline: const {},
      );
      expect(actionOf(aPlan1, 'f'), WorkspaceFileAction.iWin);

      // B records the pair it actually reached...
      final bLedger1 = advanceWorkspaceBaseline(
        mine: const {'f': olderOnB},
        peers: const {'f': sent},
        baseline: const {},
        plan: const [WorkspaceFilePlan('f', WorkspaceFileAction.peerWins)],
        landed: const {'f': asLandedOnB},
        deleted: const {},
      );
      expect(bLedger1['f']!.mine, asLandedOnB);
      expect(bLedger1['f']!.peer, sent);

      // ...while A, the sender, records nothing at all: it cannot know the fetch
      // landed. The pair of stamps exists on B's side only — and that is enough,
      // because B is the side that pulls.
      final aLedger1 = advanceWorkspaceBaseline(
        mine: const {'f': sent},
        peers: const {'f': olderOnB},
        baseline: const {},
        plan: aPlan1,
        landed: const {},
        deleted: const {},
      );
      expect(aLedger1, isEmpty);

      // Session 2: A's own plan still says "mine wins" (it never saw the
      // agreement), but B — whose ledger holds the exact pair — plans `none`, and
      // B is the one that would have to fetch. No bytes move, so the rounded
      // stamp costs nothing.
      expect(
        actionOf(
          plan(
            mine: const {'f': sent},
            peers: const {'f': asLandedOnB},
            baseline: aLedger1,
          ),
          'f',
        ),
        WorkspaceFileAction.iWin,
      );
      expect(
        actionOf(
          plan(
            mine: const {'f': asLandedOnB},
            peers: const {'f': sent},
            baseline: bLedger1,
          ),
          'f',
        ),
        WorkspaceFileAction.none,
        reason: 'the puller remembers the pair, so nothing is re-fetched',
      );

      // What losing B's ledger would cost: the same unchanged file is fetched
      // again, and a file B alone still holds is re-offered instead of deleted.
      expect(
        actionOf(
          plan(
            mine: const {'f': asLandedOnB},
            peers: const {'f': sent},
            baseline: const {},
          ),
          'f',
        ),
        WorkspaceFileAction.peerWins,
        reason: 'an absent entry is not an agreement: the file travels again',
      );
      expect(
        actionOf(
          plan(
            mine: const {'f': asLandedOnB},
            peers: const {},
            baseline: const {},
          ),
          'f',
        ),
        WorkspaceFileAction.iSend,
        reason:
            "the peer's deletion reads as \"never had it\": the file returns",
      );
    });
  });
}
