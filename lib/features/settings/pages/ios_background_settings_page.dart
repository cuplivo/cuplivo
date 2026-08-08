import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/ios_background_generation.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

class IosBackgroundSettingsPage extends StatefulWidget {
  const IosBackgroundSettingsPage({super.key});

  @override
  State<IosBackgroundSettingsPage> createState() =>
      _IosBackgroundSettingsPageState();
}

class _IosBackgroundSettingsPageState extends State<IosBackgroundSettingsPage> {
  late Future<IosBackgroundGenerationStatus> _statusFuture;

  @override
  void initState() {
    super.initState();
    _statusFuture = IosBackgroundGenerationService.instance.getStatus();
  }

  void _refreshStatus() {
    setState(() {
      _statusFuture = IosBackgroundGenerationService.instance.getStatus();
    });
  }

  Future<void> _setBackgroundNotificationsEnabled(bool enabled) async {
    final settings = context.read<SettingsProvider>();
    if (!enabled) {
      await settings.setIosBackgroundNotificationsEnabled(false);
      _refreshStatus();
      return;
    }

    final granted = await IosBackgroundGenerationService.instance
        .requestNotificationAuthorization();
    if (!mounted) return;
    await settings.setIosBackgroundNotificationsEnabled(granted);
    _refreshStatus();
  }

  Future<void> _openAppSettings() async {
    await IosBackgroundGenerationService.instance.openAppSettings();
    if (!mounted) return;
    _refreshStatus();
  }

  Future<void> _openNotificationSettings() async {
    await IosBackgroundGenerationService.instance.openNotificationSettings();
    if (!mounted) return;
    _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.iosBackgroundSettingsPageTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _noticeCard(
            context,
            title: l10n.iosBackgroundLimitNoticeTitle,
            body: l10n.iosBackgroundLimitNoticeBody,
          ),
          const SizedBox(height: 12),
          _iosSectionCard(
            children: [
              _iosSwitchRow(
                context,
                icon: Lucide.Activity,
                label: l10n.iosBackgroundGenerationEnableTitle,
                subtitle: l10n.iosBackgroundGenerationEnableSubtitle,
                value: sp.iosBackgroundGenerationEnabled,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setIosBackgroundGenerationEnabled(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.RefreshCw,
                label: l10n.iosBackgroundTaskRefreshTitle,
                subtitle: l10n.iosBackgroundTaskRefreshSubtitle,
                value: sp.iosBackgroundTaskRefreshEnabled,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setIosBackgroundTaskRefreshEnabled(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Timer,
                label: l10n.iosLiveActivityTitle,
                subtitle: l10n.iosLiveActivitySubtitle,
                value: sp.iosLiveActivityEnabled,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setIosLiveActivityEnabled(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.MessageCircle,
                label: l10n.iosBackgroundNotificationsTitle,
                subtitle: l10n.iosBackgroundNotificationsSubtitle,
                value: sp.iosBackgroundNotificationsEnabled,
                onChanged: _setBackgroundNotificationsEnabled,
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<IosBackgroundGenerationStatus>(
            future: _statusFuture,
            builder: (context, snapshot) {
              final status = snapshot.data;
              return _iosSectionCard(
                children: [
                  _iosNavRow(
                    context,
                    icon: Lucide.BadgeInfo,
                    label: l10n.iosBackgroundNativeStatusTitle,
                    detailText: status == null
                        ? l10n.iosBackgroundNativeStatusUnavailable
                        : status.liveActivitiesEnabled
                        ? l10n.iosBackgroundLiveActivityAvailable
                        : l10n.iosBackgroundLiveActivityUnavailable,
                    onTap: _openAppSettings,
                  ),
                  _iosDivider(context),
                  _iosNavRow(
                    context,
                    icon: Lucide.MessageCircle,
                    label: status?.notificationsAuthorized == true
                        ? l10n.iosBackgroundNotificationsAuthorized
                        : l10n.iosBackgroundNotificationsNotAuthorized,
                    onTap: _openNotificationSettings,
                  ),
                ],
              );
            },
          ),
          if (sp.iosLiveActivityEnabled) ...[
            const SizedBox(height: 12),
            _plainFootnote(context, l10n.iosBackgroundUnsupportedLiveActivity),
          ],
        ],
      ),
    );
  }
}

// --- iOS-style helpers (per-file copies, mirrors display_settings_page.dart) ---

class _AnimatedPressColor extends StatelessWidget {
  const _AnimatedPressColor({
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

class _TactileRow extends StatefulWidget {
  const _TactileRow({required this.builder, this.onTap, this.haptics = true});
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  final bool haptics;
  @override
  State<_TactileRow> createState() => _TactileRowState();
}

class _TactileRowState extends State<_TactileRow> {
  bool _pressed = false;
  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
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
    );
  }
}

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
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
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
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

Widget _iosSectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
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

Widget _iosDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

Widget _noticeCard(
  BuildContext context, {
  required String title,
  required String body,
}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: cs.primaryContainer.withValues(alpha: isDark ? 0.20 : 0.35),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cs.primary.withValues(alpha: 0.10), width: 0.6),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Lucide.BadgeInfo, size: 18, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.72),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _plainFootnote(BuildContext context, String text) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Text(
      text,
      style: TextStyle(
        color: cs.onSurface.withValues(alpha: 0.58),
        fontSize: 12,
        height: 1.35,
      ),
    ),
  );
}

Widget _iosNavRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  VoidCallback? onTap,
  String? detailText,
  Widget Function(BuildContext ctx)? detailBuilder,
}) {
  final cs = Theme.of(context).colorScheme;
  final interactive = onTap != null;
  return _TactileRow(
    onTap: onTap,
    haptics: true,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 15, color: c),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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

Widget _iosSwitchRow(
  BuildContext context, {
  IconData? icon,
  required String label,
  String? subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  final cs = Theme.of(context).colorScheme;
  return _TactileRow(
    onTap: () => onChanged(!value),
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: subtitle == null ? 2 : 8,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: TextStyle(fontSize: 15, color: c)),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            color: cs.onSurface.withValues(alpha: 0.56),
                          ),
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
        },
      );
    },
  );
}
