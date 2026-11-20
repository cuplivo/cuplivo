import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import 'package:Cuplivo/core/services/haptics.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// How a new DeepSeek Harness record is reached. Only direct connection (LAN
/// or public WebUI URL) exists in phase 1; the enum is here so the later
/// engine-selection phase can add rows without reshaping the flow.
enum DshConnectMode { direct }

/// "连接到一个新的DeepSeek Harness": the engine choice shown after the create
/// menu's third row.
///
/// Mobile uses the app's standard bottom sheet; desktop uses a dialog, because
/// this repository never shows bottom sheets on desktop. Phase 1 exposes the
/// direct row only.
Future<DshConnectMode?> showDshConnectModeSheet(BuildContext context) {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  return isDesktop
      ? _showDesktopModeDialog(context)
      : _showMobileModeSheet(context);
}

Future<DshConnectMode?> _showMobileModeSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showModalBottomSheet<DshConnectMode>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  l10n.dshConnectSheetTitle,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _ModeRow(
                key: const Key('dsh-engine-mode'),
                label: l10n.dshConnectModeDirect,
                onTap: () => Navigator.of(ctx).pop(DshConnectMode.direct),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<DshConnectMode?> _showDesktopModeDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<DshConnectMode>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return AlertDialog(
        backgroundColor: context.overlaySurface,
        title: Text(
          l10n.dshConnectSheetTitle,
          style: TextStyle(fontSize: 17, fontWeight: AppFontWeights.semibold),
        ),
        contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        content: SizedBox(
          width: 320,
          child: _ModeRow(
            key: const Key('dsh-engine-mode'),
            label: l10n.dshConnectModeDirect,
            onTap: () => Navigator.of(ctx).pop(DshConnectMode.direct),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.dshCancel, style: TextStyle(color: cs.primary)),
          ),
        ],
      );
    },
  );
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: sheetTileColor(context),
      borderRadius: BorderRadius.circular(14),
      haptics: false,
      onTap: () {
        Haptics.soft();
        onTap();
      },
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Icon(
            Lucide.Cable,
            size: 22,
            color: cs.onSurface.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface.withValues(alpha: 0.92),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
