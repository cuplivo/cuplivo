import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:system_fonts/system_fonts.dart';

import '../../core/providers/settings_provider.dart';
import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';

/// Shows the desktop system font chooser dialog (searchable list of
/// system-installed font families). Selecting a family applies it to the
/// app font ([codeFont] == false) or the code font ([codeFont] == true)
/// via [SettingsProvider.setAppFontSystemFamily] /
/// [SettingsProvider.setCodeFontSystemFamily].
Future<void> showSystemFontChooserDialog(
  BuildContext context, {
  required bool codeFont,
}) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final rootNavigator = Navigator.of(context, rootNavigator: true);
  final ctrl = TextEditingController();
  final settingsProvider = context.read<SettingsProvider>();
  final initial = codeFont
      ? settingsProvider.codeFontFamily
      : settingsProvider.appFontFamily;
  final title = codeFont ? l10n.desktopFontCodeLabel : l10n.desktopFontAppLabel;

  Future<List<String>> fetchSystemFonts() async {
    try {
      final sf = SystemFonts();
      // Only fetch the font family list to avoid huge memory spikes.
      final fontList = await Future.value(sf.getFontList());
      final out = List<String>.from(fontList);
      out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (out.isNotEmpty) {
        return out;
      }
    } catch (e) {
      debugPrint('showSystemFontChooserDialog: fetch font list failed: $e');
    }
    return <String>[
      'System UI',
      'Segoe UI',
      'SF Pro Text',
      'San Francisco',
      'Helvetica Neue',
      'Arial',
      'Roboto',
      'PingFang SC',
      'Microsoft YaHei',
      'SimHei',
      'Noto Sans SC',
      'Noto Serif',
      'Courier New',
      'JetBrains Mono',
      'Fira Code',
      'monospace',
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  // Show loading dialog only if fetch takes time, and ensure it closes
  bool loadingShown = false;
  final loadingTimer = Timer(const Duration(milliseconds: 300), () {
    if (!context.mounted) return;
    loadingShown = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
        final cs2 = Theme.of(ctx).colorScheme;
        return Dialog(
          elevation: 0,
          backgroundColor: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const CupertinoActivityIndicator(radius: 12),
                const SizedBox(height: 12),
                Text(
                  l10n.desktopFontLoading,
                  style: TextStyle(
                    color: cs2.onSurface,
                    fontSize: 14,
                    fontWeight: AppFontWeights.semibold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  });
  final fonts = await fetchSystemFonts();
  if (loadingTimer.isActive) {
    loadingTimer.cancel();
  }
  if (loadingShown) {
    try {
      rootNavigator.pop();
    } catch (e) {
      debugPrint(
        'showSystemFontChooserDialog: dismiss loading dialog failed: $e',
      );
    }
  }
  if (!context.mounted) {
    ctrl.dispose();
    return;
  }
  final fam = await showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return Dialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: StatefulBuilder(
              builder: (context, setState) {
                String q = ctrl.text.trim().toLowerCase();
                final filtered = q.isEmpty
                    ? fonts
                    : fonts.where((f) => f.toLowerCase().contains(q)).toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: AppFontWeights.emphasis,
                            ),
                          ),
                        ),
                        _CloseIconButton(
                          onTap: () => Navigator.of(ctx).maybePop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        hintText: l10n.desktopFontFilterHint,
                        fillColor:
                            Theme.of(context).brightness == Brightness.dark
                            ? Colors.white10
                            : const Color(0xFFF7F7F9),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant
                                .withValues(alpha: 0.12),
                            width: 0.6,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant
                                .withValues(alpha: 0.12),
                            width: 0.6,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.35),
                            width: 0.8,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white10
                              : Colors.black.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, i) {
                            final fam = filtered[i];
                            final selected = fam == initial;
                            return _FontRowItem(
                              family: fam,
                              selected: selected,
                              onTap: () => Navigator.of(ctx).pop(fam),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    },
  );
  ctrl.dispose();
  if (fam == null) return;
  if (!context.mounted) return;
  if (codeFont) {
    await settingsProvider.setCodeFontSystemFamily(fam);
  } else {
    await settingsProvider.setAppFontSystemFamily(fam);
  }
}

/// Close icon button for the dialog (hover highlight, no ripple).
class _CloseIconButton extends StatefulWidget {
  const _CloseIconButton({required this.onTap});
  final VoidCallback onTap;
  @override
  State<_CloseIconButton> createState() => _CloseIconButtonState();
}

class _CloseIconButtonState extends State<_CloseIconButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05))
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(lucide.Lucide.X, size: 18, color: cs.onSurface),
        ),
      ),
    );
  }
}

class _FontRowItem extends StatefulWidget {
  const _FontRowItem({
    required this.family,
    required this.onTap,
    this.selected = false,
  });
  final String family;
  final VoidCallback onTap;
  final bool selected;
  @override
  State<_FontRowItem> createState() => _FontRowItemState();
}

// Cache loaded/ongoing system fonts to avoid duplicate loads
final Set<String> _loadedSystemFontFamilies = <String>{};
final Set<String> _loadingSystemFontFamilies = <String>{};

class _FontRowItemState extends State<_FontRowItem> {
  bool _hover = false;
  @override
  void initState() {
    super.initState();
    // Lazy-load this row's font family for preview (only for visible items)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final fam = widget.family;
      if (_loadedSystemFontFamilies.contains(fam) ||
          _loadingSystemFontFamilies.contains(fam)) {
        return;
      }
      _loadingSystemFontFamilies.add(fam);
      try {
        await SystemFonts().loadFont(fam);
        // Cache only successful loads so a failed family can be retried.
        // Preview fonts are intentionally cached for the session (no unload
        // API); the set is never evicted or capped.
        _loadedSystemFontFamilies.add(fam);
      } catch (e) {
        // best-effort; fallback rendering will be used if load fails
        debugPrint('showSystemFontChooserDialog: load font $fam failed: $e');
      } finally {
        _loadingSystemFontFamilies.remove(fam);
        if (mounted) setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04))
        : Colors.transparent;
    final sample = 'Aa字';
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.family,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      sample,
                      style: TextStyle(
                        fontFamily: widget.family,
                        fontSize: 16,
                        color: cs.onSurface,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.selected) ...[
                const SizedBox(width: 10),
                Icon(lucide.Lucide.Check, size: 16, color: cs.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
