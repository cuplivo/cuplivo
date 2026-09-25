import 'package:flutter/material.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';

/// Full-screen "about memory" page (mobile). Desktop uses a dialog instead.
class MemoryAboutPage extends StatelessWidget {
  const MemoryAboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.memorySettingsAboutTitle),
      ),
      body: const MemoryAboutContent(),
    );
  }
}

/// Shared body for the about page (mobile) and desktop dialog.
class MemoryAboutContent extends StatelessWidget {
  const MemoryAboutContent({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListView(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _AboutSection(
          title: l10n.memoryAboutQuickstartTitle,
          body: l10n.memoryAboutQuickstartBody,
        ),
        _AboutSection(
          title: l10n.memoryAboutTypesTitle,
          body: l10n.memoryAboutTypesBody,
        ),
        _AboutSection(
          title: l10n.memoryAboutScopeTitle,
          body: l10n.memoryAboutScopeBody,
        ),
        _AboutSection(
          title: l10n.memoryAboutInjectionTitle,
          body: l10n.memoryAboutInjectionBody,
        ),
        _AboutSection(
          title: l10n.memoryAboutPipelineTitle,
          body: l10n.memoryAboutPipelineBody,
        ),
        _AboutSection(
          title: l10n.memoryAboutCacheTitle,
          body: l10n.memoryAboutCacheBody,
        ),
        _AboutSection(
          title: l10n.memoryAboutFaqTitle,
          heading: l10n.memoryAboutFaqWhyNotRememberedTitle,
          body: l10n.memoryAboutFaqWhyNotRememberedBody,
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.title, required this.body, this.heading});

  final String title;
  final String body;
  final String? heading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.92),
            ),
          ),
          const SizedBox(height: 8),
          if (heading != null) ...[
            Text(
              heading!,
              style: TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.emphasis,
                color: cs.onSurface.withValues(alpha: 0.88),
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            body,
            style: TextStyle(
              fontSize: 14,
              height: 1.55,
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}
