import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/providers/filesystem_mounts_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/format.dart';
import '../../../utils/platform_utils.dart';

/// A single entry in the current directory level of [MountFilesPage].
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

/// Directory browser for a filesystem mount (`@workspaces` or an external
/// desktop mount): one level at a time, breadcrumb navigation, per-level
/// name sort (directories first), dotfiles skipped.
///
/// Mount-scoped behavior (see CONTEXT.md "Filesystem MCP"):
/// - deletion markers are recorded ONLY for `@workspaces` — external-mount
///   deletes are physical deletes with no tombstone (they never sync);
/// - upload overwrites collisions on `@workspaces` (LWW — app-managed
///   sandbox) but rejects them on external mounts (pre-copy check);
/// - content entering `@workspaces` gets mtime=now (backup/sync protocol);
/// - read-only mounts hide upload/delete but keep preview + download.
class MountFilesPage extends StatefulWidget {
  const MountFilesPage({super.key, required this.mount});

  final FilesystemMount mount;

  @override
  State<MountFilesPage> createState() => _MountFilesPageState();
}

class _MountFilesPageState extends State<MountFilesPage> {
  List<String> _segments = const [];
  List<_DirEntry> _entries = const [];
  bool _loading = true;
  int _loadGen = 0;

  bool get _isWorkspaces =>
      widget.mount.alias == FilesystemMountsProvider.workspacesAlias;

  String get _currentHostDir => _segments.isEmpty
      ? widget.mount.path
      : p.joinAll([widget.mount.path, ..._segments]);

  String _wirePath(String name) {
    final segs = [..._segments, name];
    return '@${widget.mount.alias}/${segs.join('/')}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Generation counter: rapid breadcrumb navigation can interleave two
    // loads; only the newest may publish its listing.
    final gen = ++_loadGen;
    setState(() => _loading = true);
    try {
      final dir = Directory(_currentHostDir);
      final entries = <_DirEntry>[];
      if (await dir.exists()) {
        // followLinks: false — symlinks are never followed in scans.
        await for (final ent in dir.list(followLinks: false)) {
          final name = p.basename(ent.path);
          if (name.startsWith('.')) continue;
          if (ent is Directory) {
            entries.add(
              _DirEntry(
                name: name,
                hostPath: ent.path,
                isDir: true,
                size: 0,
                modifiedAt: DateTime.now(),
              ),
            );
          } else if (ent is File) {
            try {
              final stat = await ent.stat();
              entries.add(
                _DirEntry(
                  name: name,
                  hostPath: ent.path,
                  isDir: false,
                  size: stat.size,
                  modifiedAt: stat.modified,
                ),
              );
            } catch (_) {
              // unreadable entry — skip
            }
          }
        }
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        // Total order: lowercase names first, raw name as tiebreak — same
        // rule as the server's deterministic walk.
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

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  void _navigateTo(List<String> segments) {
    setState(() => _segments = segments);
    _load();
  }

  void _openDir(String name) {
    _navigateTo([..._segments, name]);
  }

  void _preview(_DirEntry e) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            FilePreviewPage(hostPath: e.hostPath, displayName: e.name),
      ),
    );
  }

