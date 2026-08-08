import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../services/sandbox_runtime.dart';

class LinuxSandboxFileBrowserPage extends StatefulWidget {
  const LinuxSandboxFileBrowserPage({super.key, required this.sandboxId});

  final String sandboxId;

  @override
  State<LinuxSandboxFileBrowserPage> createState() =>
      _LinuxSandboxFileBrowserPageState();
}

class _LinuxSandboxFileBrowserPageState
    extends State<LinuxSandboxFileBrowserPage> {
  late final SandboxRuntime _runtime;
  String _relativePath = '';
  List<SandboxFsEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _runtime = createSandboxRuntime(widget.sandboxId);
    _load();
  }

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _runtime.ensureReady();
      final entries = await _runtime.listDir(_relativePath);
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _error = e.toString();
        _entries = const [];
        _loading = false;
      });
    }
  }

  void _enterDir(String name) {
    final next = _relativePath.isEmpty
        ? name
        : p.posix.join(_relativePath, name);
    setState(() => _relativePath = next);
    _load();
  }

  void _goUp() {
    if (_relativePath.isEmpty) return;
    final parent = p.posix.dirname(_relativePath);
    setState(() {
      _relativePath = parent == '.' ? '' : parent;
    });
    _load();
  }

  String _title(AppLocalizations l10n) {
    if (_relativePath.isEmpty) return l10n.linuxSandboxBrowseTitle;
    return _relativePath;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ChevronLeft,
            size: 22,
            minSize: 44,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(_title(l10n), overflow: TextOverflow.ellipsis),
        actions: [
          if (_relativePath.isNotEmpty)
            Tooltip(
              message: l10n.linuxSandboxBrowseUp,
              child: IosIconButton(
                icon: Lucide.ArrowUp,
                size: 20,
                minSize: 44,
                onTap: _goUp,
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error),
                ),
              ),
            )
          : _entries.isEmpty
          ? Center(
              child: Text(
                l10n.linuxSandboxBrowseEmpty,
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return IosCardPress(
                  borderRadius: BorderRadius.circular(12),
                  baseColor: isDark
                      ? Colors.white10
                      : Colors.white.withValues(alpha: 0.96),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(
                      alpha: isDark ? 0.1 : 0.08,
                    ),
                    width: 0.6,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  onTap: entry.isDirectory ? () => _enterDir(entry.name) : null,
                  child: Row(
                    children: [
                      Icon(
                        entry.isDirectory ? Lucide.Folder : Lucide.FileText,
                        size: 20,
                        color: entry.isDirectory
                            ? cs.primary
                            : cs.onSurface.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      if (entry.isDirectory)
                        Icon(
                          Lucide.ChevronRight,
                          size: 16,
                          color: cs.onSurface.withValues(alpha: 0.4),
                        )
                      else if (entry.size != null)
                        Text(
                          _formatSize(entry.size!),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
