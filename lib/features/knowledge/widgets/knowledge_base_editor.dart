import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/assistant_bind_multi_select.dart';
import '../../../shared/widgets/ios_form_text_field.dart';

/// Values collected by [showKnowledgeBaseEditor].
class KnowledgeBaseDraft {
  final String name;
  final String description;
  final int chunkSize;
  final int chunkOverlap;

  /// The assistant ids the base should be bound to (full selection). Empty when
  /// the editor was opened without the bindings section.
  final Set<String> selectedAssistantIds;

  const KnowledgeBaseDraft({
    required this.name,
    required this.description,
    required this.chunkSize,
    required this.chunkOverlap,
    this.selectedAssistantIds = const <String>{},
  });
}

const int kKnowledgeMinChunkSize = 32;

/// Shared create/edit dialog used by the mobile pages and the desktop pane.
///
/// When [activeAssistantIdsFor] is provided, the dialog also shows the
/// "enable for which assistants" checklist and reports the full selection in
/// [KnowledgeBaseDraft.selectedAssistantIds].
Future<KnowledgeBaseDraft?> showKnowledgeBaseEditor(
  BuildContext context, {
  String? itemId,
  String name = '',
  String description = '',
  int chunkSize = 512,
  int chunkOverlap = 64,
  List<String> Function(String? assistantId)? activeAssistantIdsFor,
}) {
  return showDialog<KnowledgeBaseDraft>(
    context: context,
    builder: (ctx) => _KnowledgeBaseEditorDialog(
      itemId: itemId,
      name: name,
      description: description,
      chunkSize: chunkSize,
      chunkOverlap: chunkOverlap,
      activeAssistantIdsFor: activeAssistantIdsFor,
    ),
  );
}

/// Shared destructive-action confirmation.
Future<bool> confirmKnowledgeAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final cs = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(AppLocalizations.of(ctx)!.knowledgeCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel, style: TextStyle(color: cs.error)),
        ),
      ],
    ),
  );
  return result == true;
}

class _KnowledgeBaseEditorDialog extends StatefulWidget {
  const _KnowledgeBaseEditorDialog({
    required this.itemId,
    required this.name,
    required this.description,
    required this.chunkSize,
    required this.chunkOverlap,
    required this.activeAssistantIdsFor,
  });

  final String? itemId;
  final String name;
  final String description;
  final int chunkSize;
  final int chunkOverlap;
  final List<String> Function(String? assistantId)? activeAssistantIdsFor;

  @override
  State<_KnowledgeBaseEditorDialog> createState() =>
      _KnowledgeBaseEditorDialogState();
}

class _KnowledgeBaseEditorDialogState
    extends State<_KnowledgeBaseEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _chunkSizeController;
  late final TextEditingController _chunkOverlapController;
  Set<String> _selectedAssistantIds = <String>{};

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    _descriptionController = TextEditingController(text: widget.description);
    _chunkSizeController = TextEditingController(text: '${widget.chunkSize}');
    _chunkOverlapController = TextEditingController(
      text: '${widget.chunkOverlap}',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _chunkSizeController.dispose();
    _chunkOverlapController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final parsedSize =
        int.tryParse(_chunkSizeController.text.trim()) ?? widget.chunkSize;
    final chunkSize = parsedSize < kKnowledgeMinChunkSize
        ? kKnowledgeMinChunkSize
        : parsedSize;
    final parsedOverlap =
        int.tryParse(_chunkOverlapController.text.trim()) ??
        widget.chunkOverlap;
    final chunkOverlap = parsedOverlap.clamp(0, chunkSize - 1);

    Navigator.of(context).pop(
      KnowledgeBaseDraft(
        name: name,
        description: _descriptionController.text.trim(),
        chunkSize: chunkSize,
        chunkOverlap: chunkOverlap,
        selectedAssistantIds: _selectedAssistantIds,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        widget.name.trim().isEmpty
            ? l10n.knowledgeCreateTitle
            : l10n.knowledgeEditTitle,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IosFormTextField(
              label: l10n.knowledgeNameLabel,
              hintText: l10n.knowledgeNameHint,
              controller: _nameController,
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            IosFormTextField(
              label: l10n.knowledgeDescriptionLabel,
              controller: _descriptionController,
              maxLines: 2,
            ),
            IosFormTextField(
              label: l10n.knowledgeChunkSizeLabel,
              controller: _chunkSizeController,
              keyboardType: TextInputType.number,
            ),
            IosFormTextField(
              label: l10n.knowledgeChunkOverlapLabel,
              controller: _chunkOverlapController,
              keyboardType: TextInputType.number,
            ),
            if (widget.activeAssistantIdsFor != null) ...[
              const SizedBox(height: 10),
              AssistantBindMultiSelect(
                itemId: widget.itemId,
                activeIdsFor: widget.activeAssistantIdsFor!,
                onSelectionChanged: (selected) =>
                    _selectedAssistantIds = selected,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.knowledgeCancel),
        ),
        TextButton(
          onPressed: _nameController.text.trim().isEmpty ? null : _save,
          child: Text(l10n.knowledgeSave, style: TextStyle(color: cs.primary)),
        ),
      ],
    );
  }
}
