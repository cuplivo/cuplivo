// ignore_for_file: non_constant_identifier_names

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/storage/storage_usage_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/format.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// Shared iOS-style shell for settings pages: Scaffold + AppBar with a
/// tactile back button, optional subtitle and actions, and a ListView body.
class IosSettingsPage extends StatelessWidget {
  const IosSettingsPage({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosTactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: subtitle == null
            ? Text(title)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
        actions: [...actions],
      ),
      body: SafeArea(
        bottom: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          children: children,
        ),
      ),
    );
  }
}

/// iOS-style section header (neutral color, not theme color).
Widget IosSettingsHeader(
  BuildContext context,
  String text, {
  bool first = false,
}) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: EdgeInsets.fromLTRB(12, first ? 2 : 12, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: AppFontWeights.semibold,
        color: cs.onSurface.withValues(alpha: 0.8),
      ),
    ),
  );
}

/// iOS-style grouped section card with rounded corners and subtle border.
Widget IosSettingsSectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      // Light: white with slight transparency; Dark: subtle translucent dark
      final Color bg = isDark
          ? Colors.white10
          : Colors.white.withValues(alpha: 0.96);
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: children),
        ),
      );
    },
  );
}

Widget IosSettingsDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  // Align with icon slot (36) + gap (12) + padding (12)
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

/// Shared color tween wrapper to mimic iOS gentle press color transition.
class IosAnimatedPressColor extends StatelessWidget {
  const IosAnimatedPressColor({
    super.key,
    required this.pressed,
    required this.base,
    required this.builder,
  });
  final bool pressed;
  final Color base;
  final Widget Function(Color color) builder;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final target = pressed
        ? (Color.lerp(base, isDark ? Colors.black : Colors.white, 0.55) ?? base)
        : base;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, color, _) => builder(color ?? base),
    );
  }
}

/// Tactile row without Material ripple; haptics follow the app setting.
class IosTactileRow extends StatefulWidget {
  const IosTactileRow({
    super.key,
    required this.builder,
    this.onTap,
    this.haptics = true,
  });
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  final bool haptics;
  @override
  State<IosTactileRow> createState() => _IosTactileRowState();
}

class _IosTactileRowState extends State<IosTactileRow> {
  bool _pressed = false;
  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;
    return Semantics(
      button: interactive,
      enabled: interactive,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
        onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
        onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptics &&
                    context.read<SettingsProvider>().hapticsOnListItemTap) {
                  Haptics.soft();
                }
                widget.onTap!.call();
              },
        child: widget.builder(_pressed),
      ),
    );
  }
}

/// Icon-only tactile button for AppBar: no ripple, slight press scale.
class IosTactileIconButton extends StatefulWidget {
  const IosTactileIconButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  State<IosTactileIconButton> createState() => _IosTactileIconButtonState();
}

class _IosTactileIconButtonState extends State<IosTactileIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final pressColor = base.withValues(alpha: 0.7);
    final icon = Icon(
      widget.icon,
      size: widget.size,
      color: _pressed ? pressColor : base,
    );

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          Haptics.light();
          widget.onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: icon,
        ),
      ),
    );
  }
}

/// Navigation row with icon, optional label column (label + description),
/// optional detail text/builder, and chevron when tappable.
Widget IosSettingsNavRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  String? description,
  VoidCallback? onTap,
  String? detailText,
  Widget Function(BuildContext ctx)? detailBuilder,
}) {
  final cs = Theme.of(context).colorScheme;
  final interactive = onTap != null;
  return IosTactileRow(
    onTap: onTap,
    haptics: true,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return IosAnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                const SizedBox(width: 12),
                Expanded(
                  child: description == null
                      ? Text(
                          label,
                          style: TextStyle(
                            fontSize: 15,
                            color: c,
                            fontWeight: AppFontWeights.medium,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 15,
                                color: c,
                                fontWeight: AppFontWeights.medium,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              description,
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
                if (detailBuilder != null)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: DefaultTextStyle.merge(
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                          child: detailBuilder(context),
                        ),
                      ),
                    ),
                  )
                else if (detailText != null)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          detailText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (interactive) Icon(Lucide.ChevronRight, size: 16, color: c),
              ],
            ),
          );
        },
      );
    },
  );
}

/// Bottom sheet iOS-style option with tactile feedback (no ripple).
Widget IosSettingsSheetOption(
  BuildContext context, {
  IconData? icon,
  required String label,
  required VoidCallback onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return IosTactileRow(
    onTap: onTap,
    builder: (pressed) {
      final base = cs.onSurface;
      final target = pressed
          ? (Color.lerp(base, isDark ? Colors.black : Colors.white, 0.55) ??
                base)
          : base;
      final bgTarget = pressed
          ? (isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.05))
          : Colors.transparent;
      return TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: target),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        builder: (context, color, _) {
          final c = color ?? base;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            color: bgTarget,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                if (icon != null) ...[
                  SizedBox(width: 24, child: Icon(icon, size: 20, color: c)),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 15, color: c)),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Widget IosSettingsSheetDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 1,
    thickness: 0.6,
    indent: 16,
    endIndent: 16,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

/// Row with a label (and optional description) on the left and an
/// [IosSwitch] on the right. No Material ripple.
class IosSettingsSwitchRow extends StatelessWidget {
  const IosSettingsSwitchRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (description != null && description!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    description!,
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
          const SizedBox(width: 12),
          IosSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Chat storage usage summary shown as a row detail.
class ChatStorageSummaryDetail extends StatefulWidget {
  const ChatStorageSummaryDetail({super.key});

  @override
  State<ChatStorageSummaryDetail> createState() =>
      _ChatStorageSummaryDetailState();
}

class _ChatStorageSummaryDetailState extends State<ChatStorageSummaryDetail> {
  late Future<StorageUsageReport> _future;

  @override
  void initState() {
    super.initState();
    _future = StorageUsageService.computeReport();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      color: cs.onSurface.withValues(alpha: 0.6),
      fontSize: 13,
    );

    return FutureBuilder<StorageUsageReport>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return Text(l10n.settingsPageCalculating, style: style);
        }
        if (snapshot.hasError) {
          return Text(l10n.settingsPageFilesCount(0, '--'), style: style);
        }
        final count = data?.totalFiles ?? 0;
        final size = formatBytes(data?.totalBytes ?? 0);
        return Text(l10n.settingsPageFilesCount(count, size), style: style);
      },
    );
  }
}

void showComingSoonSnackBar(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  showAppSnackBar(context, message: l10n.newSettingsComingSoonMessage);
}

/// Row that surfaces a "Coming Soon" detail and a snackbar on tap.
Widget IosComingSoonRow(
  BuildContext context, {
  required IconData icon,
  required String label,
}) {
  final l10n = AppLocalizations.of(context)!;
  return IosSettingsNavRow(
    context,
    icon: icon,
    label: label,
    detailText: l10n.newSettingsComingSoon,
    onTap: () => showComingSoonSnackBar(context),
  );
}
