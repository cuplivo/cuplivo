/// The pure decisions of a delegation: what the child conversation inherits,
/// how deep delegation may go, what it is called, and what the parent is told.
///
/// Nothing here touches a database, a clock or a widget. The coordinator owns
/// the order of side effects; these are the answers it asks for, so a test can
/// pin each rule without standing up the app.
library;

import '../../../core/models/assistant.dart' show SubagentEscalation;
import '../../../core/models/workspace_binding.dart';
import '../../../utils/utf16_safe_cut.dart';

/// The extras keys one delegation writes onto its child conversation.
///
/// They all live in the existing extras bag: the schema stays at 5, and a
/// conversation that carries none of them is an ordinary conversation.
abstract final class SubagentExtrasKeys {
  /// The conversation that delegated to this child.
  static const String parent = 'subagent.parent';

  /// The top-most conversation of the chain. Kept so a grandchild can name the
  /// conversation a user actually recognises.
  static const String root = 'subagent.root';

  /// How many delegations deep this conversation sits. The parent's own depth
  /// is 0.
  static const String depth = 'subagent.depth';

  /// What this child was asked to be. `general` today; the placeholder is what
  /// lets a later slice add a target without migrating anything.
  static const String target = 'subagent.target';

  /// How this child may spend the user's permission: the assistant's
  /// `subagentEscalation` at the moment it was delegated. Copied rather than
  /// looked up so the answer cannot change mid-run, and reachable from the one
  /// place that asks for approval without a provider lookup.
  static const String escalation = 'subagent.escalation';

  /// The ceiling `allow` may reach, copied at the same moment: whether the
  /// delegating conversation held full access. Read live instead, a parent that
  /// gained or lost the grant while the child ran would silently raise or
  /// withdraw a consent that was given for one delegation.
  static const String escalationCap = 'subagent.escalation.cap';

  static const String generalTarget = 'general';
}

/// The deepest delegation allowed below a normal conversation.
///
/// 1 means "a subagent may not delegate again". A conversation at this depth
/// does not get the tool at all, so the model never spends a call learning it.
const int kMaxSubagentDepth = 1;

/// What the child conversation inherits, or why it cannot be created.
final class SubagentChildSpec {
  const SubagentChildSpec({required this.extras, required this.depth});

  final Map<String, dynamic> extras;
  final int depth;
}

/// Builds the extras for a child of [parentConversationId].
///
/// Two keys come from the parent's binding — `workspace.id` and `workspace.cwd`
/// — and nothing else does. Copying the whole bag would carry the parent's tool
/// grant into a conversation the user never approved one for; a grant is
/// per-conversation by design, and `ChatService.createConversation` strips it
/// as a second line of defence.
///
/// An unbound parent yields an unbound child: "no workspace" is inherited just
/// as faithfully as "this workspace".
SubagentChildSpec buildChildSpec({
  required String parentConversationId,
  required Map<String, dynamic> parentExtras,
  SubagentEscalation escalation = SubagentEscalation.ask,
  bool delegatorHasFullAccess = false,
}) {
  final parentBinding = WorkspaceBinding.fromExtras(parentExtras);
  final depth = parentDepth(parentExtras) + 1;
  final root = parentExtras[SubagentExtrasKeys.root] as String?;
  return SubagentChildSpec(
    depth: depth,
    extras: <String, dynamic>{
      if (parentBinding.isBound) ...{
        WorkspaceBinding.keyId: parentBinding.workspaceId,
        WorkspaceBinding.keyCwd: parentBinding.cwd,
      },
      SubagentExtrasKeys.parent: parentConversationId,
      SubagentExtrasKeys.root: root ?? parentConversationId,
      SubagentExtrasKeys.depth: depth,
      SubagentExtrasKeys.target: SubagentExtrasKeys.generalTarget,
      SubagentExtrasKeys.escalation: escalation.name,
      SubagentExtrasKeys.escalationCap: delegatorHasFullAccess,
    },
  );
}

