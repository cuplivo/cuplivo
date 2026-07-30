import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/group_chat_settings.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../core/services/chat/model_capability_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../model/widgets/model_select_sheet.dart';
import '../group_chat_navigation.dart';

/// Advanced group chat settings (director model/prompt, turn limits, etc.).
class GroupAdvancedSettingsPage extends StatefulWidget {
  const GroupAdvancedSettingsPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupAdvancedSettingsPage> createState() =>
      _GroupAdvancedSettingsPageState();
}

class _GroupAdvancedSettingsPageState extends State<GroupAdvancedSettingsPage> {
  late GroupChatSettings _settings;
  late final TextEditingController _promptController;
  late final TextEditingController _maxController;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final g = context.read<GroupChatService>().getGroup(widget.groupId);
    _settings = g?.settings ?? GroupChatSettings.defaults;
    _promptController = TextEditingController(
      text: _settings.directorSystemPrompt ?? '',
    );
    _maxController = TextEditingController(
      text: '${_settings.maxAssistantMessagesPerUserTurn}',
    );
    _ready = true;
  }

  @override
  void dispose() {
    _promptController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  bool _modelSupportsTool(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) => ModelCapabilityService.supportsTools(settings, providerKey, modelId);

  Future<void> _pickDirectorModel() async {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.read<SettingsProvider>();
    final sel = await showModelSelector(
      context,
      initialProviderKey: _settings.directorModelProvider,
      initialModelId: _settings.directorModelId,
    );
    if (!mounted || sel == null) return;
    if (!_modelSupportsTool(settings, sel.providerKey, sel.modelId)) {
      showAppSnackBar(
        context,
        message: l10n.groupChatAdvancedDirectorModelNoTool,
        type: NotificationType.warning,
      );
      return;
    }
    setState(() {
      _settings = _settings.copyWith(
        directorModelProvider: sel.providerKey,
        directorModelId: sel.modelId,
      );
    });
  }

  Future<void> _clearDirectorModel() async {
    setState(() {
      _settings = _settings.copyWith(
        directorModelProvider: null,
        directorModelId: null,
      );
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final svc = context.read<GroupChatService>();
    final g = svc.getGroup(widget.groupId);
    if (g == null) return;

    final maxParsed = int.tryParse(_maxController.text.trim());
    final maxVal = (maxParsed == null || maxParsed < 1) ? 1 : maxParsed;
    final prompt = _promptController.text.trim();

    // Validate director model tool support if set.
    final settings = context.read<SettingsProvider>();
    final pk = _settings.directorModelProvider ?? settings.currentModelProvider;
    final mid = _settings.directorModelId ?? settings.currentModelId;
    if (pk != null && mid != null && mid.isNotEmpty) {
      if (!_modelSupportsTool(settings, pk, mid)) {
        showAppSnackBar(
          context,
          message: l10n.groupChatAdvancedDirectorModelNoTool,
          type: NotificationType.warning,
        );
        return;
      }
    }

    final next = _settings.copyWith(
      directorSystemPrompt: prompt.isEmpty ? null : prompt,
      maxAssistantMessagesPerUserTurn: maxVal,
    );

    await svc.updateGroup(g.copyWith(settings: next));
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: l10n.groupChatSettingsSave,
      type: NotificationType.success,
    );
    closeGroupPage(context);
  }

  String _directorModelLabel(SettingsProvider settings, AppLocalizations l10n) {
    final pk = _settings.directorModelProvider;
    final mid = _settings.directorModelId;
    if (pk == null || mid == null || mid.isEmpty) {
      return l10n.groupChatAdvancedDirectorModelDefault;
    }
    return '$pk / $mid';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final settings = context.watch<SettingsProvider>();
    if (!_ready) {
      return const Scaffold(body: SizedBox.shrink());
    }

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.groupChatBackTooltip,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            minSize: 44,
            onTap: () => closeGroupPage(context),
            semanticLabel: l10n.groupChatBackTooltip,
          ),
        ),
        title: Text(l10n.groupChatAdvancedTitle),
        actions: [
          Tooltip(
            message: l10n.groupChatSettingsSave,
            child: IosIconButton(
              icon: Lucide.Check,
              size: 22,
              minSize: 44,
              onTap: _save,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Text(
            l10n.groupChatAdvancedDirectorModel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.emphasis,
              color: cs.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.groupChatAdvancedDirectorModelHint,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 8),
          IosCardPress(
            borderRadius: BorderRadius.circular(14),
            baseColor: isDark
                ? Colors.white10
                : Colors.white.withValues(alpha: 0.96),
            onTap: _pickDirectorModel,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(Lucide.Boxes, size: 18, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _directorModelLabel(settings, l10n),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14.5),
                  ),
                ),
                if (_settings.directorModelId != null)
                  IosIconButton(
                    icon: Lucide.X,
                    size: 16,
                    onTap: _clearDirectorModel,
                    semanticLabel: l10n.groupChatAdvancedDirectorModelDefault,
                  ),
                Icon(
                  Lucide.ChevronRight,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.35),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _promptController,
            minLines: 4,
            maxLines: 10,
            decoration: InputDecoration(
              labelText: l10n.groupChatAdvancedDirectorPrompt,
              hintText: l10n.groupChatAdvancedDirectorPromptHint,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _maxController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.groupChatAdvancedMaxAssistantMessages,
            ),
          ),
          const SizedBox(height: 12),
          _SwitchRow(
            label: l10n.groupChatAdvancedAllowConsecutive,
            value: _settings.allowSameAssistantConsecutive,
            onChanged: (v) => setState(() {
              _settings = _settings.copyWith(allowSameAssistantConsecutive: v);
            }),
          ),
          _SwitchRow(
            label: l10n.groupChatAdvancedPersistDirector,
            value: _settings.persistDirectorTranscript,
            onChanged: (v) => setState(() {
              _settings = _settings.copyWith(persistDirectorTranscript: v);
            }),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14.5, height: 1.3),
            ),
          ),
          const SizedBox(width: 12),
          IosSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
