import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io' show Platform;
import '../../../icons/lucide_adapter.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';
import 'package:syncfusion_flutter_core/theme.dart';
import '../../../core/providers/settings_provider.dart';
import 'theme_settings_page.dart';
import '../../../theme/palettes.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../core/services/haptics.dart';
import '../widgets/display_setting_rows.dart';
import '../widgets/ios_settings_widgets.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

class DisplaySettingsPage extends StatefulWidget {
  const DisplaySettingsPage({super.key});

  @override
  State<DisplaySettingsPage> createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends State<DisplaySettingsPage> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    context.watch<SettingsProvider>();

    String paletteName() {
      final settings = context.read<SettingsProvider>();
      final palette = ThemePalettes.byId(settings.themePaletteId);
      final locale = Localizations.localeOf(context);
      return locale.languageCode == 'zh' &&
              (locale.scriptCode ?? '').toLowerCase() != 'hant'
          ? palette.displayNameZh
          : palette.displayNameEn;
    }

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
        title: Text(l10n.settingsPageDisplay),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          // header(l10n.displaySettingsPageThemeSettingsTitle),
          _iosSectionCard(
            children: [
              _iosNavRow(
                context,
                icon: Lucide.Palette,
                label: l10n.displaySettingsPageThemeSettingsTitle,
                detailText: paletteName(),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ThemeSettingsPage()),
                ),
              ),
              _iosDivider(context),
              const LanguageRow(),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.MessageCircleMore,
                label: l10n.displaySettingsPageChatItemDisplayTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ChatItemDisplaySettingsPage(),
                  ),
                ),
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.TextInitial,
                label: l10n.displaySettingsPageRenderingSettingsTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const RenderingSettingsPage(),
                  ),
                ),
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.eclipse,
                label: l10n.displaySettingsPageBehaviorStartupTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BehaviorStartupSettingsPage(),
                  ),
                ),
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.Vibrate,
                label: l10n.displaySettingsPageHapticsSettingsTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const HapticsSettingsPage(),
                  ),
                ),
              ),
              _iosDivider(context),
              if (BackgroundChatRow.supportedOn(defaultTargetPlatform)) ...[
                const BackgroundChatRow(),
                IosSettingsDivider(context),
              ],
              const ChatMessageBackgroundRow(),
              IosSettingsDivider(context),
              const AppFontRow(),
              IosSettingsDivider(context),
              const CodeFontRow(),
              IosSettingsDivider(context),
              const ChatFontSizeRow(),
              IosSettingsDivider(context),
              const AutoScrollIdleRow(),
              IosSettingsDivider(context),
              const ChatBackgroundMaskRow(),
              IosSettingsDivider(context),
              const ChatInputBackgroundOpacityRow(),
            ],
          ),
          // Inline cards replaced by sheet-triggering rows above.
        ],
      ),
    );
  }
}

// --- iOS-style helpers ---

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

