import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/quick_instruction.dart';
import '../../../core/models/workspace.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/instruction_injection_group_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/quick_instruction_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../features/home/services/local_tools_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/assistant_bind_multi_select.dart';
import '../../../shared/widgets/ios_expandable_section.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

class InstructionInjectionPage extends StatefulWidget {
  const InstructionInjectionPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<InstructionInjectionPage> createState() =>
      _InstructionInjectionPageState();
}

class _InstructionInjectionPageState extends State<InstructionInjectionPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<QuickInstructionProvider>().initialize();
    });
  }

  Future<void> _showAddEditSheet({QuickInstruction? item}) async {
    final cs = Theme.of(context).colorScheme;
    final provider = context.read<QuickInstructionProvider>();

    final result = await showModalBottomSheet<QuickInstructionEditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return InstructionInjectionEditSheet(item: item);
      },
    );

    if (!mounted) return;
    if (result == null) return;
    if (item != null &&
        ((item.isSystem && !result.item.isSystem) ||
            (item.isPersistent && !result.item.isPersistent))) {
      final allowed = await _confirmReferenceCleanup(item);
      if (allowed != true) return;
    }
    item == null
        ? await provider.add(result.item)
        : await provider.update(result.item);
    if (!mounted) return;
    await applyInjectionBindings(
      context,
      itemId: result.item.id,
      selectedAssistantIds: result.item.isSystem
          ? result.assistantIds
          : const <String>{},
    );
  }

  Future<bool?> _confirmReferenceCleanup(QuickInstruction item) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<QuickInstructionProvider>();
    final counts = await Future.wait<int>(<Future<int>>[
      provider.activeAssistantReferenceCount(item.id),
      provider.activeConversationReferenceCount(item.id),
    ]);
    if (!mounted) return false;
    if (counts.every((count) => count == 0)) return true;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.quickInstructionCleanupTitle),
        content: Text(
          l10n.quickInstructionCleanupMessage(counts[0], counts[1]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.quickPhraseCancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.quickInstructionContinueButton),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteItem(QuickInstruction item) async {
    final allowed = await _confirmReferenceCleanup(item);
    if (allowed != true || !mounted) return;
    await context.read<QuickInstructionProvider>().delete(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final provider = context.watch<QuickInstructionProvider>();
    final groupUi = context.watch<InstructionInjectionGroupProvider>();
    final items = provider.items;

    final Map<String, List<QuickInstruction>> grouped =
        <String, List<QuickInstruction>>{};
    for (final item in items) {
      final g = item.group.trim();
      (grouped[g] ??= <QuickInstruction>[]).add(item);
    }
    final groupNames = grouped.keys.toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.embedded
            ? null
            : Tooltip(
                message: l10n.instructionInjectionBackTooltip,
                child: _TactileIconButton(
                  icon: Lucide.ArrowLeft,
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 22,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
        title: Text(l10n.instructionInjectionTitle),
        actions: [
          Tooltip(
            message: l10n.instructionInjectionAddTooltip,
            child: _TactileIconButton(
              icon: Lucide.Plus,
              color: Theme.of(context).colorScheme.onSurface,
              size: 22,
              onTap: () => _showAddEditSheet(),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Lucide.Zap,
                    size: 64,
                    color: cs.onSurface.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.instructionInjectionEmptyMessage,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final groupName in groupNames) ...[
                  _GroupHeader(
                    title: groupName.trim().isEmpty
                        ? l10n.instructionInjectionUngroupedGroup
                        : groupName.trim(),
                    collapsed: groupUi.isCollapsed(groupName),
                    onToggle: () => context
                        .read<InstructionInjectionGroupProvider>()
                        .toggleCollapsed(groupName),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: groupUi.isCollapsed(groupName)
                        ? const SizedBox.shrink()
                        : ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: grouped[groupName]?.length ?? 0,
                            buildDefaultDragHandles: false,
                            proxyDecorator: (child, index, animation) {
                              return AnimatedBuilder(
                                animation: animation,
                                builder: (context, _) {
                                  final t = Curves.easeOut.transform(
                                    animation.value,
                                  );
                                  return Transform.scale(
                                    scale: 0.98 + 0.02 * t,
                                    child: child,
                                  );
                                },
                              );
                            },
                            onReorderItem: (oldIndex, newIndex) {
                              context
                                  .read<QuickInstructionProvider>()
                                  .reorderWithinGroup(
                                    group: groupName,
                                    oldIndex: oldIndex,
                                    newIndex: newIndex,
                                  );
                            },
                            itemBuilder: (context, index) {
                              final item = grouped[groupName]![index];
                              final displayTitle = item.title.trim().isEmpty
                                  ? l10n.instructionInjectionDefaultTitle
                                  : item.title;
                              return KeyedSubtree(
                                key: ValueKey(
                                  'reorder-instruction-injection-${item.id}',
                                ),
                                child: ReorderableDelayedDragStartListener(
                                  index: index,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Slidable(
                                      key: ValueKey(item.id),
                                      endActionPane: ActionPane(
                                        motion: const StretchMotion(),
                                        extentRatio: 0.35,
                                        children: [
                                          CustomSlidableAction(
                                            autoClose: true,
                                            backgroundColor: Colors.transparent,
                                            child: Container(
                                              width: double.infinity,
                                              height: double.infinity,
                                              decoration: BoxDecoration(
                                                color: isDark
                                                    ? cs.error.withValues(
                                                        alpha: 0.22,
                                                      )
                                                    : cs.error.withValues(
                                                        alpha: 0.14,
                                                      ),
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                                border: Border.all(
                                                  color: cs.error.withValues(
                                                    alpha: 0.35,
                                                  ),
                                                ),
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 8,
                                                  ),
                                              alignment: Alignment.center,
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Lucide.Trash2,
                                                      color: cs.error,
                                                      size: 18,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      l10n.quickPhraseDeleteButton,
                                                      style: TextStyle(
                                                        color: cs.error,
                                                        fontWeight:
                                                            AppFontWeights
                                                                .emphasis,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            onPressed: (_) => _deleteItem(item),
                                          ),
                                        ],
                                      ),
                                      child: _TactileCard(
                                        pressedScale: 0.98,
                                        onTap: () =>
                                            _showAddEditSheet(item: item),
                                        builder: (pressed, overlay) {
                                          final baseBg =
                                              context.appColors.surfaceCard;
                                          return Container(
                                            decoration: BoxDecoration(
                                              color: Color.alphaBlend(
                                                overlay,
                                                baseBg,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: cs.outlineVariant
                                                    .withValues(
                                                      alpha: isDark
                                                          ? 0.1
                                                          : 0.08,
                                                    ),
                                                width: 0.6,
                                              ),
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(14),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.center,
                                                children: [
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Icon(
                                                              Lucide.Zap,
                                                              size: 18,
                                                              color: cs.primary,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Expanded(
                                                              child: Text(
                                                                displayTitle,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: TextStyle(
                                                                  fontSize: 15,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        Text(
                                                          item.prompt,
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            fontSize: 13,
                                                            color:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onSurface
                                                                    .withValues(
                                                                      alpha:
                                                                          0.7,
                                                                    ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Icon(
                                                    Lucide.ChevronRight,
                                                    size: 16,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(alpha: 0.5),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.collapsed,
    required this.onToggle,
  });

  final String title;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textBase = cs.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Center(
                child: AnimatedRotation(
                  turns: collapsed ? 0.0 : 0.25,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Lucide.ChevronRight,
                    size: 16,
                    color: textBase.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: AppFontWeights.emphasis,
                  color: textBase,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class QuickInstructionEditResult {
  const QuickInstructionEditResult({
    required this.item,
    required this.assistantIds,
  });

  final QuickInstruction item;
  final Set<String> assistantIds;
}

class InstructionInjectionEditSheet extends StatefulWidget {
  const InstructionInjectionEditSheet({super.key, required this.item});

  final QuickInstruction? item;

  @override
  State<InstructionInjectionEditSheet> createState() =>
      _InstructionInjectionEditSheetState();
}

class _InstructionInjectionEditSheetState
    extends State<InstructionInjectionEditSheet> {
  static const List<String> _localToolIds = LocalToolNames.toolsHubManaged;

  late final TextEditingController _titleController;
  late final TextEditingController _groupController;
  late final TextEditingController _promptController;
  late final TextEditingController _blockController;
  late QuickInstructionPlacement _placement;
  late QuickInstructionTriggerMode _triggerMode;
  late bool _retainInHistory;
  late bool _toolPolicyEnabled;
  late bool _shellDisabled;
  late Set<String> _disabledLocalToolIds;
  late Set<String> _disabledMcpServerIds;
  late Set<String> _disabledFilesystemToolNames;
  Set<String> _assistantSelection = <String>{};
  bool _advancedExpanded = false;
  bool _placementExpanded = false;
  bool _triggerExpanded = false;
  bool _localToolsExpanded = false;
  bool _mcpExpanded = false;
  bool _filesystemExpanded = false;
  bool _commandLimitsExpanded = false;
  bool _showValidationErrors = false;
  bool _assistantSelectionInitialized = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _titleController = TextEditingController(text: item?.title ?? '');
    _groupController = TextEditingController(text: item?.group ?? '');
    _promptController = TextEditingController(text: item?.prompt ?? '');
    _placement = item?.placement ?? QuickInstructionPlacement.beforeUserMessage;
    _triggerMode = item?.triggerMode ?? QuickInstructionTriggerMode.oneShot;
    _retainInHistory = item?.retainInHistory ?? true;
    final policy = item?.toolPolicy ?? QuickInstructionToolPolicy();
    _toolPolicyEnabled = policy.enabled;
    _shellDisabled = policy.shellDisabled;
    _disabledLocalToolIds = policy.disabledLocalToolIds.toSet();
    _disabledMcpServerIds = policy.disabledMcpServerIds.toSet();
    _disabledFilesystemToolNames = policy.disabledFilesystemToolNames.toSet();
    _blockController = TextEditingController(
      text: policy.shellBlockPatterns.join('\n'),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_assistantSelectionInitialized) return;
    _assistantSelectionInitialized = true;
    final itemId = widget.item?.id;
    if (itemId == null) return;
    final provider = context.read<QuickInstructionProvider>();
    _assistantSelection = {
      for (final assistant in context.read<AssistantProvider>().assistants)
        if (assistant.id.isNotEmpty &&
            provider.activeIdsFor(assistant.id).contains(itemId))
          assistant.id,
    };
  }

  @override
  void dispose() {
    _titleController.dispose();
    _groupController.dispose();
    _promptController.dispose();
    _blockController.dispose();
    super.dispose();
  }

  List<String> _patterns(TextEditingController controller) {
    return controller.text
        .split(RegExp(r'\r?\n'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  void _save() {
    final title = _titleController.text.trim();
    final prompt = _promptController.text.trim();
    if (title.isEmpty || prompt.isEmpty) {
      setState(() => _showValidationErrors = true);
      return;
    }
    final item = QuickInstruction(
      id: widget.item?.id ?? const Uuid().v4(),
      title: title,
      prompt: prompt,
      group: _groupController.text.trim(),
      placement: _placement,
      triggerMode: _triggerMode,
      retainInHistory: _retainInHistory,
      toolPolicy: QuickInstructionToolPolicy(
        enabled: _toolPolicyEnabled,
        disabledLocalToolIds: _disabledLocalToolIds.toList(growable: false),
        disabledMcpServerIds: _disabledMcpServerIds.toList(growable: false),
        disabledFilesystemToolNames: _disabledFilesystemToolNames.toList(
          growable: false,
        ),
        shellDisabled: _shellDisabled,
        shellBlockPatterns: _patterns(_blockController),
      ),
    );
    Navigator.of(context).pop(
      QuickInstructionEditResult(
        item: item,
        assistantIds: Set<String>.from(_assistantSelection),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final inputBox = _placement == QuickInstructionPlacement.inputBox;
    final userPlacement =
        _placement == QuickInstructionPlacement.beforeUserMessage ||
        _placement == QuickInstructionPlacement.afterUserMessage;
    final toolsEnabled = _toolPolicyEnabled && !inputBox;

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.94,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.item == null
                    ? l10n.instructionInjectionAddTitle
                    : l10n.instructionInjectionEditTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      TextField(
                        controller: _titleController,
                        autofocus: true,
                        decoration: _fieldDecoration(
                          context,
                          label: l10n.instructionInjectionNameLabel,
                          errorText:
                              _showValidationErrors &&
                                  _titleController.text.trim().isEmpty
                              ? l10n.quickInstructionRequiredField
                              : null,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _groupController,
                        decoration: _fieldDecoration(
                          context,
                          label: l10n.instructionInjectionGroupLabel,
                          hint: l10n.instructionInjectionGroupHint,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _promptController,
                        minLines: 4,
                        maxLines: 8,
                        decoration: _fieldDecoration(
                          context,
                          label: l10n.instructionInjectionPromptLabel,
                          alignLabelWithHint: true,
                          errorText:
                              _showValidationErrors &&
                                  _promptController.text.trim().isEmpty
                              ? l10n.quickInstructionRequiredField
                              : null,
                        ),
                      ),
                      const SizedBox(height: 14),
                      IosExpandableSection(
                        icon: Lucide.Settings2,
                        title: l10n.quickInstructionAdvancedSettings,
                        expanded: _advancedExpanded,
                        onToggle: () => setState(
                          () => _advancedExpanded = !_advancedExpanded,
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                            child: Column(
                              children: [
                                IosExpandableSection(
                                  icon: Lucide.ListOrdered,
                                  title: l10n.quickInstructionPlacementTitle,
                                  expanded: _placementExpanded,
                                  onToggle: () => setState(
                                    () => _placementExpanded =
                                        !_placementExpanded,
                                  ),
                                  children: [
                                    for (final placement
                                        in QuickInstructionPlacement.values)
                                      _OptionRow(
                                        title: _placementLabel(l10n, placement),
                                        selected: _placement == placement,
                                        onTap: () => setState(
                                          () => _placement = placement,
                                        ),
                                      ),
                                  ],
                                ),
                                if (!inputBox) ...[
                                  const SizedBox(height: 10),
                                  IosExpandableSection(
                                    icon: Lucide.Zap,
                                    title: l10n.quickInstructionTriggerTitle,
                                    expanded: _triggerExpanded,
                                    onToggle: () => setState(
                                      () =>
                                          _triggerExpanded = !_triggerExpanded,
                                    ),
                                    children: [
                                      if (_placement ==
                                          QuickInstructionPlacement
                                              .systemPrompt)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: AssistantBindMultiSelect(
                                            itemId: widget.item?.id,
                                            activeIdsFor: context
                                                .watch<
                                                  QuickInstructionProvider
                                                >()
                                                .activeIdsFor,
                                            onSelectionChanged: (selection) =>
                                                _assistantSelection = selection,
                                          ),
                                        )
                                      else ...[
                                        _OptionRow(
                                          title: l10n
                                              .quickInstructionTriggerOneShot,
                                          selected:
                                              _triggerMode ==
                                              QuickInstructionTriggerMode
                                                  .oneShot,
                                          onTap: () => setState(
                                            () => _triggerMode =
                                                QuickInstructionTriggerMode
                                                    .oneShot,
                                          ),
                                        ),
                                        _OptionRow(
                                          title: l10n
                                              .quickInstructionTriggerPersistent,
                                          selected:
                                              _triggerMode ==
                                              QuickInstructionTriggerMode
                                                  .persistent,
                                          onTap: () => setState(
                                            () => _triggerMode =
                                                QuickInstructionTriggerMode
                                                    .persistent,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                                if (userPlacement) ...[
                                  const SizedBox(height: 10),
                                  _SwitchRow(
                                    title:
                                        l10n.quickInstructionRetainHistoryTitle,
                                    subtitle: l10n
                                        .quickInstructionRetainHistorySubtitle,
                                    value: _retainInHistory,
                                    onChanged: (value) => setState(
                                      () => _retainInHistory = value,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 10),
                                Opacity(
                                  opacity: inputBox ? 0.45 : 1,
                                  child: _SwitchRow(
                                    title: l10n
                                        .quickInstructionToolRestrictionTitle,
                                    subtitle: inputBox
                                        ? l10n.quickInstructionInputBoxNoTools
                                        : l10n.quickInstructionToolRestrictionSubtitle,
                                    value: _toolPolicyEnabled,
                                    onChanged: inputBox
                                        ? null
                                        : (value) => setState(
                                            () => _toolPolicyEnabled = value,
                                          ),
                                  ),
                                ),
                                if (_toolPolicyEnabled) ...[
                                  const SizedBox(height: 10),
                                  Opacity(
                                    opacity: toolsEnabled ? 1 : 0.45,
                                    child: IgnorePointer(
                                      ignoring: !toolsEnabled,
                                      child: _buildToolSettings(context),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _IosOutlineButton(
                      label: l10n.quickPhraseCancelButton,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _IosFilledButton(
                      label: l10n.quickPhraseSaveButton,
                      onTap: _save,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolSettings(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final mcp = context.watch<McpProvider>();
    return Column(
      children: [
        IosExpandableSection(
          icon: Lucide.Wrench,
          title: l10n.quickInstructionLocalToolsTitle,
          expanded: _localToolsExpanded,
          onToggle: () =>
              setState(() => _localToolsExpanded = !_localToolsExpanded),
          children: [
            _InfoRow(text: l10n.quickInstructionSwitchOnMeansDisabled),
            for (final id in _localToolIds)
              _SwitchRow(
                title: _localToolLabel(l10n, id),
                subtitle: _localToolSupported(id)
                    ? id
                    : l10n.quickInstructionToolUnavailable(id),
                value: _disabledLocalToolIds.contains(id),
                onChanged: (value) => setState(() {
                  value
                      ? _disabledLocalToolIds.add(id)
                      : _disabledLocalToolIds.remove(id);
                }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        IosExpandableSection(
          icon: Lucide.Network,
          title: l10n.quickInstructionMcpServersTitle,
          expanded: _mcpExpanded,
          onToggle: () => setState(() => _mcpExpanded = !_mcpExpanded),
          children: [
            _InfoRow(text: l10n.quickInstructionSwitchOnMeansDisabled),
            if (mcp.servers.isEmpty)
              _InfoRow(text: l10n.quickInstructionNoMcpServers)
            else
              for (final server in mcp.servers)
                _SwitchRow(
                  title: server.name,
                  subtitle: mcp.statusFor(server.id) == McpStatus.connected
                      ? server.id
                      : l10n.quickInstructionMcpOffline(server.id),
                  value: _disabledMcpServerIds.contains(server.id),
                  onChanged: (value) => setState(() {
                    value
                        ? _disabledMcpServerIds.add(server.id)
                        : _disabledMcpServerIds.remove(server.id);
                  }),
                ),
          ],
        ),
        const SizedBox(height: 10),
        IosExpandableSection(
          icon: Lucide.Folder,
          title: l10n.quickInstructionFilesystemToolsTitle,
          expanded: _filesystemExpanded,
          onToggle: () =>
              setState(() => _filesystemExpanded = !_filesystemExpanded),
          children: [
            _InfoRow(text: l10n.quickInstructionSwitchOnMeansDisabled),
            for (final name in WorkspaceToolNames.filesystemTools)
              _SwitchRow(
                title: _filesystemToolLabel(l10n, name),
                subtitle: name,
                value: _disabledFilesystemToolNames.contains(name),
                onChanged: (value) => setState(() {
                  value
                      ? _disabledFilesystemToolNames.add(name)
                      : _disabledFilesystemToolNames.remove(name);
                }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _SwitchRow(
          title: l10n.quickInstructionDisableShellTitle,
          subtitle: l10n.quickInstructionSwitchOnMeansDisabled,
          value: _shellDisabled,
          onChanged: (value) => setState(() => _shellDisabled = value),
        ),
        const SizedBox(height: 10),
        Opacity(
          opacity: _shellDisabled ? 0.45 : 1,
          child: IgnorePointer(
            ignoring: _shellDisabled,
            child: IosExpandableSection(
              icon: Lucide.Terminal,
              title: l10n.quickInstructionCommandLimitsTitle,
              expanded: _commandLimitsExpanded,
              onToggle: () => setState(
                () => _commandLimitsExpanded = !_commandLimitsExpanded,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Column(
                    children: [
                      TextField(
                        controller: _blockController,
                        minLines: 3,
                        maxLines: 6,
                        decoration: _fieldDecoration(
                          context,
                          label: l10n.quickInstructionCommandBlocklist,
                          hint: l10n.quickInstructionCommandPatternHint,
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

InputDecoration _fieldDecoration(
  BuildContext context, {
  required String label,
  String? hint,
  String? errorText,
  bool alignLabelWithHint = false,
}) {
  final cs = Theme.of(context).colorScheme;
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    errorText: errorText,
    alignLabelWithHint: alignLabelWithHint,
    filled: true,
    fillColor: context.appColors.surfaceFill,
    border: border,
    enabledBorder: border,
    focusedBorder: border.copyWith(
      borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.5)),
    ),
  );
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      haptics: false,
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(child: Text(title)),
          Icon(
            selected ? Lucide.CheckCircle : Lucide.eclipse,
            size: 19,
            color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.58),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          IosSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

String _placementLabel(
  AppLocalizations l10n,
  QuickInstructionPlacement placement,
) => switch (placement) {
  QuickInstructionPlacement.systemPrompt =>
    l10n.quickInstructionPlacementSystem,
  QuickInstructionPlacement.beforeUserMessage =>
    l10n.quickInstructionPlacementBeforeUser,
  QuickInstructionPlacement.afterUserMessage =>
    l10n.quickInstructionPlacementAfterUser,
  QuickInstructionPlacement.inputBox => l10n.quickInstructionPlacementInputBox,
};

String _localToolLabel(AppLocalizations l10n, String id) => switch (id) {
  LocalToolNames.timeInfo => l10n.assistantEditLocalToolTimeInfoTitle,
  LocalToolNames.clipboard => l10n.assistantEditLocalToolClipboardTitle,
  LocalToolNames.textToSpeech => l10n.assistantEditLocalToolTextToSpeechTitle,
  LocalToolNames.askUser => l10n.assistantEditLocalToolAskUserTitle,
  LocalToolNames.calculate => l10n.assistantEditLocalToolCalculateTitle,
  LocalToolNames.screenTime => l10n.assistantEditLocalToolScreenTimeTitle,
  LocalToolNames.calendarQuery => l10n.assistantEditLocalToolCalendarQueryTitle,
  LocalToolNames.calendarCreate =>
    l10n.assistantEditLocalToolCalendarCreateTitle,
  LocalToolNames.handoff => l10n.assistantEditLocalToolHandoffTitle,
  _ => id,
};

bool _localToolSupported(String id) => switch (id) {
  LocalToolNames.screenTime => DeviceLocalTools.screenTimeSupported,
  LocalToolNames.calendarQuery ||
  LocalToolNames.calendarCreate => DeviceLocalTools.calendarSupported,
  _ => true,
};

String _filesystemToolLabel(AppLocalizations l10n, String name) =>
    switch (name) {
      WorkspaceToolNames.read => l10n.workspaceToolReadTitle,
      WorkspaceToolNames.write => l10n.workspaceToolWriteTitle,
      WorkspaceToolNames.patch => l10n.workspaceToolPatchTitle,
      WorkspaceToolNames.delete => l10n.workspaceToolDeleteTitle,
      WorkspaceToolNames.glob => l10n.workspaceToolGlobTitle,
      WorkspaceToolNames.grep => l10n.workspaceToolGrepTitle,
      WorkspaceToolNames.outline => l10n.workspaceToolOutlineTitle,
      WorkspaceToolNames.mkdir => l10n.workspaceToolMkdirTitle,
      WorkspaceToolNames.move => l10n.workspaceToolMoveTitle,
      WorkspaceToolNames.zip => l10n.workspaceToolZipTitle,
      WorkspaceToolNames.unzip => l10n.workspaceToolUnzipTitle,
      WorkspaceToolNames.download => l10n.workspaceToolDownloadTitle,
      _ => name,
    };

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
    final press = base.withValues(alpha: 0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.light();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          widget.icon,
          size: widget.size,
          color: _pressed ? press : base,
        ),
      ),
    );
  }
}

class _TactileCard extends StatefulWidget {
  const _TactileCard({
    required this.builder,
    this.onTap,
    this.pressedScale = 0.98,
  });
  final Widget Function(bool pressed, Color overlay) builder;
  final VoidCallback? onTap;
  final double pressedScale;

  @override
  State<_TactileCard> createState() => _TactileCardState();
}

class _TactileCardState extends State<_TactileCard> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlay = _pressed
        ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05)
        : Colors.transparent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null
          ? null
          : (_) => Future.delayed(
              const Duration(milliseconds: 120),
              () => _set(false),
            ),
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              Haptics.soft();
              widget.onTap!.call();
            },
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.builder(_pressed, overlay),
      ),
    );
  }
}

class _IosOutlineButton extends StatefulWidget {
  const _IosOutlineButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_IosOutlineButton> createState() => _IosOutlineButtonState();
}

class _IosOutlineButtonState extends State<_IosOutlineButton> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: AppFontWeights.semibold,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

class _IosFilledButton extends StatefulWidget {
  const _IosFilledButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_IosFilledButton> createState() => _IosFilledButtonState();
}

class _IosFilledButtonState extends State<_IosFilledButton> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: cs.primary,
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onPrimary,
              fontWeight: AppFontWeights.semibold,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
