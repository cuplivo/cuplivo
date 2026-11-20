import 'package:flutter/material.dart';

import 'package:Cuplivo/core/models/model_spec.dart';
import 'package:Cuplivo/core/models/reasoning_request.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_picker_scaffold.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/icons/reasoning_icons.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// DSH calls this "reasoning effort"; Cuplivo's own picker is level-based.
///
/// The wire ids the shipped DSH profile uses line up with Cuplivo's levels, so
/// the icon set reuses [ReasoningIcons] instead of introducing a second visual
/// language. Unknown ids (a Host plugin may invent one) fall back to the neutral
/// auto icon; the label always comes from the Host's catalog, never from this
/// mapping.
ReasoningLevel dshReasoningLevelForEffort(String? effortId) {
  return switch (effortId) {
    'off' => ReasoningLevel.off,
    'on' => ReasoningLevel.on,
    'minimal' => ReasoningLevel.minimal,
    'low' => ReasoningLevel.low,
    'medium' => ReasoningLevel.medium,
    'high' => ReasoningLevel.high,
    'xhigh' => ReasoningLevel.xhigh,
    'max' => ReasoningLevel.max,
    _ => ReasoningLevel.auto,
  };
}

/// The value `ChatInputBar` needs to paint its reasoning button.
///
/// It is presentation only: the remote session is sent the Host effort id
/// (`DshModelSelection.reasoningEffortId`), never this Cuplivo enum.
ReasoningRequest dshReasoningRequestForEffort(String? effortId) =>
    ReasoningRequest(dshReasoningLevelForEffort(effortId));

/// Opens the remote reasoning-effort picker and returns the chosen effort id,
/// or null when dismissed.
///
/// A model with no advertised efforts has nothing to choose: the caller hides
/// the control instead of opening an empty picker.
Future<String?> showDshReasoningPicker(
  BuildContext context, {
  required DshModelOption model,
  DshModelSelection? current,
  Key? panelKey,
}) {
  return showDshPicker<String>(
    context: context,
    title: AppLocalizations.of(context)!.dshReasoningPickerTitle,
    panelKey: panelKey,
    bodyBuilder: (context, scrollController) => DshReasoningEffortPicker(
      model: model,
      current: current,
      scrollController: scrollController,
    ),
  );
}

/// The picker body: one row per advertised effort with its name, description,
/// a default marker and a check on the active one.
class DshReasoningEffortPicker extends StatelessWidget {
  const DshReasoningEffortPicker({
    super.key,
    required this.model,
    required this.scrollController,
    this.current,
  });

  final DshModelOption model;
  final DshModelSelection? current;
  final ScrollController scrollController;

  static Key rowKey(String effortId) =>
      ValueKey<String>('dsh-reasoning-$effortId');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (!model.supportsReasoning) {
      return DshPickerEmptyState(
        icon: Lucide.Brain,
        message: l10n.dshReasoningPickerNone,
      );
    }
    final selectedId = model.resolveEffort(current?.reasoningEffortId)?.id;
    final defaultId = model.defaultEffort?.id;
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
      children: [
        for (final effort in model.reasoningEfforts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: IosCardPress(
              key: rowKey(effort.id),
              baseColor: effort.id == selectedId
                  ? cs.primary.withValues(alpha: 0.10)
                  : sheetTileColor(context),
              borderRadius: BorderRadius.circular(14),
              pressedBlendStrength: 0.10,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onTap: () => Navigator.of(context).pop(effort.id),
              child: Row(
                children: [
                  ReasoningIcons.levelIcon(
                    dshReasoningLevelForEffort(effort.id),
                    size: 20,
                    color: effort.id == selectedId
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                effort.name.trim().isEmpty
                                    ? effort.id
                                    : effort.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: AppFontWeights.medium,
                                  color: effort.id == selectedId
                                      ? cs.primary
                                      : cs.onSurface,
                                ),
                              ),
                            ),
                            if (effort.id == defaultId) ...[
                              const SizedBox(width: 6),
                              _DefaultMarker(
                                label: l10n.dshReasoningDefaultTag,
                              ),
                            ],
                          ],
                        ),
                        if ((effort.description ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            effort.description!.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.25,
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (effort.id == selectedId)
                    Icon(Lucide.Check, size: 18, color: cs.primary)
                  else
                    const SizedBox(width: 18),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _DefaultMarker extends StatelessWidget {
  const _DefaultMarker({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: AppFontWeights.medium,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
