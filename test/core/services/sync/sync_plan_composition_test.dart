import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_merge.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';

/// The order in which [SyncEngine.composeConversationPlan] applies its three
/// rules — the plan table, the peer's "I could not apply this", the peer's
/// announced deletions, and the bulk-replacement override. All four talk about
/// the same absence, and two of them disagree on purpose, so the order *is* the
/// behaviour.
///
/// The rule the order protects: the epoch override rewrites every `iDelete`, and
/// an announced deletion is itself an `iDelete`. Applying announcements first
/// would let the override turn a deletion the peer really made back into a push
/// of the row it deleted.
void main() {
  SyncManifestEntry entry(String digest) =>
      SyncManifestEntry(updatedAtUs: 10, messageCount: 1, digest: digest);
  SyncManifest manifest(Map<String, SyncManifestEntry> conversations) =>
      SyncManifest(conversations);
  SyncCheckpoint agreed(Map<String, SyncManifestEntry> like) => SyncCheckpoint({
    for (final conversation in like.entries)
      conversation.key: SyncCheckpointConversation(
        updatedAtUs: conversation.value.updatedAtUs,
        digest: conversation.value.digest,
        rows: const {},
      ),
  });

  SyncConvAction action({
    required SyncManifest mine,
    required SyncManifest peers,
    required SyncCheckpoint checkpoint,
    Set<String> peerUnapplied = const {},
    Map<String, SyncAnnouncedDeletion> announced = const {},
    bool peerReplaced = false,
  }) => SyncEngine.composeConversationPlan(
    mine: mine,
    peers: peers,
    checkpoint: checkpoint,
    peerUnapplied: peerUnapplied,
    announced: announced,
    peerReplaced: peerReplaced,
  ).single.action;

  final empty = manifest(const {});
  final mineHasX = manifest({'x': entry('d1')});
  final peerHasX = manifest({'x': entry('d1')});
  final agreedX = agreed({'x': entry('d1')});
  final announcedX = <String, SyncAnnouncedDeletion>{
    'x': SyncAnnouncedDeletion(digest: 'd1', updatedAtUs: 10),
  };

  test('the table deletes a copy the peer lost', () {
    expect(
      action(mine: mineHasX, peers: empty, checkpoint: agreedX),
      SyncConvAction.iDelete,
    );
  });

  test('a replaced peer turns that deletion into a re-send', () {
    expect(
      action(
        mine: mineHasX,
        peers: empty,
        checkpoint: agreedX,
        peerReplaced: true,
      ),
      SyncConvAction.iSend,
      reason:
          'the peer was bulk-replaced, so its absence is a dropped row: '
          'deleting our copy would destroy the only one left',
    );
  });

  test('an announced deletion outranks the replacement override', () {
    expect(
      action(
        mine: mineHasX,
        peers: empty,
        checkpoint: agreedX,
        announced: announcedX,
        peerReplaced: true,
      ),
      SyncConvAction.iDelete,
      reason:
          'the peer said it deleted x. The override cannot tell that from an '
          'absence, so applying announcements after it is what keeps a real '
          'deletion from being pushed back',
    );
  });

  test('without a replacement the announcement still deletes', () {
    expect(
      action(
        mine: mineHasX,
        peers: empty,
        checkpoint: agreedX,
        announced: announcedX,
      ),
      SyncConvAction.iDelete,
    );
  });

  test('the override leaves a deletion this device made alone', () {
    expect(
      action(
        mine: empty,
        peers: peerHasX,
        checkpoint: agreedX,
        peerReplaced: true,
      ),
      SyncConvAction.peerDeletes,
      reason:
          'this device deleted x: it plans peerDeletes and the peer learns of it '
          'through the announcement, which the override never touches',
    );
  });

  test('a row the peer never applied is re-sent, not read as a deletion', () {
    expect(
      action(
        mine: mineHasX,
        peers: empty,
        checkpoint: agreedX,
        peerUnapplied: const {'x'},
      ),
      SyncConvAction.iSend,
    );
  });

  test('both flags together: the announcement still wins', () {
    expect(
      action(
        mine: mineHasX,
        peers: empty,
        checkpoint: agreedX,
        peerUnapplied: const {'x'},
        announced: announcedX,
        peerReplaced: true,
      ),
      SyncConvAction.iDelete,
      reason:
          'the peer both failed to apply it and says it deleted it; the '
          'deletion is the later fact',
    );
  });
}