  Future<void> _confirmDelete(_DirEntry entry) async {
    final l10n = this.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.workspaceFilesDeleteConfirmTitle),
        content: Text(
          l10n.workspaceFilesDeleteConfirmMessage(_wirePath(entry.name)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.workspaceFilesDeleteButton),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final f = File(entry.hostPath);
      if (await f.exists()) await f.delete();
      if (!mounted) return;
      // Markers are @workspaces-only sync identity (CONTEXT.md "Filesystem
      // MCP"); external-mount deletes never write tombstones.
      if (_isWorkspaces) {
        final store = context.read<ChatService>().deletedRecordsStore;
        if (store != null) {
          await store.recordFileDeletion(
            id: _wirePath(entry.name),
            deletedAt: DateTime.now(),
          );
        }
      }
      await _load();
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.workspaceFilesDeleted(_wirePath(entry.name)),
        type: NotificationType.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.workspaceFilesDeleteFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _upload() async {
    final l10n = this.l10n;
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (res == null || !mounted) return;
    final dir = Directory(_currentHostDir);
    var ok = 0;
    final problems = <String>[];
    for (final f in res.files) {
      final src = f.path;
      if (src == null || src.isEmpty) continue;
      final name = f.name;
      // Same segment rule as wire paths — Win32 normalization hazards make
      // unsafe names resolve outside the mount on Windows.
      if (!isSafeWireSegment(name)) {
        problems.add(l10n.mountFilesUploadNameInvalid(name));
        continue;
      }
      final dest = File(p.join(dir.path, name));
      try {
        if (await dest.exists()) {
          if (!_isWorkspaces) {
            // External mounts are user real data — no silent overwrite.
            problems.add(l10n.mountFilesUploadConflict(name));
            continue;
          }
          // @workspaces is the app-managed sandbox: LWW overwrite (same
          // semantics as kelivo_write_file).
        }
        await File(src).copy(dest.path);
        // Protocol rule "mtime=now for workspaces" (same as move/unzip in
        // the server): File.copy may preserve the source mtime on
        // macOS/Windows, which would hide the upload from since-filtered
        // backups/LAN sync. Force mtime=now explicitly.
        if (_isWorkspaces) {
          await dest.setLastModified(DateTime.now());
        }
        ok++;
      } catch (e) {
        problems.add(l10n.mountFilesUploadFailed(name, e.toString()));
      }
    }
    await _load();
    if (!mounted) return;
    if (ok > 0) {
      showAppSnackBar(
        context,
        message: problems.isEmpty
            ? l10n.mountFilesUploaded(ok)
            : '${l10n.mountFilesUploaded(ok)}\n${problems.first}',
        type: NotificationType.success,
      );
    } else if (problems.isNotEmpty) {
      showAppSnackBar(
        context,
        message: problems.first,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _download(_DirEntry entry) async {
    final l10n = this.l10n;
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
        // iOS), same pattern as message_export_sheet. The whole file must
        // fit in memory — cap at the read window like the preview.
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

  /// Opens a file with the system's default app. Path-based, so it works on
  /// read-only external mounts too.
  Future<void> _openExternal(_DirEntry entry) async {
    final l10n = this.l10n;
    try {
      final res = await OpenFilex.open(entry.hostPath);
      if (res.type != ResultType.done) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          message: l10n.mountFilesOpenFailed(entry.name, res.message),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.mountFilesOpenFailed(entry.name, '$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _share(_DirEntry entry) async {
    final l10n = this.l10n;
    try {
      // share_plus exposes app-sandbox paths via FileProvider (Android) /
      // UIActivityViewController (iOS) without loading the file into memory.
      await SharePlus.instance.share(
        ShareParams(files: [XFile(entry.hostPath)]),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.mountFilesShareFailed(entry.name, '$e'),
        type: NotificationType.error,
      );
    }
  }

  /// Mobile entry: all file actions fold into one "more" sheet so the file
  /// name keeps room (desktop keeps inline icons).
  Future<void> _showMoreSheet(_DirEntry entry) async {
    final l10n = this.l10n;
    final cs = Theme.of(context).colorScheme;
    final readOnly = widget.mount.readOnly;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        Widget action({
          required IconData icon,
          required String label,
          required Future<void> Function() onTap,
          Color? color,
        }) {
          return IosCardPress(
            onTap: () {
              Navigator.of(ctx).pop();
              onTap();
            },
            borderRadius: BorderRadius.circular(12),
            baseColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: color ?? cs.onSurface),
                const SizedBox(width: 14),
                Text(label, style: const TextStyle(fontSize: 15)),
              ],
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              action(
                icon: Lucide.ExternalLink,
                label: l10n.mountFilesOpenButton,
                onTap: () => _openExternal(entry),
              ),
              action(
                icon: Lucide.Share2,
                label: l10n.mountFilesShareButton,
                onTap: () => _share(entry),
              ),
              action(
                icon: Lucide.Download,
                label: l10n.mountFilesDownloadButton,
                onTap: () => _download(entry),
              ),
              if (!readOnly)
                action(
                  icon: Lucide.Trash2,
                  label: l10n.workspaceFilesDeleteButton,
                  color: cs.error,
                  onTap: () => _confirmDelete(entry),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
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
    final crumbs = <Widget>[
      _crumbChip(widget.mount.wireName, () => _navigateTo(const [])),
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = this.l10n;
    final readOnly = widget.mount.readOnly;

    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The breadcrumb stays visible even for empty directories —
              // without it the user could only leave via the page back
              // button, with no way to step up one level at a time.
              _breadcrumb(context),
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
                          final isDesktop = PlatformUtils.isDesktopTarget;
                          return _EntryRow(
                            entry: e,
                            isDesktop: isDesktop,
                            onOpen: () {
                              if (e.isDir) {
                                _openDir(e.name);
                              } else {
                                _preview(e);
                              }
                            },
                            onDownload: e.isDir ? null : () => _download(e),
                            onDelete: e.isDir || readOnly
                                ? null
                                : () => _confirmDelete(e),
                            onOpenExternal: e.isDir || !isDesktop
                                ? null
                                : () => _openExternal(e),
                            onShare: e.isDir || !isDesktop
                                ? null
                                : () => _share(e),
                            showMore: e.isDir || isDesktop
                                ? null
                                : () => _showMoreSheet(e),
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
        title: Text(l10n.mountFilesPageTitle(widget.mount.wireName)),
        actions: [
          if (!readOnly)
            IosIconButton(
              icon: Lucide.Upload,
              size: 20,
              minSize: 44,
              semanticLabel: l10n.mountFilesUploadButton,
              onTap: _upload,
            ),
        ],
      ),
      body: content,
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.isDesktop,
    required this.onOpen,
    this.onDownload,
    this.onDelete,
    this.onOpenExternal,
    this.onShare,
    this.showMore,
  });

  final _DirEntry entry;
  final bool isDesktop;
  final VoidCallback onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onShare;
  final VoidCallback? showMore;

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
                      '${_formatTime(entry.modifiedAt, l10n)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onDownload != null && isDesktop) ...[
              IosIconButton(
                icon: Lucide.ExternalLink,
                size: 17,
                color: cs.onSurface.withValues(alpha: 0.7),
                minSize: 36,
                semanticLabel: l10n.mountFilesOpenButton,
                onTap: onOpenExternal!,
              ),
              IosIconButton(
                icon: Lucide.Share2,
                size: 17,
                color: cs.onSurface.withValues(alpha: 0.7),
                minSize: 36,
                semanticLabel: l10n.mountFilesShareButton,
                onTap: onShare!,
              ),
              IosIconButton(
                icon: Lucide.Download,
                size: 17,
                color: cs.onSurface.withValues(alpha: 0.7),
                minSize: 36,
                semanticLabel: l10n.mountFilesDownloadButton,
                onTap: onDownload!,
              ),
              if (onDelete != null)
                IosIconButton(
                  icon: Lucide.Trash2,
                  size: 17,
                  color: cs.error.withValues(alpha: 0.85),
                  minSize: 36,
                  semanticLabel: l10n.workspaceFilesDeleteButton,
                  onTap: onDelete!,
                ),
            ] else if (showMore != null)
              IosIconButton(
                icon: Lucide.Ellipsis,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.6),
                minSize: 40,
                semanticLabel: l10n.mountFilesMoreButton,
                onTap: showMore!,
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

  String _formatTime(DateTime t, AppLocalizations l10n) {
    final local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

/// File content preview. Read RULES are shared with `kelivo_read`
/// (32 MB size cap, binary rejection, truncation note) but the preview's
/// char budget is its own (256 KB vs the model's 32 KB paginated window) —
/// the two surfaces deliberately diverge on budget (see CONTEXT.md).
class FilePreviewPage extends StatefulWidget {
  const FilePreviewPage({
    super.key,
    required this.hostPath,
    required this.displayName,
  });

  final String hostPath;
  final String displayName;

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

enum _PreviewState { loading, text, image, error }

class _FilePreviewPageState extends State<FilePreviewPage> {
  _PreviewState _state = _PreviewState.loading;
  List<String> _textLines = const [];
  bool _truncated = false;
  int _totalLines = 0;
  Uint8List? _imageBytes;
  bool _isSvg = false;
  String? _errorMessage;

  /// Preview char budget: 8x the model-facing `kelivo_read` window.
  /// User preview is not token-bound, so it may show more of the file.
  static const int _previewCharBudget = 256 * 1024;

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.svg',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  /// Same binary probe as the filesystem server (null byte within the first
  /// 8 KB) — one rule set, two surfaces.
  bool _looksBinary(Uint8List bytes) {
    final n = math.min(bytes.length, 8 * 1024);
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  Future<void> _load() async {
    try {
      final f = File(widget.hostPath);
      final stat = await f.stat();
      if (stat.size > KelivoFilesystemMcpServerEngine.readWindowBytes) {
        _fail(l10n.mountFilesPreviewTooLarge(widget.displayName));
        return;
      }
      final ext = p.extension(widget.hostPath).toLowerCase();
      if (_imageExtensions.contains(ext) && stat.size > 0) {
        final bytes = await f.readAsBytes();
        if (!mounted) return;
        setState(() {
          _imageBytes = bytes;
          _isSvg = ext == '.svg';
          _state = _PreviewState.image;
        });
        return;
      }
      final raf = await f.open();
      final bytes = await raf.read(stat.size);
      await raf.close();
      if (_looksBinary(bytes)) {
        _fail(l10n.mountFilesPreviewBinary(widget.displayName));
        return;
      }
      final rawLines = utf8.decode(bytes, allowMalformed: true).split('\n');
      final lines = <String>[];
      var chars = 0;
      var lineCut = false;
      for (var i = 0; i < rawLines.length; i++) {
        var content = rawLines[i];
        // A single line can exceed the whole budget (minified files): cut
        // it so the preview stays bounded instead of feeding a ~30 MB
        // string to SelectableText (mirrors the server's read budget).
        if (content.length > _previewCharBudget) {
          content = content.substring(0, _previewCharBudget);
          lineCut = true;
        }
        final next = chars + content.length + 1;
        if (next > _previewCharBudget && lines.isNotEmpty) break;
        lines.add(content);
        chars = next;
      }
      if (!mounted) return;
      setState(() {
        _textLines = lines;
        _truncated = lines.length < rawLines.length || lineCut;
        _totalLines = rawLines.length;
        _state = _PreviewState.text;
      });
    } catch (e) {
      _fail(l10n.mountFilesPreviewReadFailed(widget.displayName, '$e'));
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _state = _PreviewState.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = this.l10n;
    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(widget.displayName),
      ),
      body: switch (_state) {
        _PreviewState.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        _PreviewState.error => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _errorMessage ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
        _PreviewState.image => Center(
          child: _isSvg
              ? SvgPicture.file(
                  File(widget.hostPath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text(
                    l10n.mountFilesPreviewReadFailed(
                      widget.displayName,
                      'decode failed',
                    ),
                  ),
                )
              : Image.memory(
                  _imageBytes!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Text(
                    l10n.mountFilesPreviewReadFailed(
                      widget.displayName,
                      'decode failed',
                    ),
                  ),
                ),
        ),
        _PreviewState.text => Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Line-number gutter: chrome, not content. Right-
                      // aligned, dimmed, excluded from selection/copy and
                      // screen readers. Long lines scroll horizontally
                      // instead of wrapping, so gutter numbers never drift
                      // away from their lines.
                      SizedBox(
                        width: _gutterWidth,
                        child: ExcludeSemantics(
                          child: Text(
                            _gutterNumbers,
                            textAlign: TextAlign.right,
                            style: _lineStyle.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SelectableText(_textLines.join('\n'), style: _lineStyle),
                    ],
                  ),
                ),
              ),
            ),
            if (_truncated)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: cs.primary.withValues(alpha: 0.08),
                child: Text(
                  l10n.mountFilesPreviewTruncated(_totalLines),
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
          ],
        ),
      },
    );
  }

  /// Shared metrics so the gutter never drifts from the content column.
  static final TextStyle _lineStyle = TextStyle(
    fontSize: 13,
    fontFamily: 'monospace',
    height: 1.5,
  );

  /// "1\n2\n..." for the visible lines.
  String get _gutterNumbers {
    final sb = StringBuffer();
    for (var i = 1; i <= _textLines.length; i++) {
      if (i > 1) sb.write('\n');
      sb.write(i);
    }
    return sb.toString();
  }

  /// Fixed width from the TOTAL line count (truncation bar state included),
  /// so the gutter never jumps while the preview loads more.
  double get _gutterWidth {
    final digits = '$_totalLines'.length;
    return digits * 8.0 + 4.0;
  }
}
