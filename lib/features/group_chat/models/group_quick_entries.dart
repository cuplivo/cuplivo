import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/conversation_mcp_settings.dart';
import '../../../core/models/model_spec.dart';
import '../../../core/models/reasoning_request.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/services/api/reasoning/reasoning_selection.dart';
import '../../../core/services/search/search_service.dart';
import '../../home/utils/model_display_helper.dart';

/// What a group's search entry shows on the composer.
///
/// A group sends each reply with its speaker's own model and its own assistant
/// record, so there is no single value to report the way a 1:1 chat does. The
/// entry reports the roster instead: [uniform] says every member agrees, and
/// only then may the button display [serviceName] (or [builtIn]). When members
/// disagree the button is lit with the neutral globe and the per-member values
/// live on the panel's member strip.
class GroupSearchEntry {
  const GroupSearchEntry({
    required this.anyOn,
    required this.uniform,
    required this.builtIn,
    required this.serviceName,
  });

  /// At least one member searches, through built-in search or the service.
  final bool anyOn;

  /// Every member resolves to the same mode.
  final bool uniform;

  /// The shared mode is the model's own search tool. Model-level, so members
  /// sharing a model always agree here.
  final bool builtIn;

  /// Display name of the shared external service, null when the shared mode is
  /// built-in search or no service is configured.
  final String? serviceName;
}

/// What a group's reasoning entry shows on the composer.
class GroupReasoningEntry {
  const GroupReasoningEntry({
    required this.anySupported,
    required this.anyActive,
    required this.uniform,
    required this.request,
  });

  /// At least one member's model can reason. The entry is hidden only when no
  /// member can, mirroring the 1:1 rule.
  final bool anySupported;

  /// At least one member will actually reason this round: its model can, and
  /// its level is not off.
  ///
  /// Both halves are needed. A model that cannot reason carries no preference,
  /// so [selectReasoningRequest] hands it the spec's default — `auto`, never
  /// `off` — and testing the level alone would report a round as reasoning
  /// when every capable member is switched off. This is the pair a group round
  /// checks before each turn (`supportsReasoning && isReasoningEnabled(...)`).
  final bool anyActive;

  /// Every member resolves to the same request.
  final bool uniform;

  /// The shared request, null when members disagree.
  final ReasoningRequest? request;
}

/// Resolves the search entry for [members] through the chain a group round
/// sends with: each member's own model, then that member's own record.
GroupSearchEntry resolveGroupSearch({
  required SettingsProvider settings,
  required List<Assistant> members,
}) {
  if (members.isEmpty) {
    return const GroupSearchEntry(
      anyOn: false,
      uniform: false,
      builtIn: false,
      serviceName: null,
    );
  }
  final serviceName = _selectedServiceName(settings);
  final modes = <({bool on, bool builtIn})>[];
  for (final member in members) {
    final model = resolveChatModel(settings, assistant: member);
    final providerKey = model.providerKey;
    final modelId = model.modelId;
    if (providerKey == null || (modelId ?? '').isEmpty) {
      // No model: the round cannot search with this member at all.
      modes.add((on: false, builtIn: false));
      continue;
    }
    final cfg = settings.getProviderConfig(providerKey);
    final builtIn = BuiltInToolsHelper.isBuiltInSearchEnabled(
      cfg: cfg,
      modelId: modelId!,
    );
    modes.add((
      on: builtIn || (member.searchEnabled && !builtIn),
      builtIn: builtIn,
    ));
  }
  final first = modes.first;
  final uniform = modes.every(
    (mode) => mode.on == first.on && mode.builtIn == first.builtIn,
  );
  return GroupSearchEntry(
    anyOn: modes.any((mode) => mode.on),
    uniform: uniform,
    builtIn: uniform && first.builtIn,
    serviceName: uniform && first.on && !first.builtIn ? serviceName : null,
  );
}

