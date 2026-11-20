import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/features/workspace/widgets/preview/preview_file_type.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/utils/format_bytes.dart';
import 'package:Cuplivo/shared/widgets/ios_tile_button.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';

/// Why a remote workspace file is not shown as a rendered preview.
///
/// The variants are deliberately user-actionable classes, not wire errors: the
/// page maps a gateway/cache failure into one of these and the card renders a
/// localized sentence plus an optional retry. Two files can fail for different
/// reasons and still look different, which is what the tests pin.
enum DshRemoteFileCardReason {
  /// No live link to the remote that owns the file.
  noConnection,

  /// The remote session handle is missing (no session selected).
  noSession,

  /// `workspaceFiles/stat` says the path does not exist (or it is a folder).
  notFound,

  /// The body exceeds the preview cache's per-file budget.
  tooLarge,

  /// This DSH version/route does not expose a preview for the file kind.
  unsupported,

  /// The preview body could not be read (transport/protocol failure).
  loadFailed,

  /// The kind needs the embedded Web UI but this platform/build cannot embed
  /// it, so the honest action is to explain instead of a blank page.
  webPreviewUnavailable,
}

/// Honest fallback for a remote file Cuplivo cannot render natively.
///
/// Reuses the workspace preview's file-type styling (icon/tint), size
/// formatting and section card, so a remote file that cannot be previewed
/// still reads as the same object family as a local one. Never renders raw
/// gateway detail: [reason] is the user-facing class.
class DshRemoteFileCard extends StatelessWidget {
  const DshRemoteFileCard({
    super.key,
    required this.name,
    required this.reason,
    this.path,
    this.size,
    this.onRetry,
  });

  static const Key retryKey = ValueKey<String>('dsh-remote-file-retry');
  static const Key rootKey = ValueKey<String>('dsh-remote-file-card');

  /// Display name; usually the file's basename.
  final String name;

  /// Workspace-relative path for the secondary line (optional).
  final String? path;

  /// Human-facing reason class.
  final DshRemoteFileCardReason reason;

  /// Size in bytes when the Host reported it.
  final int? size;

  /// Retry callback; when null the card is purely informational.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final style = previewFileTypeStyle(path ?? name);
    final cs = Theme.of(context).colorScheme;
    final resolvedPath = path ?? p.basename(name);
    return SectionCard(
      key: rootKey,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: style.color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(style.icon, size: 24, color: style.color),
          ),
          const SizedBox(height: 12),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _message(l10n),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
          if (reason == DshRemoteFileCardReason.noConnection) ...[
            const SizedBox(height: 4),
            Text(
              l10n.dshFilesUnavailableHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            size == null
                ? resolvedPath
                : '${formatBytes(size!)} · $resolvedPath',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            IosTileButton(
              key: retryKey,
              icon: Lucide.RotateCw,
              label: l10n.workspacePreviewRetry,
              onTap: onRetry!,
            ),
          ],
        ],
      ),
    );
  }

  String _message(AppLocalizations l10n) {
    return switch (reason) {
      DshRemoteFileCardReason.noConnection => l10n.dshFilesUnavailable,
      DshRemoteFileCardReason.noSession => l10n.dshFilesNoSession,
      DshRemoteFileCardReason.notFound => l10n.workspaceFileNotAvailable,
      DshRemoteFileCardReason.tooLarge => l10n.workspacePreviewFileTooLarge,
      DshRemoteFileCardReason.unsupported ||
      DshRemoteFileCardReason.webPreviewUnavailable =>
        l10n.dshFilesPreviewUnavailable,
      DshRemoteFileCardReason.loadFailed => l10n.workspacePreviewLoadError,
    };
  }
}
