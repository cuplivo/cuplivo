import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/pages/file_preview_page.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/format.dart';

/// A single entry in the current directory level of [SandboxFilesPage].
class _DirEntry {
  final String name;
  final String hostPath;
  final bool isDir;
  final int size;
  final DateTime modifiedAt;

  const _DirEntry({
    required this.name,
    required this.hostPath,
    required this.isDir,
    required this.size,
    required this.modifiedAt,
  });
}

/// Read-only directory browser over the mobile Linux sandbox system
/// directory (the host-side mirror of the guest root filesystem):
/// - Android: `<ws>/.sandbox/linux` (per-workspace proot rootfs)
/// - iOS: shared rootfs `alpine-rootfs/data` (guest `/`; shared by ALL
///   workspaces — a banner explains this on iOS)
///
/// Differs from the [FilePreviewPage]'s host-mount browser
/// ([MountFilesPage]) on purpose: the address space is guest-style (root
/// breadcrumb `/`, paths like `/usr/bin`), dotfiles are ALWAYS visible
/// (system viewer, no toggle), and the page is strictly read-only —
/// preview + download only. No upload, no delete, no deletion markers, no
/// wire paths: the rootfs is app-managed data that never participates in
/// backup/sync or the MCP tool surface. Symlinks resolve to their target
/// type (a rootfs is full of them), so link-to-dir is navigable and
/// link-to-file is downloadable; dangling links are skipped.
class SandboxFilesPage extends StatefulWidget {
  const SandboxFilesPage({super.key, required this.rootHostPath});

  /// Host path of the guest root filesystem mirror.
  final String rootHostPath;

  @override
  State<SandboxFilesPage> createState() => _SandboxFilesPageState();
}

class _SandboxFilesPageState extends State<SandboxFilesPage> {
  List<String> _segments = const [];
  List<_DirEntry> _entries = const [];
  bool _loading = true;
  int _loadGen = 0;

