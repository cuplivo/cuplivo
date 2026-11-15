import 'package:flutter/material.dart';

import '../../features/markdown_export/pages/markdown_export_page.dart';
import '../../features/settings/pages/storage_space_page.dart';
import '../../features/translate/pages/translate_page.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';

/// The screens that are tools rather than conversation surfaces.
///
/// Both entry points — the drawer footer and the desktop rail — offer exactly
/// this list in this order, so a new tool is one edit here plus one screen, not
/// two lists that drift apart.
enum AppTool { translate, storage, markdownImage }

extension AppToolPresentation on AppTool {
  IconData get icon => switch (this) {
    AppTool.translate => Lucide.Languages,
    AppTool.storage => Lucide.Folder,
    AppTool.markdownImage => Lucide.Image,
  };

  String label(AppLocalizations l10n) => switch (this) {
    AppTool.translate => l10n.desktopNavTranslateTooltip,
    AppTool.storage => l10n.desktopNavStorageTooltip,
    AppTool.markdownImage => l10n.markdownExportTitle,
  };

  /// Opens the tool on top of the current route, for entry points that do not
  /// own a tab they can switch to.
  void push(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => switch (this) {
          AppTool.translate => const TranslatePage(),
          AppTool.storage => const StorageSpacePage(),
          AppTool.markdownImage => const MarkdownExportPage(),
        },
      ),
    );
  }
}
