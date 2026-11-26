/// The pure decisions of a delegation: what the child conversation inherits,
/// how deep delegation may go, what it is called, and what the parent is told.
///
/// Nothing here touches a database, a clock or a widget. The coordinator owns
/// the order of side effects; these are the answers it asks for, so a test can
/// pin each rule without standing up the app.
library;

import '../../../core/models/assistant.dart'
    show Assistant, SubagentEscalation, kSubagentDepthMax, kSubagentDepthMin;
import '../../../core/models/workspace_binding.dart';
import '../../../utils/single_line_text.dart';
import '../../../utils/utf16_safe_cut.dart';
import 'subagent_target.dart';

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

  /// What this child was asked to be: [SubagentTarget.encode] — `general` for a
  /// copy of the delegating assistant, `assistant:<id>` for one of the user's
  /// other assistants. The model sends it, the tool writes it, this key keeps
  /// it, and nobody has to put it back together from two keys.
  static const String target = SubagentTargetKeys.extras;

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

  /// How many further delegation levels this conversation may still create.
  ///
  /// Written when the child is created from the delegating side's ceiling, and
  /// read here rather than recomputed: an assistant that is later configured
  /// shallower must not reach back and cut a chain that already started. A
  /// conversation without the key is a root, and the ceiling is its assistant's.
  static const String levels = 'subagent.levels';

  static const String generalTarget = SubagentTargetKeys.general;
}

/// The assistants a delegation from [delegator] may name, in the order they
/// should be offered.
///
/// One rule, two callers: the tool schema asks it for the names and the handler
/// asks it whether an emitted target is legal. Two copies would drift, and the
/// one that drifts is the one that acts.
///
/// The delegating assistant is never in the list — "a copy of yourself" is what
/// `general` already means — and an assistant the user did not select is not
/// either: the selection is also what keeps the id list (roughly 15 tokens
/// each, twice) out of a request the user's assistant rarely needs.
List<Assistant> delegableAssistants({
  required Assistant delegator,
  required List<Assistant> all,
}) {
  final chosen = delegator.subagentTargetIds.toSet();
  if (chosen.isEmpty) return const <Assistant>[];
  return <Assistant>[
    for (final assistant in all)
      if (assistant.id != delegator.id && chosen.contains(assistant.id))
        assistant,
  ];
}

/// One line of the target menu: the value the model must emit, and what the
/// assistant is for.
///
/// The name is not decoration — the model reads it and the id is what it copies
/// back. The description follows only when the user wrote one, and it is folded
/// to a single line: a menu entry is one line, and a newline would break it.
String targetMenuLine(Assistant assistant) {
  final name = assistantName(assistant);
  final about = oneLineText(assistant.description);
  return '${SubagentTarget.assistant(assistant.id).encode()} — '
      '${about.isEmpty ? name : '$name：$about'}';
}

/// The name a model reads for [assistant]; an id is the last resort, and the
/// same fallback the group director uses.
String assistantName(Assistant assistant) {
  final name = assistant.name.trim();
  return name.isEmpty ? assistant.id : name;
}

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
  String target = SubagentTargetKeys.general,
  required int levels,
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
      SubagentExtrasKeys.levels: levels,
      SubagentExtrasKeys.target: target,
      SubagentExtrasKeys.escalation: _narrowEscalation(
        _chainEscalation(parentExtras),
        escalation,
      ).name,
      SubagentExtrasKeys.escalationCap: delegatorHasFullAccess,
    },
  );
}

/// How many further levels a conversation at [extras] may still create.
///
/// A root conversation is its assistant's ceiling; a child was handed a number
/// by the conversation that created it, and that number wins — a chain already
/// under way is not re-priced because somebody edited an assistant afterwards.
int delegationLevels({
  required Assistant? delegator,
  required Map<String, dynamic> extras,
}) {
  final granted = extras[SubagentExtrasKeys.levels];
  if (granted is int && granted >= 0) {
    return granted.clamp(0, kSubagentDepthMax);
  }
  return (delegator?.subagentDepth ?? kSubagentDepthMin).clamp(
    kSubagentDepthMin,
    kSubagentDepthMax,
  );
}

/// How many further levels the child created by a conversation with
/// [parentLevels] may create.
///
/// One level is spent on the child itself, and the child's own assistant gets
/// the last word on how deep its own delegations go — which is why a chain
/// handed to a shallower assistant stops there instead of running to the
/// number the first assistant asked for.
int childLevels({required int parentLevels, required Assistant child}) {
  final remaining = parentLevels - 1;
  final own = child.subagentDepth.clamp(kSubagentDepthMin, kSubagentDepthMax);
  final levels = remaining < own ? remaining : own;
  return levels < 0 ? 0 : levels;
}

/// The delegation depth of a conversation: 0 for an ordinary conversation.
int parentDepth(Map<String, dynamic> extras) {
  final raw = extras[SubagentExtrasKeys.depth];
  return raw is int && raw >= 0 ? raw : 0;
}

/// Whether a conversation at [extras] may delegate at all.
bool mayDelegate({
  required Assistant? delegator,
  required Map<String, dynamic> extras,
}) => delegationLevels(delegator: delegator, extras: extras) >= 1;

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
  required Assistant? delegator,
}) {
  if (isGroup) return 'group_conversation';
  if (isTemporary) return 'temporary_conversation';
  if (!mayDelegate(delegator: delegator, extras: extras)) return 'depth_limit';
  return null;
}

/// What the conversation that delegated to [extras] settled on.
///
/// Null means "there is no chain": a conversation a user started, whose policy
/// is the delegating assistant's own. A value that is present but unreadable is
/// *not* that case — an enum renamed by a later build, or a hand-edited row,
/// still stands for a decision somebody made, and answering "no chain" would let
/// a nested delegation widen a consent an ancestor narrowed. It answers `ask`,
/// the same default the other reader of this key uses
/// (`conversation_tool_permissions.dart`).
SubagentEscalation? _chainEscalation(Map<String, dynamic> extras) {
  final stored = extras[SubagentExtrasKeys.escalation];
  if (stored == null) return null;
  for (final value in SubagentEscalation.values) {
    if (value.name == stored) return value;
  }
  return SubagentEscalation.ask;
}

/// The stricter of two policies.
///
/// Escalation only ever narrows down a chain: a child cannot grant itself more
/// than the conversation that created it held, or two levels of "always allow"
/// would let a delegate talk its way into a consent the user gave to its parent
/// alone.
SubagentEscalation _narrowEscalation(
  SubagentEscalation? inherited,
  SubagentEscalation own,
) {
  if (inherited == null) return own;
  const strictestFirst = [
    SubagentEscalation.deny,
    SubagentEscalation.ask,
    SubagentEscalation.allow,
  ];
  final inheritedRank = strictestFirst.indexOf(inherited);
  final ownRank = strictestFirst.indexOf(own);
  return strictestFirst[inheritedRank < ownRank ? inheritedRank : ownRank];
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
