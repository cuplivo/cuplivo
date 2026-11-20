import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// R5's 更多 entry: a native menu, per `docs/cuplivo-dsh/architecture.md` §6.1.
///
/// It exists so the harness surface is not a one-way door —
/// 返回本地助手 is the in-surface way back to Cuplivo's local assistants — and
/// it is a plain row in this menu rather than a floating control on the chat
/// surface, so the drawer keeps matching R5.
class HarnessMorePage extends StatefulWidget {
  const HarnessMorePage({
    super.key,
    required this.remoteName,
    required this.onBackToLocalAssistants,
    required this.onOpenSettings,
  });

  /// The remote's display name, shown under the menu title.
  final String remoteName;

  final VoidCallback onBackToLocalAssistants;
  final VoidCallback onOpenSettings;

  @override
  State<HarnessMorePage> createState() => _HarnessMorePageState();
}

class _HarnessMorePageState extends State<HarnessMorePage> {
  String? _version;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      final version = info.version.trim();
      final build = info.buildNumber.trim();
      setState(() {
        _version = version.isEmpty
            ? (build.isEmpty ? null : build)
            : (build.isEmpty ? version : '$version+$build');
      });
    } catch (_) {
      // Version is informational only; a platform without package_info shows
      // the em dash instead of failing the page.
    }
  }

  void _showAbout(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.dshMoreAbout),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cuplivo',
              style: TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.medium,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              _version ?? '—',
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.dshMoreAboutHint,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.sideDrawerOK),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dshSidebarMore),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (widget.remoteName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                widget.remoteName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          SectionCard(
            children: [
              _MoreRow(
                key: const Key('dsh-more-back-to-local'),
                icon: Lucide.ArrowLeft,
                label: l10n.dshMoreBackToLocal,
                onTap: widget.onBackToLocalAssistants,
              ),
              _MoreRow(
                key: const Key('dsh-more-settings'),
                icon: Lucide.Settings,
                label: l10n.dshMoreOpenSettings,
                onTap: widget.onOpenSettings,
              ),
              _MoreRow(
                key: const Key('dsh-more-about'),
                icon: Lucide.BadgeInfo,
                label: l10n.dshMoreAbout,
                onTap: () => _showAbout(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: Colors.transparent,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurface.withValues(alpha: 0.75)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface,
                fontWeight: AppFontWeights.regular,
              ),
            ),
          ),
          Icon(
            Lucide.ChevronRight,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.35),
          ),
        ],
      ),
    );
  }
}