/// Resolves the reasoning entry for [members] the same way [resolveGroupSearch]
/// resolves search.
///
/// [supportsReasoning] is the caller's capability check, so a group and a 1:1
/// chat never disagree about whether a model can reason.
GroupReasoningEntry resolveGroupReasoning({
  required SettingsProvider settings,
  required List<Assistant> members,
  required bool Function(String providerKey, String modelId) supportsReasoning,
}) {
  if (members.isEmpty) {
    return const GroupReasoningEntry(
      anySupported: false,
      anyActive: false,
      uniform: false,
      request: null,
    );
  }
  final states = <({bool supported, ReasoningRequest request})>[];
  for (final member in members) {
    final model = resolveChatModel(settings, assistant: member);
    final providerKey = model.providerKey;
    final modelId = model.modelId;
    if (providerKey == null || (modelId ?? '').isEmpty) {
      states.add((supported: false, request: ReasoningRequest.auto));
      continue;
    }
    final cfg = settings.getProviderConfig(providerKey);
    states.add((
      supported: supportsReasoning(providerKey, modelId!),
      request: selectReasoningRequest(
        settings: settings,
        config: cfg,
        modelId: modelId,
        assistant: member,
      ),
    ));
  }
  final first = states.first;
  final uniform = states.every(
    (state) =>
        state.supported == first.supported && state.request == first.request,
  );
  return GroupReasoningEntry(
    anySupported: states.any((state) => state.supported),
    anyActive: states.any(
      (state) => state.supported && state.request.level != ReasoningLevel.off,
    ),
    uniform: uniform,
    request: uniform ? first.request : null,
  );
}

/// The members whose model can call a tool at all, with the model resolved the
/// way the round resolves it.
Iterable<({Assistant member, String modelId})> _toolCapableMembers({
  required SettingsProvider settings,
  required List<Assistant> members,
  required bool Function(String providerKey, String modelId) supportsTools,
}) sync* {
  for (final member in members) {
    final model = resolveChatModel(settings, assistant: member);
    final providerKey = model.providerKey;
    final modelId = model.modelId;
    if (providerKey == null || (modelId ?? '').isEmpty) continue;
    if (!supportsTools(providerKey, modelId!)) continue;
    yield (member: member, modelId: modelId);
  }
}

/// Whether any member's model can call a tool, whatever that member has switched
/// on. The composer draws the tools entry on this alone, the way a 1:1 chat does
/// for its one model: a model that cannot call a tool is offered none, so a
/// roster where nobody can gets no entry.
bool anyGroupMemberCanCallTools({
  required SettingsProvider settings,
  required List<Assistant> members,
  required bool Function(String providerKey, String modelId) supportsTools,
}) => _toolCapableMembers(
  settings: settings,
  members: members,
  supportsTools: supportsTools,
).isNotEmpty;

/// Whether a group's tools entry is lit: some member both brings tools and can
/// call them.
///
/// The capability test comes first, exactly as the 1:1 composer writes
/// `supportsModelTools && _isToolsActive(...)`: a model that cannot call tools
/// is offered none, so a bound workspace, a local tool switch or an MCP
/// selection must not light the entry on its own — those are three ways of
/// *having* tools, not of being able to use them. [conversation] carries a group
/// panel's own MCP override, which applies to every member that allows it.
bool resolveGroupToolsActive({
  required SettingsProvider settings,
  required List<Assistant> members,
  required bool workspaceBound,
  required bool Function(String providerKey, String modelId) supportsTools,
  required Iterable<String> connectedServerIds,
  Conversation? conversation,
}) {
  final connected = connectedServerIds.toSet();
  for (final capable in _toolCapableMembers(
    settings: settings,
    members: members,
    supportsTools: supportsTools,
  )) {
    if (workspaceBound) return true;
    if (capable.member.localToolIds.isNotEmpty) return true;
    final selected = ConversationMcpSettings.effectiveServerIds(
      capable.member,
      conversation,
    );
    if (selected.any(connected.contains)) return true;
  }
  return false;
}

/// The external service the composer's search entry names, resolved the same
/// way the 1:1 entry resolves it.
String? _selectedServiceName(SettingsProvider settings) {
  final services = settings.searchServices;
  if (services.isEmpty) return null;
  final selected = settings.searchServiceSelected.clamp(0, services.length - 1);
  return SearchService.getService(services[selected]).name;
}