  String get _currentHostDir => _segments.isEmpty
      ? widget.rootHostPath
      : p.joinAll([widget.rootHostPath, ..._segments]);

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    // Clear the previous listing up-front so an error (or a superseded
    // load) can never leave rows that disagree with the current breadcrumb.
    setState(() {
      _loading = true;
      _entries = const [];
    });
    try {
      final dir = Directory(_currentHostDir);
      final entries = <_DirEntry>[];
      if (await dir.exists()) {
        final dirs = <_DirEntry>[];
        final files = <File>[];
        // followLinks: true — a rootfs is full of symlinks (usrmerge makes
        // /bin, /lib, /sbin themselves links), so links resolve to their
        // target type: link-to-dir shows as a navigable directory, link-to-
        // file as a downloadable file. Dangling links surface as Link
        // entities and are skipped. Breaking out of the await-for (page
        // disposed, or a newer load superseded this one) cancels the
        // underlying directory stream, so rapid navigation never stacks
        // full scans of large system directories.
        await for (final ent in dir.list(followLinks: true)) {
          if (!mounted || gen != _loadGen) break;
          if (ent is Directory) {
            dirs.add(
              _DirEntry(
                name: p.basename(ent.path),
                hostPath: ent.path,
                isDir: true,
                size: 0,
                modifiedAt: DateTime.now(),
              ),
            );
          } else if (ent is File) {
            files.add(ent);
          }
        }
        if (!mounted || gen != _loadGen) return;
        // Stats in parallel: /usr/lib-class directories have thousands of
        // entries, and sequential stat keeps the spinner up much longer.
        final fileEntries = await Future.wait(
          files.map((f) async {
            try {
              final stat = await f.stat();
              return _DirEntry(
                name: p.basename(f.path),
                hostPath: f.path,
                isDir: false,
                size: stat.size,
                modifiedAt: stat.modified,
              );
            } catch (_) {
              // unreadable entry — skip
              return null;
            }
          }),
        );
        if (!mounted || gen != _loadGen) return;
        entries
          ..addAll(dirs)
          ..addAll(fileEntries.whereType<_DirEntry>());
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        final cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return cmp != 0 ? cmp : a.name.compareTo(b.name);
      });
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _loading = false);
      showAppSnackBar(
        context,
        message: l10n.workspaceFilesLoadFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  void _navigateTo(List<String> segments) {
    setState(() => _segments = segments);
    _load();
  }

  void _preview(_DirEntry e) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            FilePreviewPage(hostPath: e.hostPath, displayName: e.name),
      ),
    );
  }

  Future<void> _download(_DirEntry entry) async {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.mountFilesDownloadButton,
          fileName: entry.name,
        );
        if (savePath == null) return;
        await File(entry.hostPath).copy(savePath);
      } else {
        // Mobile: FilePicker with bytes parameter (required on Android &
        // iOS), same pattern as the mount browser download.
        final stat = await File(entry.hostPath).stat();
        if (stat.size > KelivoFilesystemMcpServerEngine.readWindowBytes) {
          if (!mounted) return;
          showAppSnackBar(
            context,
            message: l10n.mountFilesDownloadTooLarge(entry.name),
            type: NotificationType.error,
          );
          return;
        }
        final bytes = await File(entry.hostPath).readAsBytes();
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.mountFilesDownloadButton,
          fileName: entry.name,
          bytes: bytes,
        );
        if (savePath == null) return;
      }
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.mountFilesDownloaded(entry.name),
        type: NotificationType.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.mountFilesDownloadFailed(entry.name, e.toString()),
        type: NotificationType.error,
      );
    }
  }

  Widget _crumbChip(String label, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: cs.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: cs.onSurface.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }

  Widget _breadcrumb(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Guest-style address space: the mount root is the guest `/`.
    final crumbs = <Widget>[
      _crumbChip('/', () => _navigateTo(const [])),
      for (var i = 0; i < _segments.length; i++)
        _crumbChip(
          _segments[i],
          () => _navigateTo(_segments.sublist(0, i + 1)),
        ),
    ];
    final items = <Widget>[];
    for (var i = 0; i < crumbs.length; i++) {
      if (i > 0) {
        items.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Lucide.ChevronRight,
              size: 13,
              color: cs.onSurface.withValues(alpha: 0.4),
            ),
          ),
        );
      }
      items.add(crumbs[i]);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: items),
    );
  }

  /// iOS rootfs is shared by all workspaces; say so instead of letting the
  /// user think the files belong to the current workspace alone.
  Widget? _sharedBanner(BuildContext context) {
    if (!Platform.isIOS) return null;
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        l10n.workspaceSandboxSharedBanner,
        style: TextStyle(
          fontSize: 12,
          color: cs.onSurface.withValues(alpha: 0.75),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _breadcrumb(context),
              _sharedBanner(context) ?? const SizedBox.shrink(),
              Expanded(
                child: _entries.isEmpty
                    ? Center(
                        child: Text(
                          l10n.mountFilesEmptyDir,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: cs.onSurface.withValues(alpha: 0.06),
                        ),
                        itemBuilder: (context, i) {
                          final e = _entries[i];
                          return _EntryRow(
                            entry: e,
                            onOpen: () {
                              if (e.isDir) {
                                _navigateTo([..._segments, e.name]);
                              } else {
                                _preview(e);
                              }
                            },
                            onDownload: e.isDir ? null : () => _download(e),
                          );
                        },
                      ),
              ),
            ],
          );

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.workspaceSandboxFilesTitle),
      ),
      body: content,
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.onOpen, this.onDownload});

  final _DirEntry entry;
  final VoidCallback onOpen;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              entry.isDir ? Lucide.Folder : Lucide.FileText,
              size: 18,
              color: entry.isDir
                  ? cs.primary.withValues(alpha: 0.7)
                  : cs.onSurface.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!entry.isDir) ...[
                    const SizedBox(height: 3),
                    Text(
                      '${formatBytes(entry.size)} · '
                      '${_formatTime(entry.modifiedAt)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onDownload != null)
              IosIconButton(
                icon: Lucide.Download,
                size: 17,
                color: cs.onSurface.withValues(alpha: 0.7),
                minSize: 36,
                semanticLabel: l10n.mountFilesDownloadButton,
                onTap: onDownload,
              ),
            if (entry.isDir)
              Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.3),
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