Widget _sheetOption(
  BuildContext context, {
  IconData? icon,
  required String label,
  required VoidCallback onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return _TactileRow(
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

Widget _sheetDividerNoIcon(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 1,
    thickness: 0.6,
    indent: 16,
    endIndent: 16,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

Future<void> _showMobileMessageNavModeSheet(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final choice = await showModalBottomSheet<MobileMessageNavButtonsMode>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetOption(
              ctx,
              label: l10n.displaySettingsPageMessageNavButtonsModeAlways,
              onTap: () =>
                  Navigator.of(ctx).pop(MobileMessageNavButtonsMode.always),
            ),
            _sheetDividerNoIcon(ctx),
            _sheetOption(
              ctx,
              label: l10n.displaySettingsPageMessageNavButtonsModeScroll,
              onTap: () =>
                  Navigator.of(ctx).pop(MobileMessageNavButtonsMode.scroll),
            ),
            _sheetDividerNoIcon(ctx),
            _sheetOption(
              ctx,
              label: l10n.displaySettingsPageMessageNavButtonsModeNever,
              onTap: () =>
                  Navigator.of(ctx).pop(MobileMessageNavButtonsMode.never),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  if (!context.mounted) return;
  await context.read<SettingsProvider>().setMobileMessageNavButtonsMode(choice);
}

// --- Subpages ---

class ChatItemDisplaySettingsPage extends StatelessWidget {
  const ChatItemDisplaySettingsPage({super.key});
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
        title: Text(l10n.displaySettingsPageChatItemDisplayTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _iosSectionCard(
            children: [
              _iosSwitchRow(
                context,
                icon: Lucide.User,
                label: l10n.displaySettingsPageShowUserAvatarTitle,
                value: sp.showUserAvatar,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowUserAvatar(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.MessageCircle,
                label: l10n.displaySettingsPageShowUserNameTitle,
                value: sp.showUserName,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowUserName(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.clock,
                label: l10n.displaySettingsPageShowUserTimestampTitle,
                value: sp.showUserTimestamp,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowUserTimestamp(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Ellipsis,
                label: l10n.displaySettingsPageShowUserMessageActionsTitle,
                value: sp.showUserMessageActions,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setShowUserMessageActions(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Bot,
                label: l10n.displaySettingsPageChatModelIconTitle,
                value: sp.showModelIcon,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowModelIcon(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Bot,
                label: l10n.displaySettingsPageUseNewAssistantAvatarUxTitle,
                value: sp.useNewAssistantAvatarUx,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setUseNewAssistantAvatarUx(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.MessageSquare,
                label: l10n.displaySettingsPageShowModelNameTitle,
                value: sp.showModelName,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowModelName(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.clock,
                label: l10n.displaySettingsPageShowModelTimestampTitle,
                value: sp.showModelTimestamp,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowModelTimestamp(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Globe,
                label: l10n.displaySettingsPageShowProviderInChatMessageTitle,
                value: sp.showProviderInChatMessage,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setShowProviderInChatMessage(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Type,
                label: l10n.displaySettingsPageShowTokenStatsTitle,
                value: sp.showTokenStats,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowTokenStats(v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class RenderingSettingsPage extends StatelessWidget {
  const RenderingSettingsPage({super.key});
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
        title: Text(l10n.displaySettingsPageRenderingSettingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _iosSectionCard(
            children: [
              _iosSwitchRow(
                context,
                icon: Lucide.Hash,
                label: l10n.displaySettingsPageEnableDollarLatexTitle,
                value: sp.enableDollarLatex,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setEnableDollarLatex(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Code,
                label: l10n.displaySettingsPageEnableMathTitle,
                value: sp.enableMathRendering,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setEnableMathRendering(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.TextSelect,
                label: l10n.displaySettingsPageEnableUserMarkdownTitle,
                value: sp.enableUserMarkdown,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setEnableUserMarkdown(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Brain,
                label: l10n.displaySettingsPageEnableReasoningMarkdownTitle,
                value: sp.enableReasoningMarkdown,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setEnableReasoningMarkdown(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.MessageSquare,
                label: l10n.displaySettingsPageEnableAssistantMarkdownTitle,
                value: sp.enableAssistantMarkdown,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setEnableAssistantMarkdown(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.FoldVertical,
                label: l10n.displaySettingsPageAutoCollapseCodeBlockTitle,
                value: sp.autoCollapseCodeBlock,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setAutoCollapseCodeBlock(v),
              ),
              if (sp.autoCollapseCodeBlock) ...[
                _iosDivider(context),
                const _AutoCollapseCodeBlockLinesRow(),
              ],
              if (Platform.isAndroid || Platform.isIOS) ...[
                _iosDivider(context),
                _iosSwitchRow(
                  context,
                  icon: Lucide.WrapText,
                  label: l10n.displaySettingsPageMobileCodeBlockWrapTitle,
                  value: sp.mobileCodeBlockWrap,
                  onChanged: (v) => context
                      .read<SettingsProvider>()
                      .setMobileCodeBlockWrap(v),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _AutoCollapseCodeBlockLinesRow extends StatefulWidget {
  const _AutoCollapseCodeBlockLinesRow();
  @override
  State<_AutoCollapseCodeBlockLinesRow> createState() =>
      _AutoCollapseCodeBlockLinesRowState();
}

class _AutoCollapseCodeBlockLinesRowState
    extends State<_AutoCollapseCodeBlockLinesRow> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    final sp = context.read<SettingsProvider>();
    _controller = TextEditingController(
      text: '${sp.autoCollapseCodeBlockLines}',
    );
    _focusNode = FocusNode()
      ..addListener(() {
        if (!_focusNode.hasFocus) _commit();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit() {
    final sp = context.read<SettingsProvider>();
    final raw = _controller.text.trim();
    final parsed = int.tryParse(raw) ?? sp.autoCollapseCodeBlockLines;
    final next = parsed.clamp(1, 999);
    sp.setAutoCollapseCodeBlockLines(next);
    final text = '$next';
    if (_controller.text != text) {
      _controller.value = _controller.value.copyWith(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sp = context.watch<SettingsProvider>();

    // Keep controller in sync when not editing
    if (!_focusNode.hasFocus) {
      final t = '${sp.autoCollapseCodeBlockLines}';
      if (_controller.text != t) _controller.text = t;
    }

    final baseColor = cs.onSurface.withValues(alpha: 0.9);
    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(
        color: cs.outlineVariant.withValues(alpha: 0.28),
        width: 0.8,
      ),
    );
    final focusBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: cs.primary, width: 1.0),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Icon(Lucide.ListOrdered, size: 20, color: baseColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.displaySettingsPageAutoCollapseCodeBlockLinesTitle,
              style: TextStyle(fontSize: 15, color: baseColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IntrinsicWidth(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, maxWidth: 80),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: isDark ? Colors.white10 : Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: baseBorder,
                  enabledBorder: baseBorder,
                  focusedBorder: focusBorder,
                ),
                onSubmitted: (_) => _commit(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.displaySettingsPageAutoCollapseCodeBlockLinesUnit,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class BehaviorStartupSettingsPage extends StatelessWidget {
  const BehaviorStartupSettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
        title: Text(l10n.displaySettingsPageBehaviorStartupTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _iosSectionCard(
            children: [
              _iosSwitchRow(
                context,
                icon: Lucide.Brain,
                label: l10n.displaySettingsPageAutoCollapseThinkingTitle,
                value: sp.autoCollapseThinking,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setAutoCollapseThinking(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.ListTree,
                label: l10n.displaySettingsPageCollapseThinkingStepsTitle,
                value: sp.collapseThinkingSteps,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setCollapseThinkingSteps(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.FileText,
                label: l10n.displaySettingsPageShowToolResultSummaryTitle,
                value: sp.showToolResultSummary,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setShowToolResultSummary(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.TextSelect,
                label: l10n.displaySettingsPageInsertSuggestionOnlyTitle,
                value: sp.insertSuggestionOnTapOnly,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setInsertSuggestionOnTapOnly(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.RefreshCw,
                label: l10n
                    .displaySettingsPageRegenerateDeleteTrailingMessagesTitle,
                value: sp.regenerateDeleteTrailingMessages,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setRegenerateDeleteTrailingMessages(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.MessageCircleWarning,
                label: l10n.displaySettingsPageShowRegenerateConfirmDialogTitle,
                value: sp.showRegenerateConfirmDialog,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setShowRegenerateConfirmDialog(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.BadgeInfo,
                label: l10n.displaySettingsPageShowUpdatesTitle,
                value: sp.showAppUpdates,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowAppUpdates(v),
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.ChevronRight,
                label: l10n.displaySettingsPageMessageNavButtonsTitle,
                detailBuilder: (_) =>
                    Text(switch (sp.mobileMessageNavButtonsMode) {
                      MobileMessageNavButtonsMode.always =>
                        l10n.displaySettingsPageMessageNavButtonsModeAlways,
                      MobileMessageNavButtonsMode.scroll =>
                        l10n.displaySettingsPageMessageNavButtonsModeScroll,
                      MobileMessageNavButtonsMode.never =>
                        l10n.displaySettingsPageMessageNavButtonsModeNever,
                    }),
                onTap: () => _showMobileMessageNavModeSheet(context),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Calendar,
                label: l10n.displaySettingsPageShowChatListDateTitle,
                value: sp.showChatListDate,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setShowChatListDate(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Crop,
                label: l10n.displaySettingsPageEnableImageCropperTitle,
                subtitle: l10n.displaySettingsPageEnableImageCropperSubtitle,
                value: sp.imageCropperEnabled,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setImageCropperEnabled(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.panelLeft,
                label:
                    l10n.displaySettingsPageKeepSidebarOpenOnAssistantTapTitle,
                value: sp.keepSidebarOpenOnAssistantTap,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setKeepSidebarOpenOnAssistantTap(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.ListTree,
                label: l10n.displaySettingsPageKeepSidebarOpenOnTopicTapTitle,
                value: sp.keepSidebarOpenOnTopicTap,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setKeepSidebarOpenOnTopicTap(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.UnfoldVertical,
                label: l10n
                    .displaySettingsPageKeepAssistantListExpandedOnSidebarCloseTitle,
                value: sp.keepAssistantListExpandedOnSidebarClose,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setKeepAssistantListExpandedOnSidebarClose(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Shuffle,
                label: l10n.displaySettingsPageNewChatOnAssistantSwitchTitle,
                value: sp.newChatOnAssistantSwitch,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setNewChatOnAssistantSwitch(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Trash2,
                label: l10n.displaySettingsPageNewChatAfterDeleteTitle,
                value: sp.newChatAfterDelete,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setNewChatAfterDelete(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.MessageCirclePlus,
                label: l10n.displaySettingsPageNewChatOnLaunchTitle,
                value: sp.newChatOnLaunch,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setNewChatOnLaunch(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.CornerDownLeft,
                label: l10n.displaySettingsPageEnterToSendTitle,
                value: sp.enterToSendOnMobile,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setEnterToSendOnMobile(v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _iosSectionCard(
            children: [
              _iosSwitchRow(
                context,
                icon: Lucide.Zap,
                label: l10n.oneClickCompressEnabledTitle,
                subtitle: l10n.oneClickCompressEnabledSubtitle,
                value: sp.oneClickCompressEnabled,
                onChanged: (v) => context
                    .read<SettingsProvider>()
                    .setOneClickCompressEnabled(v),
              ),
              if (sp.oneClickCompressEnabled) ...[
                _iosDivider(context),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Lucide.Maximize, size: 20, color: cs.primary),
                          const SizedBox(width: 12),
                          Text(
                            l10n.oneClickCompressMaxLongEdgeTitle,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 15,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${sp.oneClickCompressMaxLongEdge}px',
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.6),
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SfSliderTheme(
                        data: SfSliderThemeData(
                          activeTrackHeight: 8,
                          inactiveTrackHeight: 8,
                          overlayRadius: 14,
                          activeTrackColor: cs.primary,
                          inactiveTrackColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.25 : 0.20,
                          ),
                          tooltipBackgroundColor: cs.primary,
                          tooltipTextStyle: TextStyle(
                            color: cs.onPrimary,
                            fontWeight: AppFontWeights.semibold,
                          ),
                          activeTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.45 : 0.35,
                          ),
                          inactiveTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.30 : 0.25,
                          ),
                          activeMinorTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.34 : 0.28,
                          ),
                          inactiveMinorTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.24 : 0.20,
                          ),
                        ),
                        child: SfSlider(
                          value: sp.oneClickCompressMaxLongEdge.toDouble(),
                          min: 768,
                          max: 4096,
                          stepSize: 256,
                          showTicks: true,
                          showLabels: true,
                          interval: 1024,
                          minorTicksPerInterval: 3,
                          enableTooltip: true,
                          shouldAlwaysShowTooltip: false,
                          tooltipShape: const SfPaddleTooltipShape(),
                          labelFormatterCallback: (value, text) =>
                              '${value.toInt()}px',
                          thumbIcon: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              shape: BoxShape.circle,
                              boxShadow: isDark
                                  ? []
                                  : [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.08,
                                        ),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                            ),
                          ),
                          onChanged: (v) => context
                              .read<SettingsProvider>()
                              .setOneClickCompressMaxLongEdge(
                                (v as double).round(),
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                _iosDivider(context),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Lucide.ImageDown, size: 20, color: cs.primary),
                          const SizedBox(width: 12),
                          Text(
                            l10n.oneClickCompressQualityTitle,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 15,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${sp.oneClickCompressQuality}%',
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.6),
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SfSliderTheme(
                        data: SfSliderThemeData(
                          activeTrackHeight: 8,
                          inactiveTrackHeight: 8,
                          overlayRadius: 14,
                          activeTrackColor: cs.primary,
                          inactiveTrackColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.25 : 0.20,
                          ),
                          tooltipBackgroundColor: cs.primary,
                          tooltipTextStyle: TextStyle(
                            color: cs.onPrimary,
                            fontWeight: AppFontWeights.semibold,
                          ),
                          activeTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.45 : 0.35,
                          ),
                          inactiveTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.30 : 0.25,
                          ),
                          activeMinorTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.34 : 0.28,
                          ),
                          inactiveMinorTickColor: cs.onSurface.withValues(
                            alpha: isDark ? 0.24 : 0.20,
                          ),
                        ),
                        child: SfSlider(
                          value: sp.oneClickCompressQuality.toDouble(),
                          min: 50,
                          max: 95,
                          stepSize: 5,
                          showTicks: true,
                          showLabels: true,
                          interval: 10,
                          minorTicksPerInterval: 1,
                          enableTooltip: true,
                          shouldAlwaysShowTooltip: false,
                          tooltipShape: const SfPaddleTooltipShape(),
                          labelFormatterCallback: (value, text) =>
                              '${value.toInt()}%',
                          thumbIcon: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              shape: BoxShape.circle,
                              boxShadow: isDark
                                  ? []
                                  : [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.08,
                                        ),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                            ),
                          ),
                          onChanged: (v) => context
                              .read<SettingsProvider>()
                              .setOneClickCompressQuality(
                                (v as double).round(),
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                _iosDivider(context),
                _iosSwitchRow(
                  context,
                  icon: Lucide.Image,
                  label: l10n.oneClickCompressAlwaysJpgTitle,
                  subtitle: l10n.oneClickCompressAlwaysJpgSubtitle,
                  value: sp.oneClickCompressAlwaysJpg,
                  onChanged: (v) => context
                      .read<SettingsProvider>()
                      .setOneClickCompressAlwaysJpg(v),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class HapticsSettingsPage extends StatelessWidget {
  const HapticsSettingsPage({super.key});
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
        title: Text(l10n.displaySettingsPageHapticsSettingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _iosSectionCard(
            children: [
              _iosSwitchRow(
                context,
                icon: Lucide.Vibrate,
                label: l10n.displaySettingsPageHapticsGlobalTitle,
                value: sp.hapticsGlobalEnabled,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setHapticsGlobalEnabled(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.toggleRight,
                label: l10n.displaySettingsPageHapticsIosSwitchTitle,
                value: sp.hapticsIosSwitch,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setHapticsIosSwitch(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.panelRight,
                label: l10n.displaySettingsPageHapticsOnSidebarTitle,
                value: sp.hapticsOnDrawer,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setHapticsOnDrawer(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.ListOrdered,
                label: l10n.displaySettingsPageHapticsOnListItemTapTitle,
                value: sp.hapticsOnListItemTap,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setHapticsOnListItemTap(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Square,
                label: l10n.displaySettingsPageHapticsOnCardTapTitle,
                value: sp.hapticsOnCardTap,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setHapticsOnCardTap(v),
              ),
              _iosDivider(context),
              _iosSwitchRow(
                context,
                icon: Lucide.Vibrate,
                label: l10n.displaySettingsPageHapticsOnGenerateTitle,
                value: sp.hapticsOnGenerate,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setHapticsOnGenerate(v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
