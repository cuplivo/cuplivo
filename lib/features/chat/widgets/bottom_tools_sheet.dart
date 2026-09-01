import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../home/utils/input_bar_button_layout.dart';
import '../../home/widgets/instruction_injection_sheet.dart';
import '../../home/widgets/world_book_sheet.dart';
import '../../instruction_injection/pages/instruction_injection_page.dart';
import '../../skills/pages/skills_page.dart';
import '../../world_book/pages/world_book_page.dart';

/// The mobile "More" bucket content.
///
/// Renders only the ids in [moreIds] (already resolved for this platform) for
/// which a callback/feature is actually available — the dynamic replacement
/// for the previously fixed row set.
class BottomToolsSheet extends StatelessWidget {
  const BottomToolsSheet({
    super.key,
    this.moreIds = const <String>[],
    this.onCustomize,
    this.onCamera,
    this.onPhotos,
    this.onUpload,
    this.onClear,
    this.clearLabel,
    this.assistantId,
    this.onDocumentProcessing,
    this.onOpenSkills,
    this.onSelectModel,
    this.onOpenSearch,
    this.onConfigureReasoning,
    this.onQuickPhrase,
    this.onOpenToolsHub,
    this.onConversationProactiveCare,
  });

  /// Bucket ids in configured order (resolved via
  /// `resolveInputBarButtonLayout` for this platform).
  final List<String> moreIds;
  final VoidCallback? onCustomize;
  final VoidCallback? onCamera;
  final VoidCallback? onPhotos;
  final VoidCallback? onUpload;
  final VoidCallback? onClear;
  final String? clearLabel;
  final String? assistantId;
  final VoidCallback? onDocumentProcessing;
  final VoidCallback? onOpenSkills;
  final VoidCallback? onSelectModel;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onConfigureReasoning;
  final VoidCallback? onQuickPhrase;
  final VoidCallback? onOpenToolsHub;
  final VoidCallback? onConversationProactiveCare;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bg = Theme.of(context).colorScheme.surface;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

