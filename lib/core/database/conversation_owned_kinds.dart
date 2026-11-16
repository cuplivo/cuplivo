import '../models/compression_config.dart';
import '../models/context_operation.dart';
import '../models/image_context.dart';
import 'composer_draft_store.dart';

/// The `extension_entity_rows` a conversation owns, as one rule read by both
/// halves that must not disagree: what its delete removes, and what the recycle
/// bin stages on the way out.
///
/// What a conversation keeps outside its messages — the history of the
/// operations that compressed or cleared its context, the images it pins and how
/// it treats images at all, and its own compression configuration — is deleted
/// with the conversation **and** staged by the bin, because delete-and-restore
/// is supposed to hand the conversation back and these are part of it. None of
/// them rides a sync subtree (`SyncSubtreePayload` carries the conversation row,
/// the messages, the parts and the MCP bindings), so the bin is the only way
/// back from a mistaken delete.
///
/// The difference between the lists below is a written exclusion, not an
/// omission: a kind that appears in none of them is a row that outlives the
/// conversation it describes. And every row in every list is keyed by the
/// conversation id in `id` — the column the whole app reads these rows through
/// (`_hasDraft`, `readImageContextSettings`, `CompressionRepository.overrides`,
/// `readContextOperations`) and the column both halves claim them by, which is
/// what makes one predicate enough on either side.
const conversationDocumentKinds = <String>{
  ContextOperation.entityKind,
  ImageContextSettings.entityKind,
  CompressionConfig.conversationKind,
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
const conversationDeletedKinds = <String>{
  ...conversationDocumentKinds,
  ...conversationUnrecoverableKinds,
};

/// Everything a conversation snapshot stages.
///
/// The draft belongs to the capture but not to [conversationDocumentKinds]: it
/// is composer state, written back under its own gate (a draft made since the
/// deletion wins) and with its dead attachment paths pruned, where a document is
/// part of the conversation and comes back whole.
const conversationCapturedKinds = <String>{
  ...conversationDocumentKinds,
  ComposerDraftStore.kind,
};
