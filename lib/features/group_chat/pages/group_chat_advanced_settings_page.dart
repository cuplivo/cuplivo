import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant_detail_injection.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_settings_section.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../model/widgets/model_select_sheet.dart';

class GroupChatAdvancedSettingsPage extends StatefulWidget {
  const GroupChatAdvancedSettingsPage({super.key, required this.groupChatId});
  final String groupChatId;

  @override
  State<GroupChatAdvancedSettingsPage> createState() =>
      _GroupChatAdvancedSettingsPageState();
}

class _GroupChatAdvancedSettingsPageState
    extends State<GroupChatAdvancedSettingsPage> {
  late TextEditingController _promptCtrl;
  late TextEditingController _maxCtrl;
  late TextEditingController _nCtrl;

  @override
  void initState() {
    super.initState();
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    _promptCtrl = TextEditingController(
      text: g?.directorSystemPrompt ?? GroupChat.defaultDirectorSystemPrompt,
    );
    _maxCtrl = TextEditingController(
      text: (g?.maxAssistantMessagesPerRound ?? 3).toString(),
    );
    _nCtrl = TextEditingController(
      text: (g?.assistantDetailInjectionN ?? 5).toString(),
    );
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _maxCtrl.dispose();
    _nCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final gp = context.watch<GroupChatProvider>();
    final settings = context.watch<SettingsProvider>();
    final group = gp.getById(widget.groupChatId);
    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.groupChatAdvancedSettings)),
        body: Center(child: Text(l10n.groupChatNotFound)),
      );
    }

    final modelLabel =
        (group.directorModelProvider == null || group.directorModelId == null)
        ? l10n.groupChatDirectorModelFollowGlobal
        : '${group.directorModelProvider}/${group.directorModelId}';

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.groupChatAdvancedSettings),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          _sectionHeader(context, l10n.groupChatAdvancedDirectorSection),
          const SizedBox(height: 10),
          IosSettingsSection(
            children: [
              IosSettingsNavRow(
                icon: Lucide.Bot,
                label: l10n.groupChatDirectorModel,
                detailText: modelLabel,
                onTap: () async {
                  final selected = await showModelSelector(context);
                  if (selected == null || !context.mounted) return;
                  if (selected.providerKey.isEmpty ||
                      selected.modelId.isEmpty) {
                    await gp.updateGroup(
                      group.copyWith(clearDirectorModel: true),
                    );
                  } else {
                    await gp.updateGroup(
                      group.copyWith(
                        directorModelProvider: selected.providerKey,
                        directorModelId: selected.modelId,
                      ),
                    );
                  }
                },
              ),
              IosSettingsDivider(),
              IosSettingsNavRow(
                icon: Lucide.RotateCcw,
                label: l10n.groupChatDirectorModelClear,
                onTap: () async {
                  await gp.updateGroup(
                    group.copyWith(clearDirectorModel: true),
                  );
                },
              ),
              IosSettingsDivider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: IosFormTextField(
                  label: l10n.groupChatDirectorSystemPrompt,
                  controller: _promptCtrl,
                  maxLines: 8,
                  minLines: 5,
                  onChanged: (v) async {
                    await gp.updateGroup(
                      group.copyWith(directorSystemPrompt: v),
                    );
                  },
                ),
              ),
              IosSettingsDivider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: _variablesBlock(context, l10n, cs, group, gp),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _sectionHeader(context, l10n.groupChatAdvancedAssistantSection),
          const SizedBox(height: 10),
          IosSettingsSection(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: IosFormTextField(
                  label: l10n.groupChatMaxAssistantMessages,
                  controller: _maxCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (v) async {
                    final n = int.tryParse(v) ?? 3;
                    await gp.updateGroup(
                      group.copyWith(
                        maxAssistantMessagesPerRound: n.clamp(1, 20),
                      ),
                    );
                  },
                ),
              ),
              IosSettingsDivider(),
              IosSettingsNavRow(
                icon: Lucide.MessageSquare,
                label: l10n.groupChatInjectionMode,
                detailText: _modeLabel(
                  l10n,
                  group.assistantDetailInjectionMode,
                ),
                onTap: () => _pickInjectionMode(context, group, gp),
              ),
              if (group.assistantDetailInjectionMode.needsN) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: IosFormTextField(
                    label: l10n.groupChatInjectionN,
                    controller: _nCtrl,
                    keyboardType: TextInputType.number,
                    onChanged: (v) async {
                      final n = int.tryParse(v) ?? 5;
                      await gp.updateGroup(
                        group.copyWith(
                          assistantDetailInjectionN: n.clamp(1, 100),
                        ),
                      );
                    },
                  ),
                ),
              ],
              IosSettingsDivider(),
              IosSettingsSwitchRow(
                icon: Lucide.User,
                label: l10n.groupChatInjectGroupMembersTitle,
                value: group.injectGroupMembersIntoAssistantSystemPrompt,
                onChanged: (v) async {
                  await gp.updateGroup(
                    group.copyWith(
                      injectGroupMembersIntoAssistantSystemPrompt: v,
                    ),
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.groupChatInjectGroupMembersDesc,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${l10n.groupChatDirectorModelFollowGlobal}: '
            '${settings.currentModelProvider}/${settings.currentModelId}',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      title,
      style: TextStyle(
        fontWeight: AppFontWeights.emphasis,
        color: cs.onSurface.withValues(alpha: 0.8),
      ),
    );
  }

  Widget _variablesBlock(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
    GroupChat group,
    GroupChatProvider gp,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.groupChatAvailableVariables,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: GroupChat.directorPromptVariables
              .map(
                (v) => GestureDetector(
                  onTap: () {
                    final t = _promptCtrl.text;
                    _promptCtrl.text = '$t$v';
                    _promptCtrl.selection = TextSelection.collapsed(
                      offset: _promptCtrl.text.length,
                    );
                    gp.updateGroup(
                      group.copyWith(directorSystemPrompt: _promptCtrl.text),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      v,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.primary,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Future<void> _pickInjectionMode(
    BuildContext context,
    GroupChat group,
    GroupChatProvider gp,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final selected = await showModalBottomSheet<AssistantDetailInjectionMode>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
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
                    l10n.groupChatInjectionMode,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...AssistantDetailInjectionMode.values.map((mode) {
                    final isSelected =
                        group.assistantDetailInjectionMode == mode;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        _modeLabel(l10n, mode),
                        style: TextStyle(
                          fontSize: 14,
                          color: isSelected
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Lucide.Check, size: 18, color: cs.primary)
                          : null,
                      onTap: () => Navigator.of(ctx).pop(mode),
                    );
                  }),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (selected == null || !context.mounted) return;
    await gp.updateGroup(
      group.copyWith(assistantDetailInjectionMode: selected),
    );
  }

  String _modeLabel(AppLocalizations l10n, AssistantDetailInjectionMode mode) {
    switch (mode) {
      case AssistantDetailInjectionMode.beforeSystemPrompt:
        return l10n.groupChatInjectionBeforeSystem;
      case AssistantDetailInjectionMode.appendIntoSystemPrompt:
        return l10n.groupChatInjectionAppendSystem;
      case AssistantDetailInjectionMode.endOfFirstUserMessage:
        return l10n.groupChatInjectionEndFirstUser;
      case AssistantDetailInjectionMode.endOfEveryUserMessage:
        return l10n.groupChatInjectionEndEveryUser;
      case AssistantDetailInjectionMode.endOfEveryUserAndAssistantMessage:
        return l10n.groupChatInjectionEndEveryUserAndAssistant;
      case AssistantDetailInjectionMode.everyNUserMessages:
        return l10n.groupChatInjectionEveryNUser;
      case AssistantDetailInjectionMode.everyNUserAndAssistantMessages:
        return l10n.groupChatInjectionEveryNUserAndAssistant;
    }
  }
}
