/// What one push can carry: the wire size of a JSON document, and the
/// conversations a round's budget admits.
///
/// The receiving side counts the *decompressed* request body
/// (`sync_server.dart`), so the number that matters is the UTF-8 length of
/// `jsonEncode(body)` — the same expression `SyncClient._writeJson` sends.
/// Two things follow, and both are easy to get wrong: a count of Dart code
/// units is wrong for every non-ASCII string (one CJK character is one unit and
/// three bytes), and a second sizing formula beside this one is a second thing
/// to keep in step with the serialisation.
library;

import 'dart:convert';

import 'sync_models.dart';

/// The wire size of [json], exactly as the client serialises it.
int wireBytesOf(Object? json) => utf8LengthOf(jsonEncode(json));

/// The wire size of one conversation's subtree.
int conversationWireBytes(SyncSubtreePayload subtree) =>
    wireBytesOf(subtree.toJson());

/// The UTF-8 length of [text], counted without materialising the bytes.
///
/// `utf8.encode(text).length` allocates a whole second copy of the encoding —
/// per conversation, on top of the row maps already in memory — which is the
/// cost the budget exists to avoid paying twice. `jsonEncode` leaves non-ASCII
/// unescaped, so the count walks the code units: one byte below 0x80, two below
/// 0x800, four for a surrogate pair, three for everything else. A lone
/// surrogate cannot reach here (the encoder escapes those), and is counted as
/// the three bytes of the replacement character anyway.
int utf8LengthOf(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
      final next = text.codeUnitAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/// The bytes a push carries whatever its conversation list turns out to be: the
/// business rows, the asset manifest, the skill hashes and the workspace tables.
///
/// Measured as a batch with **no** subtrees, because that is the part
/// [admitConversations] adds to. One function builds it, so the arithmetic
/// [admitConversations] relies on cannot drift from what the sender serialises.
int pushEnvelopeBytes({
  required SyncBusinessPayload business,
  required List<SyncBlobEntry> assets,
  required Map<String, String> skillHashes,
  required SyncWorkspaceFileTables workspaceFiles,
}) => wireBytesOf(
  SyncDeltaBatch(
    const [],
    business: business,
    assets: assets,
    skillHashes: skillHashes,
    workspaceFiles: workspaceFiles,
  ).toJson(),
);

/// Throws when [batch] serialises past [budget] bytes.
///
/// The admission rule is only as good as the pair it joins: the list it
/// *measured* and the list the sender *built*. This is the half that watches
/// the pair — `sync_engine.dart` calls it, inside an `assert`, on the very batch
/// about to leave — so an edit that measures one set and sends another fails on
/// the sender instead of as a 413 on the peer, which stalls the pair for good.
/// The encode is a second copy of a body that can reach the budget, which is why
/// it lives behind the assert (release strips it) and why it is a function of its
/// own: a guard nobody can test is a guard nobody checks.
///
/// [envelopeBytes] is the measured fixed part of the same push, and it makes the
/// promise honest rather than paranoid. The fixed part is measured, not capped
/// (ADR-0003): when it alone is past the budget, admission can admit nothing and
/// the body *is* that part — a state only the receiving side's 256 MB cap may
/// refuse. The bound then becomes "no larger than the fixed part", so a debug
/// build does not fail a round release would have let the peer answer.
void assertPushFits(SyncDeltaBatch batch, int budget, {int? envelopeBytes}) {
  final bytes = wireBytesOf(batch.toJson());
  final fixedPart = envelopeBytes ?? 0;
  final bound = fixedPart > budget ? fixedPart : budget;
  if (bytes > bound) {
    throw StateError('push body $bytes B exceeds the $bound B budget');
  }
}

/// [planned] minus the conversations one push cannot carry, in plan order.
///
/// [envelopeBytes] is [pushEnvelopeBytes] of the same push. The identity this
/// rests on is exact: a body holding `k` subtrees is
/// `envelope + Σ(size + 1) − 1` — the `+ 1` is each subtree's separating comma,
/// the `− 1` the empty `[]` the envelope carried instead — so a list whose
/// sizes add up to no more than `budgetBytes - envelopeBytes` cannot serialise
/// past the budget. The bound is arithmetic, not headroom.
///
/// Order is the plan's, because a stable order is what makes "not this round,
/// next round" predictable. An over-budget conversation is *skipped rather than
/// ending the walk*: the conversations behind it still ride, and it is retried
/// with its checkpoint untouched. One larger than [perConversationBytes] cannot
/// ride in any round and is skipped the same way — that is the bound that keeps
/// one huge conversation from displacing every other one, round after round.
({List<SyncSubtreePayload> admitted, Set<String> omitted}) admitConversations({
  required List<SyncSubtreePayload> planned,
  required int envelopeBytes,
  required int budgetBytes,
  required int perConversationBytes,
}) {
  final admitted = <SyncSubtreePayload>[];
  final omitted = <String>{};
  var remaining = budgetBytes - envelopeBytes;
  for (final subtree in planned) {
    final id = subtree.conversation['id'] as String;
    final bytes = conversationWireBytes(subtree) + 1;
    if (bytes > perConversationBytes || bytes > remaining) {
      omitted.add(id);
      continue;
    }
    remaining -= bytes;
    admitted.add(subtree);
  }
  return (admitted: admitted, omitted: omitted);
}
