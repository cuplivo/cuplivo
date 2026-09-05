import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/assistant.dart';
import '../../core/providers/assistant_provider.dart';
import '../../core/providers/quick_instruction_provider.dart';
import '../../core/providers/world_book_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import 'ios_checkbox.dart';
import 'ios_tactile.dart';

/// Multi-select checklist of all current assistants, used to assign an item
/// (world book / instruction injection) to assistants at edit time.
///
/// The checkbox set is initialized from the entity's effective per-assistant
/// binding (`activeIdsFor`, including the global fallback). The user's FULL
/// final selection is reported via [onSelectionChanged].
class AssistantBindMultiSelect extends StatefulWidget {
  const AssistantBindMultiSelect({
    super.key,
    required this.itemId,
    required this.activeIdsFor,
    required this.onSelectionChanged,
  });

  /// The bound entity's id; `null` when creating a new one (nothing checked).
  final String? itemId;

  /// The per-assistant active ids of the entity (effective fallback
  /// semantics included).
  final List<String> Function(String? assistantId) activeIdsFor;

  /// Reports the full set of checked assistant ids after every change.
  final ValueChanged<Set<String>> onSelectionChanged;

  @override
  State<AssistantBindMultiSelect> createState() =>
      _AssistantBindMultiSelectState();
}

class _AssistantBindMultiSelectState extends State<AssistantBindMultiSelect> {
  Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    final assistants = context.read<AssistantProvider>().assistants;
    _selected = {
      for (final a in assistants)
        if (a.id.isNotEmpty &&
            widget.itemId != null &&
            widget.activeIdsFor(a.id).contains(widget.itemId))
          a.id,
    };
    widget.onSelectionChanged(Set<String>.from(_selected));
  }

  void _check(Assistant assistant, bool value) {
    setState(() {
      if (value) {
        _selected.add(assistant.id);
      } else {
        _selected.remove(assistant.id);
      }
    });
    widget.onSelectionChanged(Set<String>.from(_selected));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final assistants = context.watch<AssistantProvider>().assistants;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text(
            l10n.bindingsEnableForAssistants,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.9),
            ),
          ),
        ),
        for (final a in assistants)
          _AssistantCheckRow(
            label: a.name.trim().isEmpty
                ? l10n.bindingsUnnamedAssistant
                : a.name.trim(),
            checked: _selected.contains(a.id),
            onTap: () => _check(a, !_selected.contains(a.id)),
          ),
        if (assistants.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Text(
              l10n.bindingsNoAssistantsHint,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
      ],
    );
  }
}

class _AssistantCheckRow extends StatelessWidget {
  const _AssistantCheckRow({
    required this.label,
    required this.checked,
    required this.onTap,
  });

  final String label;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      pressedBlendStrength: 0,
      pressedScale: 1.0,
      haptics: false,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IosCheckbox(value: checked, onChanged: (_) => onTap()),
          ],
        ),
      ),
    );
  }
}

/// Applies an explicit per-assistant binding state for an item id.
///
/// Every assistant in [assistantIds] is brought to its desired state:
/// checked assistants gain the item in their active list, unchecked ones lose
/// it. Empty-result assignment states are written as explicit empty lists.
Future<void> applyAssistantBindStates({
  required String itemId,
  required Set<String> selectedAssistantIds,
  required List<String> assistantIds,
  required List<String> Function(String? assistantId) activeIdsFor,
  required Future<void> Function(List<String> ids, {String? assistantId})
  setActiveIds,
}) async {
  for (final assistantId in assistantIds) {
    final active = activeIdsFor(assistantId);
    final currentlyBound = active.contains(itemId);
    final shouldBeBound = selectedAssistantIds.contains(assistantId);
    if (currentlyBound == shouldBeBound) continue;
    final ids = active.toSet();
    if (shouldBeBound) {
      ids.add(itemId);
    } else {
      ids.remove(itemId);
    }
    await setActiveIds(ids.toList(growable: false), assistantId: assistantId);
  }
}

/// Applies a world book's assistant assignment.
///
/// Call this only AFTER the book itself has been persisted — a failed
/// `addBook`/`updateBook` must never leave orphan bindings behind.
Future<void> applyWorldBookBindings(
  BuildContext context, {
  required String itemId,
  required Set<String> selectedAssistantIds,
}) async {
  final assistantIds = context
      .read<AssistantProvider>()
      .assistants
      .map((a) => a.id)
      .toList(growable: false);
  if (assistantIds.isEmpty) return;
  final provider = context.read<WorldBookProvider>();
  await applyAssistantBindStates(
    itemId: itemId,
    selectedAssistantIds: selectedAssistantIds,
    assistantIds: assistantIds,
    activeIdsFor: provider.activeBookIdsFor,
    setActiveIds: (ids, {assistantId}) =>
        provider.setActiveBookIds(ids, assistantId: assistantId),
  );
}

/// Applies an instruction injection's assistant assignment.
///
/// Call this only AFTER the injection itself has been persisted — a failed
/// `add`/`update` must never leave orphan bindings behind.
Future<void> applyInjectionBindings(
  BuildContext context, {
  required String itemId,
  required Set<String> selectedAssistantIds,
}) async {
  final assistantIds = context
      .read<AssistantProvider>()
      .assistants
      .map((a) => a.id)
      .toList(growable: false);
  if (assistantIds.isEmpty) return;
  final provider = context.read<QuickInstructionProvider>();
  await applyAssistantBindStates(
    itemId: itemId,
    selectedAssistantIds: selectedAssistantIds,
    assistantIds: assistantIds,
    activeIdsFor: provider.activeIdsFor,
    setActiveIds: (ids, {assistantId}) =>
        provider.setActiveIds(ids, assistantId: assistantId),
  );
}