/// The delegation depth of a conversation: 0 for an ordinary conversation.
int parentDepth(Map<String, dynamic> extras) {
  final raw = extras[SubagentExtrasKeys.depth];
  return raw is int && raw >= 0 ? raw : 0;
}

/// Whether a conversation at [extras] may delegate at all.
bool mayDelegate(Map<String, dynamic> extras) =>
    parentDepth(extras) < kMaxSubagentDepth;

/// Whether a conversation at [extras] was started by a delegator.
bool isSubagentConversation(Map<String, dynamic> extras) =>
    extras[SubagentExtrasKeys.depth] is int;

/// The text a delegator's message carries into its child conversation.
///
/// The prefix is the contract the brief states: the child model reads it, so it
/// has to be the same sentence the brief names, in both directions.
String mailToChildText(String text) =>
    'The delegator sent a message: ${text.trim()}';

/// The text a subagent's message carries into its parent conversation.
String mailToParentText({required String label, required String text}) {
  final name = label.trim();
  return '${name.isEmpty ? 'The subagent' : 'Subagent $name'} sent a message: '
      '${text.trim()}';
}

/// Why a conversation may not delegate, or null when it may.
///
/// One rule, two callers: the tool list asks it to decide whether to offer the
/// tool, and the coordinator asks it to decide whether to act. A second copy of
/// these answers would drift, and the one that drifts is the one that acts.
///
/// The two non-depth reasons are not about limits:
///
/// * a group conversation has no single assistant to inherit, so the child would
///   silently run as whoever is selected later;
/// * a temporary chat promises to be gone completely when the user leaves, and a
///   child conversation is a real row — with the task text as its first message,
///   its whole transcript, and a place in every backup and sync.
String? delegationBlockedFor({
  required Map<String, dynamic> extras,
  required bool isGroup,
  required bool isTemporary,
}) {
  if (isGroup) return 'group_conversation';
  if (isTemporary) return 'temporary_conversation';
  if (!mayDelegate(extras)) return 'depth_limit';
  return null;
}

/// The title a child conversation gets.
///
/// [label] is the model's own short name for the job — a few characters in the
/// conversation's language. A model that ignores the instruction, or omits it,
/// falls back to the task's first sentence so the sidebar never shows an empty
/// row. Both are bounded by the same length: a "character" budget tuned for
/// Chinese would cut an English label to two words, and the sidebar is one line
/// either way.
String childTitle({required String? label, required String task}) {
  final clean = (label ?? '').trim();
  final source = clean.isNotEmpty ? clean : firstSentence(task);
  return _truncate(source, _kTitleCodeUnits);
}

/// Code units, not characters: the sidebar is one ellipsised line, and a bound
/// expressed in code units is the one `truncateHeadUtf16Safe` enforces.
const int _kTitleCodeUnits = 20;

/// The result message's text: what the parent model reads on its next turn.
///
/// English, deliberately. It is a machine-ish notice that travels into every
/// provider's history, and the app's own copy is localised at the divider — one
/// language here keeps the notice stable no matter which language the user is
/// talking in.
String resultBrief({
  required String label,
  required String outcome,
  String? text,
  String? childConversationId,
}) {
  final lines = <String>['Subagent finished: $label', 'Outcome: $outcome'];
  final body = (text ?? '').trim();
  if (body.isNotEmpty) {
    lines.add(body);
  }
  if (childConversationId != null) {
    lines.add(
      'Its conversation is a separate chat ($childConversationId); it ran in '
      'this same workspace. Do not claim you did this work yourself.',
    );
  }
  return lines.join('\n');
}

/// The first sentence of [task], capped so a title never wraps the sidebar.
String firstSentence(String task) {
  final flat = task.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '';
  final stop = flat.indexOf(RegExp(r'[.。!！?？]'));
  return stop > 0 ? flat.substring(0, stop) : flat;
}

String _truncate(String value, int max) {
  if (value.length <= max) return value;
  return '${truncateHeadUtf16Safe(value, max)}…';
}
