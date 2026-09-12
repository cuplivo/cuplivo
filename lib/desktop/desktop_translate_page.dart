import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

import '../icons/lucide_adapter.dart' as lucide;
import '../l10n/app_localizations.dart';
import '../utils/brand_assets.dart';
import '../core/providers/settings_provider.dart';
import '../core/providers/assistant_provider.dart';
import '../core/services/api/chat_api_service.dart';
import '../core/services/api/plain_text_collector.dart';
import '../shared/widgets/snackbar.dart';
import '../features/model/widgets/model_select_sheet.dart'
    show showModelSelector;
import '../features/settings/widgets/language_select_sheet.dart'
    show
        TranslateLanguageActionRow,
        effectiveTranslateLanguage,
        showTranslateLanguageManager,
        translateLanguageDisplayName,
        visibleTranslateLanguages;
import 'widgets/desktop_select_dropdown.dart';

class DesktopTranslatePage extends StatefulWidget {
  const DesktopTranslatePage({super.key});

  @override
  State<DesktopTranslatePage> createState() => _DesktopTranslatePageState();
}

class _DesktopTranslatePageState extends State<DesktopTranslatePage> {
  final TextEditingController _source = TextEditingController();
  final TextEditingController _output = TextEditingController();

  String? _modelProviderKey;
  String? _modelId;

  bool _translating = false;
  bool _stopped = false;
  String? _requestId;

  @override
  void initState() {
    super.initState();
    // Defer initializing model defaults until first frame to ensure providers are ready
    WidgetsBinding.instance.addPostFrameCallback((_) => _initDefaults());
  }

  @override
  void dispose() {
    ChatApiService.cancelRequest(_requestId ?? '');
    _source.dispose();
    _output.dispose();
    super.dispose();
  }

  void _initDefaults() {
    final settings = context.read<SettingsProvider>();
    final assistant = context.read<AssistantProvider>().currentAssistant;

    // Default model: translate model -> assistant's chat model -> global default
    final providerKey =
        settings.translateModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final modelId =
        settings.translateModelId ??
        assistant?.chatModelId ??
        settings.currentModelId;
    setState(() {
      _modelProviderKey = providerKey;
      _modelId = modelId;
    });
  }

  Future<void> _onLanguageSelected(String code) async {
    final settings = context.read<SettingsProvider>();
    final visible = visibleTranslateLanguages(
      settings.translateVisibleLanguages,
    );
    // The dropdown lists only visible entries, but a background visibility
    // change may race the tap; never persist a hidden target.
    if (!visible.any((l) => l.code == code)) return;
    await settings.setTranslateTargetLang(code);
  }

  Future<void> _pickModel() async {
    if (_translating) return; // avoid switching mid-stream
    final settings = context.read<SettingsProvider>();
    final sel = await showModelSelector(
      context,
      initialProviderKey: _modelProviderKey,
      initialModelId: _modelId,
    );
    if (!mounted) return;
    if (sel == null) return;

    setState(() {
      _modelProviderKey = sel.providerKey;
      _modelId = sel.modelId;
    });
    // Persist translate model selection so it’s remembered next time
    await settings.setTranslateModel(sel.providerKey, sel.modelId);
  }

