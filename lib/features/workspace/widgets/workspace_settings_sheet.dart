import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/workspace.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/workspace/workspace_execution_context.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import 'workspace_directory_picker.dart';

Future<void> showWorkspaceSettingsSheet(
  BuildContext context, {
  required String assistantId,
  String? conversationId,
}) async {
  final workspaces = context.read<WorkspaceProvider>();
  await workspaces.init();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _WorkspaceSettingsSheet(
      assistantId: assistantId,
      conversationId: conversationId,
    ),
  );
}

class _WorkspaceSettingsSheet extends StatefulWidget {
  const _WorkspaceSettingsSheet({
    required this.assistantId,
    this.conversationId,
  });

  final String assistantId;
  final String? conversationId;

  @override
  State<_WorkspaceSettingsSheet> createState() =>
      _WorkspaceSettingsSheetState();
}

class _WorkspaceSettingsSheetState extends State<_WorkspaceSettingsSheet> {
  final TextEditingController _directoryController = TextEditingController();
  String? _selectedWorkspaceId;
  bool _initialized = false;
  bool _saving = false;
  bool _switchingWorkspace = false;

  bool get _conversationMode => widget.conversationId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final assistant = context.read<AssistantProvider>().getById(
      widget.assistantId,
    );
    final workspaces = context.read<WorkspaceProvider>();
    _selectedWorkspaceId =
        assistant?.workspaceId ?? workspaces.defaultWorkspace?.id;
    _syncDirectoryText(assistant);
    _initialized = true;
  }

  @override
  void dispose() {
    _directoryController.dispose();
    super.dispose();
  }

  Conversation? _conversation() {
    final id = widget.conversationId;
    if (id == null) return null;
    return context.read<ChatService>().getConversation(id);
  }

  String _assistantDefault(Assistant? assistant, String workspaceId) {
    return assistant?.workspaceDefaultDirectories[workspaceId] ?? '/workspace';
  }

  String _effectiveDirectory(Assistant? assistant, String workspaceId) {
    final conversation = _conversation();
    return conversation?.workspaceDirectoryOverrides[workspaceId] ??
        _assistantDefault(assistant, workspaceId);
  }

  void _syncDirectoryText(Assistant? assistant) {
    final workspaceId = _selectedWorkspaceId;
    if (workspaceId == null) {
      _directoryController.text = '/workspace';
      return;
    }
    _directoryController.text = _conversationMode
        ? _effectiveDirectory(assistant, workspaceId)
        : _assistantDefault(assistant, workspaceId);
  }

  Future<void> _updateAssistant(
    Assistant Function(Assistant current) update,
  ) async {
    final provider = context.read<AssistantProvider>();
    final current = provider.getById(widget.assistantId);
    if (current == null) return;
    await provider.updateAssistant(update(current));
  }

  Future<void> _selectWorkspace(Workspace workspace) async {
    if (_saving || _switchingWorkspace) return;
    final assistant = context.read<AssistantProvider>().getById(
      widget.assistantId,
    );
    setState(() {
      _switchingWorkspace = true;
      _selectedWorkspaceId = workspace.id;
      _syncDirectoryText(assistant);
    });
    try {
      await _updateAssistant(
        (current) => current.copyWith(workspaceId: workspace.id),
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to select workspace: $error\n$stackTrace');
      rethrow;
    } finally {
      if (mounted) setState(() => _switchingWorkspace = false);
    }
  }

  Future<void> _saveDirectory(String raw) async {
    final l10n = AppLocalizations.of(context)!;
    final workspaceId = _selectedWorkspaceId;
    final workspaces = context.read<WorkspaceProvider>();
    final workspace = workspaceId == null
        ? null
        : workspaces.getById(workspaceId);
    if (workspace == null || _saving || _switchingWorkspace) return;
    final chatService = _conversationMode ? context.read<ChatService>() : null;
    setState(() => _saving = true);
    try {
      final normalized = normalizeWorkspaceDirectory(raw);
      await ensureWorkspaceWorkingDirectory(
        context: WorkspaceExecutionContext(
          workspace: workspace,
          workingDirectory: normalized,
        ),
        workspaces: workspaces,
      );
      if (_conversationMode) {
        await chatService!.setConversationWorkspaceDirectoryOverride(
          widget.conversationId!,
          workspaceId!,
          normalized,
        );
      } else {
        await _updateAssistant((assistant) {
          final directories = Map<String, String>.of(
            assistant.workspaceDefaultDirectories,
          )..[workspaceId!] = normalized;
          return assistant.copyWith(workspaceDefaultDirectories: directories);
        });
      }
      if (!mounted) return;
      _directoryController.text = normalized;
      showAppSnackBar(
        context,
        message: l10n.workspaceDirectorySaved,
        type: NotificationType.success,
      );
      setState(() {});
    } catch (e, st) {
      debugPrint('Failed to save workspace working directory: $e\n$st');
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.workspaceDirectorySaveFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _browse() async {
    if (_saving || _switchingWorkspace) return;
    final workspaceId = _selectedWorkspaceId;
    final workspaces = context.read<WorkspaceProvider>();
    final workspace = workspaceId == null
        ? null
        : workspaces.getById(workspaceId);
    if (workspace == null) return;
    String initialDirectory;
    try {
      initialDirectory = normalizeWorkspaceDirectory(_directoryController.text);
      await ensureWorkspaceWorkingDirectory(
        context: WorkspaceExecutionContext(
          workspace: workspace,
          workingDirectory: initialDirectory,
        ),
        workspaces: workspaces,
      );
    } on WorkspacePathException catch (error, stackTrace) {
      debugPrint(
        'Workspace directory picker reset an unsafe initial path: '
        '$error\n$stackTrace',
      );
      initialDirectory = '/workspace';
    }
    if (!mounted) return;
    final selected = await showWorkspaceDirectoryPicker(
      context,
      workspace: workspace,
      workspaces: workspaces,
      initialDirectory: initialDirectory,
    );
    if (selected == null || !mounted) return;
    _directoryController.text = selected;
    await _saveDirectory(selected);
  }

  Future<void> _useAssistantDefault() async {
    final workspaceId = _selectedWorkspaceId;
    if (!_conversationMode ||
        workspaceId == null ||
        _saving ||
        _switchingWorkspace) {
      return;
    }
    await context
        .read<ChatService>()
        .clearConversationWorkspaceDirectoryOverride(
          widget.conversationId!,
          workspaceId,
        );
    if (!mounted) return;
    _syncDirectoryText(
      context.read<AssistantProvider>().getById(widget.assistantId),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final assistant = context.watch<AssistantProvider>().getById(
      widget.assistantId,
    );
    final workspaces = context.watch<WorkspaceProvider>();
    if (_conversationMode) context.watch<ChatService>();
    final workspaceId = _selectedWorkspaceId;
    final selectedWorkspace = workspaceId == null
        ? null
        : workspaces.getById(workspaceId);
    final conversation = _conversation();
    final hasOverride =
        workspaceId != null &&
        conversation?.workspaceDirectoryOverrides.containsKey(workspaceId) ==
            true;

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.workspaceSettingsTitle,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                  IosIconButton(
                    icon: Lucide.X,
                    semanticLabel: l10n.homePageCancel,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _WorkspaceCard(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.workspaceEnableTitle,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: AppFontWeights.medium,
                                ),
                              ),
                            ),
                            IosSwitch(
                              value: assistant?.workspaceEnabled ?? false,
                              onChanged: (enabled) => _updateAssistant(
                                (current) => current.copyWith(
                                  workspaceEnabled: enabled,
                                  workspaceId: _selectedWorkspaceId,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.workspaceBindTitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.62),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (workspaces.workspaces.isEmpty)
                      _WorkspaceCard(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(l10n.workspaceListEmpty),
                        ),
                      )
                    else
                      _WorkspaceCard(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: workspaces.workspaces.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: cs.onSurface.withValues(alpha: 0.08),
                            ),
                            itemBuilder: (_, index) {
                              final workspace = workspaces.workspaces[index];
                              final selected = workspace.id == workspaceId;
                              return IosCardPress(
                                baseColor: Colors.transparent,
                                borderRadius: BorderRadius.zero,
                                onTap: _saving || _switchingWorkspace
                                    ? null
                                    : () => _selectWorkspace(workspace),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 11,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Lucide.Folder, size: 20),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(workspace.displayName),
                                          Text(
                                            '@${workspace.alias}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: cs.onSurface.withValues(
                                                alpha: 0.55,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (selected)
                                      Icon(
                                        Lucide.Check,
                                        size: 18,
                                        color: cs.primary,
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    IosFormTextField(
                      label: _conversationMode
                          ? l10n.workspaceConversationDirectoryTitle
                          : l10n.workspaceDefaultDirectoryTitle,
                      controller: _directoryController,
                      hintText: l10n.workspaceDirectoryHint,
                      enabled: selectedWorkspace != null,
                      inlineLabel: false,
                      outerPadding: EdgeInsets.zero,
                    ),
                    if (_conversationMode && selectedWorkspace != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        hasOverride
                            ? l10n.workspaceDirectoryOverride
                            : l10n.workspaceDirectoryInherited,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.58),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: IosTileButton(
                            label: l10n.workspaceDirectoryBrowse,
                            icon: Lucide.FolderOpen,
                            enabled:
                                selectedWorkspace != null &&
                                !_saving &&
                                !_switchingWorkspace,
                            onTap: _browse,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: IosTileButton(
                            label: l10n.workspaceDirectorySave,
                            icon: Lucide.Check,
                            enabled:
                                selectedWorkspace != null &&
                                !_saving &&
                                !_switchingWorkspace,
                            backgroundColor: cs.primary,
                            onTap: () =>
                                _saveDirectory(_directoryController.text),
                          ),
                        ),
                      ],
                    ),
                    if (_conversationMode && hasOverride) ...[
                      const SizedBox(height: 10),
                      IosTileButton(
                        label: l10n.workspaceDirectoryUseAssistantDefault,
                        icon: Lucide.RotateCcw,
                        enabled: !_saving && !_switchingWorkspace,
                        onTap: _useAssistantDefault,
                      ),
                    ],
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

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}