    Widget roundedAction({
      required IconData icon,
      required String label,
      VoidCallback? onTap,
    }) {
      final cardColor = context.appColors.surfaceFill;
      return Expanded(
        child: SizedBox(
          height: 72,
          child: IosCardPress(
            baseColor: cardColor,
            borderRadius: BorderRadius.circular(14),
            pressedScale: 0.98,
            duration: const Duration(milliseconds: 260),
            onTap: () {
              Haptics.light();
              onTap?.call();
            },
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 24,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final gridIds = [
      for (final id in moreIds)
        if (id == inputBarButtonCamera ||
            id == inputBarButtonPhotos ||
            id == inputBarButtonUpload)
          id,
    ];

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (gridIds.isNotEmpty)
                      Row(
                        children: [
                          for (var i = 0; i < gridIds.length; i++) ...[
                            if (i > 0) const SizedBox(width: 12),
                            switch (gridIds[i]) {
                              inputBarButtonCamera => roundedAction(
                                icon: Lucide.Camera,
                                label: l10n.bottomToolsSheetCamera,
                                onTap: onCamera,
                              ),
                              inputBarButtonPhotos => roundedAction(
                                icon: Lucide.Image,
                                label: l10n.bottomToolsSheetPhotos,
                                onTap: onPhotos,
                              ),
                              _ => roundedAction(
                                icon: Lucide.Paperclip,
                                label: l10n.bottomToolsSheetUpload,
                                onTap: onUpload,
                              ),
                            },
                          ],
                        ],
                      ),
                    if (gridIds.isNotEmpty) const SizedBox(height: 12),
                    _BucketSection(
                      moreIds: moreIds,
                      clearLabel: clearLabel,
                      onClear: onClear,
                      assistantId: assistantId,
                      onDocumentProcessing: onDocumentProcessing,
                      onOpenSkills: onOpenSkills,
                      onSelectModel: onSelectModel,
                      onOpenSearch: onOpenSearch,
                      onConfigureReasoning: onConfigureReasoning,
                      onQuickPhrase: onQuickPhrase,
                      onOpenToolsHub: onOpenToolsHub,
                      onConversationProactiveCare: onConversationProactiveCare,
                      onCustomize: onCustomize,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BucketSection extends StatefulWidget {
  const _BucketSection({
    required this.moreIds,
    this.onClear,
    this.clearLabel,
    this.assistantId,
    this.onDocumentProcessing,
    this.onOpenSkills,
    this.onSelectModel,
    this.onOpenSearch,
    this.onConfigureReasoning,
    this.onQuickPhrase,
    this.onOpenToolsHub,
    this.onCustomize,
    this.onConversationProactiveCare,
  });
  final List<String> moreIds;
  final VoidCallback? onClear;
  final String? clearLabel;
  final String? assistantId;
  final VoidCallback? onDocumentProcessing;
  final VoidCallback? onOpenSkills;
  final VoidCallback? onSelectModel;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onConfigureReasoning;
  final VoidCallback? onQuickPhrase;
  final VoidCallback? onOpenToolsHub;
  final VoidCallback? onCustomize;
  final VoidCallback? onConversationProactiveCare;

  @override
  State<_BucketSection> createState() => _BucketSectionState();
}

class _BucketSectionState extends State<_BucketSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<WorldBookProvider>().initialize();
    });
  }

  Widget _row({
    required IconData icon,
    required String label,
    bool selected = false,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    Widget? trailing,
  }) {
    final cs = Theme.of(context).colorScheme;
    final onColor = selected ? cs.primary : cs.onSurface;
    final radius = BorderRadius.circular(14);
    return SizedBox(
      height: 48,
      child: IosCardPress(
        borderRadius: radius,
        baseColor: Theme.of(context).colorScheme.surface,
        duration: const Duration(milliseconds: 260),
        onTap: onTap,
        onLongPress: onLongPress,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: onColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.medium,
                  color: onColor,
                ),
              ),
            ),
            trailing ??
                (selected
                    ? Icon(Lucide.Check, size: 18, color: cs.primary)
                    : const SizedBox(width: 18)),
          ],
        ),
      ),
    );
  }

  Row _chevron(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Lucide.ChevronRight,
          size: 18,
          color: cs.onSurface.withValues(alpha: 0.55),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final worldBookProvider = context.watch<WorldBookProvider>();
    final hasWorldBooks = worldBookProvider.books.isNotEmpty;
    final ap = context.watch<AssistantProvider>();
    final assistant = widget.assistantId != null
        ? ap.getById(widget.assistantId!)
        : ap.currentAssistant;
    final skillsActive = assistant?.skillIds.isNotEmpty ?? false;

    final rows = <Widget>[];
    void addRow(Widget row) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(row);
    }

    for (final id in widget.moreIds) {
      switch (id) {
        case inputBarButtonSearch:
          if (widget.onOpenSearch == null) break;
          addRow(
            _row(
              icon: Lucide.Search,
              label: l10n.chatInputBarOnlineSearchTooltip,
              onTap: () {
                Haptics.light();
                widget.onOpenSearch?.call();
              },
            ),
          );
        case inputBarButtonReasoning:
          if (widget.onConfigureReasoning == null) break;
          addRow(
            _row(
              icon: Lucide.Brain,
              label: l10n.chatInputBarReasoningStrengthTooltip,
              onTap: () {
                Haptics.light();
                widget.onConfigureReasoning?.call();
              },
            ),
          );
        case inputBarButtonTools:
          if (widget.onOpenToolsHub == null) break;
          addRow(
            _row(
              icon: Lucide.Wrench,
              label: l10n.chatInputBarToolsTooltip,
              onTap: () {
                Haptics.light();
                widget.onOpenToolsHub?.call();
              },
            ),
          );
        case inputBarButtonQuickPhrase:
          if (widget.onQuickPhrase == null) break;
          addRow(
            _row(
              icon: Lucide.Zap,
              label: l10n.chatInputBarQuickPhraseTooltip,
              onTap: () {
                Haptics.light();
                widget.onQuickPhrase?.call();
              },
            ),
          );
        case inputBarButtonLearning:
          addRow(
            _row(
              icon: Lucide.Layers,
              label: l10n.instructionInjectionTitle,
              selected: false,
              onTap: () async {
                Haptics.light();
                await showInstructionInjectionSheet(
                  context,
                  assistantId: widget.assistantId,
                );
              },
              onLongPress: () {
                Haptics.light();
                final rootNav = Navigator.of(context, rootNavigator: true);
                Navigator.of(context).maybePop();
                Future.microtask(() {
                  rootNav.push(
                    MaterialPageRoute(
                      builder: (_) => const InstructionInjectionPage(),
                    ),
                  );
                });
              },
              trailing: _chevron(context),
            ),
          );
        case inputBarButtonWorldBook:
          if (!hasWorldBooks) break;
          addRow(
            _row(
              icon: Lucide.BookOpen,
              label: l10n.worldBookTitle,
              selected: false,
              onTap: () async {
                Haptics.light();
                await showWorldBookSheet(
                  context,
                  assistantId: widget.assistantId,
                );
              },
              onLongPress: () {
                Haptics.light();
                final rootNav = Navigator.of(context, rootNavigator: true);
                Navigator.of(context).maybePop();
                Future.microtask(() {
                  rootNav.push(
                    MaterialPageRoute(builder: (_) => const WorldBookPage()),
                  );
                });
              },
              trailing: _chevron(context),
            ),
          );
        case inputBarButtonSkills:
          addRow(
            _row(
              icon: Lucide.Sparkles,
              label: l10n.skillsTitle,
              selected: skillsActive,
              onTap: () {
                Haptics.light();
                widget.onOpenSkills?.call();
              },
              onLongPress: () {
                Haptics.light();
                final rootNav = Navigator.of(context, rootNavigator: true);
                Navigator.of(context).maybePop();
                Future.microtask(() {
                  rootNav.push(
                    MaterialPageRoute(builder: (_) => const SkillsPage()),
                  );
                });
              },
              trailing: _chevron(context),
            ),
          );
        case inputBarButtonDocument:
          if (widget.onDocumentProcessing == null) break;
          addRow(
            _row(
              icon: Lucide.FileText,
              label: l10n.documentProcessingTitle,
              selected: false,
              onTap: () async {
                Haptics.light();
                Navigator.of(context).maybePop();
                widget.onDocumentProcessing?.call();
              },
              trailing: _chevron(context),
            ),
          );
        case inputBarButtonContext:
          addRow(
            _row(
              icon: Lucide.workflow,
              label: l10n.contextManagement,
              onTap: () {
                Haptics.light();
                widget.onClear?.call();
              },
              trailing: _chevron(context),
            ),
          );
        case inputBarButtonModel:
          if (widget.onSelectModel == null) break;
          addRow(
            _row(
              icon: Lucide.Boxes,
              label: l10n.chatInputBarSelectModelTooltip,
              onTap: () {
                Haptics.light();
                widget.onSelectModel?.call();
              },
            ),
          );
        case inputBarButtonProactiveCare:
          if (widget.onConversationProactiveCare == null) break;
          addRow(
            _row(
              icon: Lucide.HeartPulse,
              label: l10n.conversationProactiveCareTitle,
              onTap: () {
                Haptics.light();
                widget.onConversationProactiveCare?.call();
              },
              trailing: _chevron(context),
            ),
          );
        case inputBarButtonCustomize:
          if (widget.onCustomize == null) break;
          addRow(
            _row(
              icon: Lucide.Settings2,
              label: l10n.chatInputBarCustomizeMenuAction,
              onTap: () {
                Haptics.light();
                widget.onCustomize?.call();
              },
            ),
          );
        default:
          break;
      }
    }

    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}
