import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart';
import 'ios_switch.dart';

/// An iOS-style settings card: rounded container with a subtle border used by
/// settings surfaces (mirrors the section-card look of the assistant edit page).
class IosSettingsSection extends StatelessWidget {
  const IosSettingsSection({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
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
  }
}

/// Thin hairline divider inside an [IosSettingsSection].
class IosSettingsDivider extends StatelessWidget {
  const IosSettingsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 6,
      thickness: 0.6,
      indent: 54,
      endIndent: 12,
      color: cs.outlineVariant.withValues(alpha: 0.18),
    );
  }
}

/// A tappable settings row with a leading icon, label, optional detail and a
/// chevron — matches the assistant edit page's row style.
class IosSettingsNavRow extends StatelessWidget {
  const IosSettingsNavRow({
    super.key,
    required this.icon,
    required this.label,
    this.detailText,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? detailText;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final interactive = onTap != null;
    return _SettingsTactileRow(
      onTap: onTap,
      builder: (pressed) {
        final c = _rowColor(
          context,
          cs.onSurface.withValues(alpha: 0.9),
          pressed,
        );
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (detailText != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    detailText!,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (trailing != null) trailing!,
              if (interactive) Icon(Lucide.ChevronRight, size: 16, color: c),
            ],
          ),
        );
      },
    );
  }
}

/// A settings row with a leading icon, label and an [IosSwitch].
class IosSettingsSwitchRow extends StatelessWidget {
  const IosSettingsSwitchRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _SettingsTactileRow(
      onTap: () => onChanged(!value),
      builder: (pressed) {
        final c = _rowColor(
          context,
          cs.onSurface.withValues(alpha: 0.9),
          pressed,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 15, color: c)),
              ),
              IosSwitch(value: value, onChanged: onChanged),
            ],
          ),
        );
      },
    );
  }
}

/// Subtle press tint used by the rows (dark→black on light, light→white on
/// dark), mirroring the assistant edit page's row feedback. No Material ripple.
Color _rowColor(BuildContext context, Color base, bool pressed) {
  if (!pressed) return base;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Color.lerp(base, isDark ? Colors.white : Colors.black, 0.55) ?? base;
}

/// Tactile press wrapper used by [IosSettingsNavRow] and
/// [IosSettingsSwitchRow].
class _SettingsTactileRow extends StatefulWidget {
  const _SettingsTactileRow({required this.builder, this.onTap});

  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;

  @override
  State<_SettingsTactileRow> createState() => _SettingsTactileRowState();
}

class _SettingsTactileRowState extends State<_SettingsTactileRow> {
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
      onTap: widget.onTap,
      child: widget.builder(_pressed),
    );
  }
}
