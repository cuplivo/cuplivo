import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/model_spec.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/reasoning/reasoning_selection.dart';
import '../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/widgets/reasoning_level_sheet.dart';
import '../../home/utils/model_display_helper.dart';
import 'group_member_strip.dart';

/// The reasoning picker, scoped to one member of a group.
///
/// The picker itself is the 1:1 one; what a group adds is the strip that says
/// whose level is being edited. Every write goes through the same
/// `commitReasoningChoice` a 1:1 chat uses, so a group adds no storage.
Future<void> showGroupReasoningSheet(
  BuildContext context, {
  required List<Assistant> members,
  String? initialAssistantId,
}) {
  if (members.isEmpty) return Future<void>.value();
  final initial = members.any((m) => m.id == initialAssistantId)
      ? initialAssistantId!
      : members.first.id;
  return showReasoningPickerSheet<void>(
    context: context,
    builder: (_) =>
        _GroupReasoningPicker(members: members, initialAssistantId: initial),
  );
}

class _GroupReasoningPicker extends StatefulWidget {
  const _GroupReasoningPicker({
    required this.members,
    required this.initialAssistantId,
  });

  final List<Assistant> members;
  final String initialAssistantId;

  @override
  State<_GroupReasoningPicker> createState() => _GroupReasoningPickerState();
}

class _GroupReasoningPickerState extends State<_GroupReasoningPicker> {
  late String _selectedId = widget.initialAssistantId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final byId = {for (final member in widget.members) member.id: member};
    final member = byId[_selectedId] ?? widget.members.first;
    final model = resolveChatModel(settings, assistant: member);
    final providerKey = model.providerKey;
    final modelId = model.modelId;
    final hasModel = providerKey != null && (modelId ?? '').isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GroupMemberStrip(
            members: widget.members,
            selectedId: member.id,
            onSelect: (picked) => setState(() => _selectedId = picked.id),
            valueBuilder: (picked) => _levelValue(settings, l10n, picked),
          ),
        ),
        const SizedBox(height: 12),
        // What one of these picks commits is the model-level reasoning memory
        // (`commitReasoningChoice`), exactly what the 1:1 composer writes — not
        // the assistant record. Two members on the same provider+model share
        // that memory, so both chips change together; the strip reads each
        // member's own resolution, which is why it shows that happening instead
        // of pretending the level is stored per assistant.
        if (hasModel)
          ReasoningLevelPicker(
            config: settings.getProviderConfig(providerKey),
            modelId: modelId!,
            assistant: member,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Text(
              l10n.reasoningLevelNoReasoning,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.62),
              ),
            ),
          ),
      ],
    );
  }

  /// The member's level as a word, or nothing when no level applies: an
  /// unsupported model and an off switch both read better as an empty slot
  /// than as a second label saying so.
  Widget? _levelValue(
    SettingsProvider settings,
    AppLocalizations l10n,
    Assistant member,
  ) {
    final model = resolveChatModel(settings, assistant: member);
    final providerKey = model.providerKey;
    final modelId = model.modelId;
    if (providerKey == null || (modelId ?? '').isEmpty) return null;
    final config = settings.getProviderConfig(providerKey);
    if (!ModelSpecResolver.instance.spec(config, modelId!).supportsReasoning) {
      return null;
    }
    final request = selectReasoningRequest(
      settings: settings,
      config: config,
      modelId: modelId,
      assistant: member,
    );
    if (request.level == ReasoningLevel.off) return null;
    return Text(reasoningLevelLabel(l10n, request.level));
  }
}
