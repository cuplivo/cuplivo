import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../shared/widgets/section_card.dart';

/// The Markdown being written, in the reader's code face and never wrapped in
/// decoration the exported picture will not have.
class MarkdownExportEditor extends StatelessWidget {
  const MarkdownExportEditor({
    super.key,
    required this.controller,
    required this.hint,
  });

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final codeFont = settings.codeFontFamily;
    return SectionCard(
      radius: 14,
      padding: EdgeInsets.zero,
      child: TextField(
        controller: controller,
        expands: true,
        maxLines: null,
        minLines: null,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontFamily: (codeFont?.isNotEmpty ?? false) ? codeFont : 'monospace',
          fontSize: 13,
          height: 1.6,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        decoration: InputDecoration(
          hintText: hint,
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        ),
      ),
    );
  }
}
