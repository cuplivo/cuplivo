import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/snackbar.dart';
import '../../shared/widgets/windows_ax_tree_safe_tooltip.dart';
import '../../utils/app_directories.dart';
import '../../utils/open_directory.dart';

/// Resolves the application `logs` directory, creating it when missing, then
/// opens it in the system file manager.
Future<void> _openLogsDirectory() async {
  final base = await AppDirectories.getAppDataDirectory();
  final logsDir = Directory(p.join(base.path, 'logs'));
  if (!await logsDir.exists()) {
    await logsDir.create(recursive: true);
  }
  await openDirectoryInFileManager(logsDir.path);
}

/// Folder button shown next to the log toggles in desktop settings.
///
/// Opens the application `logs` directory in the system file manager and
/// reports failures through an error snackbar instead of staying silent
/// (issue #789: a `file://` URI handed to `url_launcher` did nothing).
class LogsFolderButton extends StatelessWidget {
  const LogsFolderButton({super.key, this.openFolder = _openLogsDirectory});

  /// Injectable for tests; production uses [_openLogsDirectory].
  final Future<void> Function() openFolder;

  Future<void> _handleTap(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await openFolder();
    } catch (e) {
      debugPrint('LogsFolderButton: failed to open logs folder: $e');
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.logViewerOpenFolderFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return WindowsAxTreeSafeTooltip(
      message: l10n.logViewerOpenFolder,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _handleTap(context),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(lucide.Lucide.FolderOpen, size: 18, color: cs.primary),
        ),
      ),
    );
  }
}