  Future<void> _startTranslate() async {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.read<SettingsProvider>();

    final text = _source.text.trim();
    if (text.isEmpty) return;

    final providerKey = _modelProviderKey;
    final modelId = _modelId;
    if (providerKey == null || modelId == null) {
      showAppSnackBar(
        context,
        message: l10n.homePagePleaseSetupTranslateModel,
        type: NotificationType.warning,
      );
      return;
    }

    final cfg = settings.getProviderConfig(providerKey);

    final visible = visibleTranslateLanguages(
      settings.translateVisibleLanguages,
    );
    final lang = effectiveTranslateLanguage(
      visible: visible,
      persistedCode: settings.translateTargetLang,
      localeLanguageCode: Localizations.localeOf(context).languageCode,
    );
    final prompt = settings.translatePrompt
        .replaceAll('{source_text}', text)
        .replaceAll(
          '{target_lang}',
          translateLanguageDisplayName(l10n, lang.code),
        );

    setState(() {
      _translating = true;
      _output.text = '';
    });
    _stopped = false;

    try {
      _requestId = 'translate_${DateTime.now().millisecondsSinceEpoch}';
      // Layer-① collector (ADR-0034): accumulate + live-update the output.
      await PlainTextCollector().collect(
        config: cfg,
        modelId: modelId,
        messages: [
          {'role': 'user', 'content': prompt},
        ],
        requestId: _requestId,
        updateInterval: const Duration(milliseconds: 120),
        onAccumulated: (t) {
          if (!mounted || _stopped) return;
          setState(() {
            // Remove leading whitespace on the first chunk to avoid top gap.
            _output.text = t.replaceFirst(RegExp(r'^\s+'), '');
          });
        },
      );
      if (!mounted || _stopped) return;
      setState(() => _translating = false);
    } catch (e) {
      if (!mounted || _stopped) return;
      setState(() => _translating = false);
      showAppSnackBar(
        context,
        message: l10n.homePageTranslateFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _stopTranslate() async {
    _stopped = true;
    ChatApiService.cancelRequest(_requestId ?? '');
    if (mounted) setState(() => _translating = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    // Rebuild only when the visible set or the target actually changes.
    final (visibleCodes, targetCode) = context
        .select<SettingsProvider, (Set<String>, String?)>(
          (s) => (s.translateVisibleLanguages, s.translateTargetLang),
        );
    final visible = visibleTranslateLanguages(visibleCodes);
    final currentTarget = effectiveTranslateLanguage(
      visible: visible,
      persistedCode: targetCode,
      localeLanguageCode: Localizations.localeOf(context).languageCode,
    );

    final topBar = SizedBox(
      height: 36,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, top: 8),
          child: Text(
            l10n.desktopNavTranslateTooltip, // 显示“翻译”
            style: TextStyle(
              fontSize: 14,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );

    final brandAsset = (_modelId != null)
        ? BrandAssets.assetForName(_modelId!)
        : null;

    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          topBar,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 40,
                        child: Row(
                          children: [
                            // Language dropdown
                            DesktopSelectDropdown<String>(
                              value: currentTarget.code,
                              options: [
                                for (final lang in visible)
                                  DesktopSelectOption<String>(
                                    value: lang.code,
                                    label: translateLanguageDisplayName(
                                      l10n,
                                      lang.code,
                                    ),
                                    leading: lang.flag,
                                  ),
                              ],
                              minWidth: 150,
                              minHeight: 40,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 4,
                              ),
                              maxLabelWidth: 240,
                              triggerFillColor: context.appColors.surfaceCard,
                              onSelected: _onLanguageSelected,
                              footer: TranslateLanguageActionRow(
                                icon: lucide.Lucide.Settings2,
                                label: l10n.translateLanguageManagerTitle,
                                onTap: () =>
                                    showTranslateLanguageManager(context),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Translate / Stop button with animation
                            _TranslateButton(
                              translating: _translating,
                              onTranslate: _startTranslate,
                              onStop: _stopTranslate,
                            ),
                            const Spacer(),
                            // Model picker button (brand icon)
                            _ModelPickerButton(
                              asset: brandAsset,
                              modelId: _modelId,
                              onTap: _pickModel,
                              enabled: !_translating,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Two large rounded rectangles: input (left) and output (right)
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: _PaneContainer(
                                overlay: _PaneActionButton(
                                  icon: lucide.Lucide.Eraser,
                                  label: l10n.translatePageClearAll,
                                  onTap: () {
                                    _source.clear();
                                    _output.clear();
                                  },
                                ),
                                child: TextField(
                                  controller: _source,
                                  keyboardType: TextInputType.multiline,
                                  maxLines: null,
                                  expands: true,
                                  decoration: InputDecoration(
                                    hintText: l10n.translatePageInputHint,
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    contentPadding: const EdgeInsets.all(14),
                                  ),
                                  style: TextStyle(fontSize: 14.5, height: 1.4),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _PaneContainer(
                                overlay: _PaneActionButton(
                                  icon: lucide.Lucide.Copy,
                                  label: l10n.translatePageCopyResult,
                                  onTap: () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: _output.text),
                                    );
                                    if (!context.mounted) return;
                                    showAppSnackBar(
                                      context,
                                      message: l10n
                                          .chatMessageWidgetCopiedToClipboard,
                                      type: NotificationType.success,
                                    );
                                  },
                                ),
                                child: TextField(
                                  controller: _output,
                                  readOnly: true,
                                  keyboardType: TextInputType.multiline,
                                  maxLines: null,
                                  expands: true,
                                  decoration: InputDecoration(
                                    hintText: l10n.translatePageOutputHint,
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    contentPadding: const EdgeInsets.all(14),
                                  ),
                                  style: TextStyle(fontSize: 14.5, height: 1.4),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaneContainer extends StatelessWidget {
  const _PaneContainer({required this.child, this.overlay});
  final Widget child;
  final Widget? overlay;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.18),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
        if (overlay != null) Positioned(top: 8, right: 8, child: overlay!),
      ],
    );
  }
}

class _TranslateButton extends StatefulWidget {
  const _TranslateButton({
    required this.translating,
    required this.onTranslate,
    required this.onStop,
  });
  final bool translating;
  final VoidCallback onTranslate;
  final VoidCallback onStop;

  @override
  State<_TranslateButton> createState() => _TranslateButtonState();
}

class _TranslateButtonState extends State<_TranslateButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final fg = isDark ? Colors.black : Colors.white;
    final base = cs.primary;
    final bg = _hover ? base.withValues(alpha: 0.92) : base;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.translating ? widget.onStop : widget.onTranslate,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: widget.translating
                ? Row(
                    key: const ValueKey('stop'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        'assets/icons/stop.svg',
                        width: 16,
                        height: 16,
                        colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.chatMessageWidgetStopTooltip,
                        style: TextStyle(
                          color: fg,
                          fontSize: 13.5,
                          fontWeight: AppFontWeights.semibold,
                        ),
                      ),
                    ],
                  )
                : Row(
                    key: const ValueKey('translate'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(lucide.Lucide.Languages, size: 16, color: fg),
                      const SizedBox(width: 6),
                      Text(
                        l10n.chatMessageWidgetTranslateTooltip,
                        style: TextStyle(
                          color: fg,
                          fontSize: 13.5,
                          fontWeight: AppFontWeights.semibold,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ModelPickerButton extends StatelessWidget {
  const _ModelPickerButton({
    required this.asset,
    required this.modelId,
    required this.onTap,
    required this.enabled,
  });
  final String? asset;
  final String? modelId;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = enabled
        ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05)
        : Colors.transparent;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (asset != null)
                () {
                  if (asset!.toLowerCase().endsWith('.svg')) {
                    return SvgPicture.asset(asset!, width: 18, height: 18);
                  }
                  return Image.asset(asset!, width: 18, height: 18);
                }()
              else
                Icon(
                  lucide.Lucide.Bot,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.9),
                ),
              if (modelId != null) ...[
                const SizedBox(width: 8),
                Text(
                  modelId!,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PaneActionButton extends StatefulWidget {
  const _PaneActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_PaneActionButton> createState() => _PaneActionButtonState();
}

class _PaneActionButtonState extends State<_PaneActionButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.06)
        : Colors.transparent;
    final fg = cs.onSurface.withValues(alpha: 0.9);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        tooltip: widget.label,
        button: true,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.icon, size: 16, color: fg),
          ),
        ),
      ),
    );
  }
}
