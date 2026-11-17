import '../services/sync/sync_family_registry.dart';
import 'composer_draft_store.dart';

/// The `extension_entity_rows` a conversation owns, as one rule read by the three
/// places that act on them: the conversation's delete and a bulk reset remove
/// these rows, and the recycle bin's capture takes the copy that makes a restore
/// possible.
///
/// What a conversation keeps outside its messages — the history of the
/// operations that compressed or cleared its context, the images it pins and how
/// it treats images at all, and its own compression configuration — is deleted
/// with the conversation **and** staged by the bin, because delete-and-restore
/// is supposed to hand the conversation back and these are part of it. Since
/// protocol 9 they also ride the conversation's sync subtree
/// (`syncedConversationFamilies`), so the bin is no longer the *only* way back —
/// but a peer that deleted the conversation, or a restore after the peer's copy
/// was replaced, still needs it.
///
/// The set is derived from the registration, not listed. The registry is where
/// "a conversation owns this kind" is decided, so a second literal here would be
/// the fifth enumeration of one fact: a family added to the registry would
/// travel to peers while the bin neither captured nor deleted it. A synced
/// conversation family with a kind *is* a document — one row per conversation,
/// addressed by that kind.
///
/// A device-local conversation kind is not here, because it does not travel: the
/// bin is its only way back, and [conversationUnrecoverableKinds] has to say so.
/// A kind that appears in none of these lists is a row that outlives the
/// conversation it describes, which is what the guard test refuses.
///
/// Every row in every list is keyed by the conversation id in `id` — the column
/// the whole app reads these rows through (`_hasDraft`,
/// `readImageContextSettings`, `CompressionRepository.overrides`,
/// `readContextOperations`) and the column both halves claim them by, which is
/// what makes one predicate enough on either side.
final Set<String> conversationDocumentKinds = {
  for (final family in syncedConversationFamilies)
    if (family.kind != null) family.kind!,
};

/// Removed with the conversation, and deliberately not staged.
///
/// Named here rather than left out of the capture silently, and for the reason
/// ADR-0016 gives about `generation_run_rows`: a compression task is a stream
/// that is happening now, not history anyone could want back, and a restored
/// task would describe a run no writer is feeding.
const conversationUnrecoverableKinds = <String>{'contextCompressionTask'};

/// Everything a conversation's deletion removes from `extension_entity_rows`.
///
/// The draft is not in here: it has its own delete path
/// (`ComposerDraftStore.delete`) with the same predicate and its own fence, and
/// naming it here would give one row two owners.
final Set<String> conversationDeletedKinds = {
  ...conversationDocumentKinds,
  ...conversationUnrecoverableKinds,
};

/// Everything a conversation snapshot stages.
///
/// The draft belongs to the capture but not to [conversationDocumentKinds]: it
/// is composer state, written back under its own gate (a draft made since the
/// deletion wins) and with its dead attachment paths pruned, where a document is
/// part of the conversation and comes back whole.
final Set<String> conversationCapturedKinds = {
  ...conversationDocumentKinds,
  ComposerDraftStore.kind,
};
