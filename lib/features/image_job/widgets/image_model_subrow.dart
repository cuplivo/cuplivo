/// The row that grows under 绘图 when it is on.
///
/// It is not a second switch and not a chevron on the main row: the main row
/// only says on/off, and *what it draws with* is the next level down. Collapsed,
/// a phone shows nothing extra and a desktop keeps the model in the row's
/// detail — the accepted round-11 shape.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../model/widgets/model_select_sheet.dart';
import '../services/image_backends.dart' show modelCanDrawPicture;
import '../services/image_model_resolver.dart';
import 'image_job_panel.dart' show imageModelDisplayName;

/// What the sub-row says: the model in effect, or that there is none.
String imageModelSubRowLabel(
  AppLocalizations l10n,
  SettingsProvider settings,
  Assistant? assistant,
) {
  final resolved = resolveImageModel(settings, assistant);
  if (resolved.binding == null) return l10n.imageJobNotConfigured;
  return '${l10n.imageJobPanelModelLabel} · '
      '${imageModelDisplayName(settings, resolved.binding)}';
}

/// The same resolution the coordinator runs, so the row cannot promise a model
/// the tool would refuse. Defined once in the resolver, re-exported here because
/// three UI call sites already import this file for the label.
ResolvedModel resolveImageModel(
  SettingsProvider settings,
  Assistant? assistant,
) => resolveImageModelFor(settings, assistant);

/// Pick the model this assistant draws with and store it on the assistant.
///
/// [closeFirst] closes the surface that asked — the desktop tools popover is an
/// overlay entry that paints *above* every route, so a picker opened under it
/// would appear behind it and the popover's own barrier would eat the tap. The
/// caller that knows how to close it hands that in.
///
/// Everything that survives the close (the provider, the assistant, the model
/// resolution) is captured before the first await, so the choice is still
/// written once the popover is gone.
Future<void> pickImageModel(
  BuildContext context, {
  required Assistant assistant,
  VoidCallback? closeFirst,
}) async {
  final settings = context.read<SettingsProvider>();
  final assistants = context.read<AssistantProvider>();
  final current = resolveImageModel(settings, assistant);
  final pickerHost = context;
  closeFirst?.call();
  final selection = await showModelSelector(
    pickerHost,
    initialProviderKey: current.binding?.providerId,
    initialModelId: current.binding?.modelId,
    includeModel: modelCanDrawPicture,
    // Without this the assistant's choice is a one-way door: once the sub-row
    // has written a pair there is no way back to "follow the global default",
    // and a pair whose provider later disappears would keep winning.
    //
    // The label is not "Follow assistant": for a drawing model the tier above is
    // the global default in Settings — the assistant *is* the tier being
    // overridden here.
    allowInherit: true,
    inheritLabel: AppLocalizations.of(pickerHost)!.imageModelFollowGlobal,
  );
  if (selection == null) return;
  final latest = assistants.getById(assistant.id) ?? assistant;
  await assistants.updateAssistant(
    selection.isInherit
        ? latest.copyWith(
            clearImageModelProvider: true,
            clearImageModelId: true,
          )
        : latest.copyWith(
            imageModelProvider: selection.providerKey,
            imageModelId: selection.modelId,
          ),
  );
}

/// The 13px, indented row with a `›`: 「模型 · gpt-image-1」 or 「未配置 · 去选择」.
class ImageModelSubRow extends StatelessWidget {
  const ImageModelSubRow({
    super.key,
    required this.label,
    required this.configured,
    required this.onTap,
    this.inset = 42,
    this.height = 34,
    this.fontSize = 13,
  });

  final String label;
  final bool configured;
  final VoidCallback onTap;

  /// Left inset that lines the text up under the main row's label.
  final double inset;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = configured
        ? cs.onSurface.withValues(alpha: 0.6)
        : context.appColors.warning;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: EdgeInsets.only(left: inset, right: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: fontSize, color: color),
                  ),
                ),
                Icon(
                  Lucide.ChevronRight,
                  size: fontSize + 1,
                  color: cs.onSurface.withValues(alpha: 0.35),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
