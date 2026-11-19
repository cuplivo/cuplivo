import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/state/dsh_gateway_models.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// A Flutter entry page behind one of R5's three sidebar rows.
///
/// The rows themselves are part of the home slice; their interiors are later
/// slices. This page is where an interior lands once it exists, so the row is
/// real navigation instead of a dead tap. Until then it states what is missing
/// (capability parity: an unimplemented DSH surface is shown as unavailable,
/// never faked).
class HarnessEntryPage extends StatelessWidget {
  const HarnessEntryPage({
    super.key,
    required this.title,
    required this.icon,
    this.plugins = const <DshPluginEntry>[],
    this.showUnavailable = true,
  });

  final String title;
  final IconData icon;

  /// Plugins the host reported. The plugin list is a native DSH surface, so it
  /// renders here when the catalog has entries; the plugin *panels* stay in the
  /// chat slice's WebView.
  final List<DshPluginEntry> plugins;

  /// Whether the page shows the "arrives in a later slice" note. A page with
  /// content (the plugin list) still shows it for the actions it lacks.
  final bool showUnavailable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (plugins.isNotEmpty) ...[
            SectionCard(
              children: [
                for (final plugin in plugins)
                  ListTile(
                    leading: Icon(
                      Lucide.Boxes,
                      size: 18,
                      color: cs.onSurface.withValues(alpha: 0.75),
                    ),
                    title: Text(
                      plugin.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: AppFontWeights.medium,
                      ),
                    ),
                    subtitle: plugin.description == null
                        ? null
                        : Text(
                            plugin.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                    trailing: plugin.enabled
                        ? Icon(Lucide.Check, size: 16, color: cs.primary)
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (showUnavailable)
            _UnavailableNote(
              icon: icon,
              title: l10n.dshSurfaceUnavailable,
              hint: l10n.dshSurfaceUnavailableHint,
            ),
        ],
      ),
    );
  }
}

class _UnavailableNote extends StatelessWidget {
  const _UnavailableNote({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 40),
      child: Column(
        children: [
          Icon(icon, size: 28, color: cs.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}
