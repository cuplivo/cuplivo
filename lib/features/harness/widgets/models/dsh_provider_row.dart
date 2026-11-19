import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/widgets/models/dsh_provider_icon.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The 启用 pill of a DSH provider row.
class DshProviderStatusPill extends StatelessWidget {
  const DshProviderStatusPill({
    super.key,
    required this.enabled,
    required this.label,
  });

  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final foreground = enabled ? colors.success : colors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: AppFontWeights.semibold,
          color: foreground,
        ),
      ),
    );
  }
}

/// One provider card in the 模型 tab's list (R9).
///
/// A standalone rounded card rather than a row inside a shared card, matching
/// the reference: circular mark, name, optional 启用 pill and a chevron. The
/// subtitle is only used for the host's diagnostic line.
class DshProviderCard extends StatelessWidget {
  const DshProviderCard({
    super.key,
    required this.providerId,
    required this.displayName,
    required this.enabled,
    required this.onTap,
    this.subtitle,
    this.icon,
  });

  final String providerId;
  final String displayName;
  final bool enabled;
  final VoidCallback onTap;
  final String? subtitle;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final subtitleText = subtitle?.trim() ?? '';
    return RepaintBoundary(
      child: IosCardPress(
        baseColor: sheetTileColor(context),
        borderRadius: BorderRadius.circular(16),
        pressedBlendStrength: 0.08,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        child: Row(
          children: [
            icon ??
                DshProviderIcon(
                  providerId: providerId,
                  displayName: displayName,
                ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface.withValues(alpha: 0.92),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitleText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitleText,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            DshProviderStatusPill(
              enabled: enabled,
              label: enabled
                  ? l10n.dshModelsProviderEnabled
                  : l10n.dshModelsProviderUnavailable,
            ),
            const SizedBox(width: 6),
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }
}

/// The first card of the 模型 tab: the 自定义提供商 creation entry.
///
/// It keeps the same card geometry as [DshProviderCard] but reads as an action
/// (plus mark, no status pill) so adding a provider is discoverable without
/// opening the `+` picker first.
class DshProviderCustomCard extends StatelessWidget {
  const DshProviderCustomCard({
    super.key,
    required this.onTap,
    this.enabled = true,
  });

  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: IosCardPress(
        baseColor: sheetTileColor(context),
        borderRadius: BorderRadius.circular(16),
        pressedBlendStrength: 0.08,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: enabled ? onTap : null,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary.withValues(alpha: 0.14),
              ),
              child: Icon(Lucide.Plus, size: 18, color: cs.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.dshModelsCustomProviderTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface.withValues(alpha: 0.92),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.dshModelsCustomProviderSubtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row of the add-provider picker (R10).
///
/// A plain list row with a bottom hairline, the same layout as the reference:
/// circular mark, name and chevron. [trailing] replaces the chevron for rows
/// that open a detail directly.
class DshProviderPickRow extends StatelessWidget {
  const DshProviderPickRow({
    super.key,
    required this.providerId,
    required this.displayName,
    required this.onTap,
    this.showDivider = true,
    this.icon,
  });

  final String providerId;
  final String displayName;
  final VoidCallback onTap;
  final bool showDivider;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosCardPress(
          baseColor: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          pressedBlendStrength: 0.07,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onTap: onTap,
          child: Row(
            children: [
              icon ??
                  DshProviderIcon(
                    providerId: providerId,
                    displayName: displayName,
                    size: 32,
                  ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  displayName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Lucide.ChevronRight,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.32),
              ),
            ],
          ),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: cs.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
      ],
    );
  }
}
