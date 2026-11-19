import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';
import 'harness_home_controller.dart';
import 'harness_home_models.dart';
import 'harness_session_catalog.dart';

/// One extra rail entry contributed by the remote (a plugin panel, once the
/// gateway reports plugin slots). Official tool cards are built in.
@immutable
class HarnessRailExtraEntry {
  const HarnessRailExtraEntry({
    required this.id,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;
}

/// The DeepSeek Harness right rail (R7).
///
/// Official DSH surfaces are Flutter-native here: the Start page's tool cards,
/// the read-only workspace-file browser and the terminal entry. Plugin
/// contributions arrive as [extraEntries] and open the chat slice's WebView
/// pages; the rail itself never embeds the official web UI.
///
/// 浏览器 is deliberately absent: DSH 0.2.2-rc.1 exposes no `browser/*` remote
/// namespace (the official browser panel is a desktop-only surface), so a
/// browser card would be a control the remote cannot serve — capability parity
/// says it stays hidden. See `docs/cuplivo-dsh/client-reference.md` §0 item 4.
class HarnessRightRail extends StatelessWidget {
  const HarnessRightRail({
    super.key,
    required this.page,
    required this.session,
    required this.workspaceFiles,
    required this.onClose,
    required this.onToggleExpanded,
    required this.expanded,
    required this.onShowPage,
    required this.onShowStart,
    this.extraEntries = const <HarnessRailExtraEntry>[],
  });

  final HarnessRailPage page;

  /// The open session; the workspace-file browser is rooted at its workspace.
  final HarnessSessionSummary? session;

  /// Read-only file access, or null when this build has no file API wired.
  final HarnessWorkspaceFiles? workspaceFiles;

  final VoidCallback onClose;
  final VoidCallback onToggleExpanded;
  final bool expanded;
  final ValueChanged<HarnessRailPage> onShowPage;
  final VoidCallback onShowStart;
  final List<HarnessRailExtraEntry> extraEntries;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: const Key('dsh-right-rail'),
      color: context.appColors.surfaceCard,
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            _RailHeader(
              title: _pageTitle(AppLocalizations.of(context)!),
              showBack: page != HarnessRailPage.start,
              onBack: onShowStart,
              onClose: onClose,
              onToggleExpanded: onToggleExpanded,
              expanded: expanded,
            ),
            Divider(
              height: 0.6,
              thickness: 0.6,
              color: cs.outlineVariant.withValues(alpha: 0.18),
            ),
            Expanded(child: _pageBody(context)),
          ],
        ),
      ),
    );
  }

  String _pageTitle(AppLocalizations l10n) => switch (page) {
    HarnessRailPage.start => l10n.dshRailStart,
    HarnessRailPage.workspaceFiles => l10n.dshRailWorkspaceFiles,
    HarnessRailPage.terminal => l10n.dshRailNewTerminal,
    HarnessRailPage.moreTools => l10n.dshRailMoreTools,
  };

  Widget _pageBody(BuildContext context) => switch (page) {
    HarnessRailPage.start => _RailStartPage(
      extraEntries: extraEntries,
      onShowPage: onShowPage,
    ),
    HarnessRailPage.workspaceFiles => _RailWorkspaceFilesPage(
      session: session,
      workspaceFiles: workspaceFiles,
    ),
    HarnessRailPage.terminal => _RailTerminalPage(session: session),
    HarnessRailPage.moreTools => _RailMoreToolsPage(extraEntries: extraEntries),
  };
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({
    required this.title,
    required this.showBack,
    required this.onBack,
    required this.onClose,
    required this.onToggleExpanded,
    required this.expanded,
  });

  final String title;
  final bool showBack;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final VoidCallback onToggleExpanded;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          if (showBack)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: IosIconButton(
                key: const Key('dsh-rail-back'),
                icon: Lucide.ArrowLeft,
                size: 18,
                minSize: 40,
                onTap: onBack,
                semanticLabel: l10n.dshRailBackToStart,
              ),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              key: const Key('dsh-rail-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: AppFontWeights.emphasis,
                color: cs.onSurface,
              ),
            ),
          ),
          IosIconButton(
            key: const Key('dsh-rail-expand'),
            icon: expanded ? Lucide.Minimize2 : Lucide.Maximize2,
            size: 17,
            minSize: 40,
            onTap: onToggleExpanded,
            semanticLabel: expanded ? l10n.dshRailCollapse : l10n.dshRailExpand,
            tooltip: expanded ? l10n.dshRailCollapse : l10n.dshRailExpand,
          ),
          IosIconButton(
            key: const Key('dsh-rail-close'),
            icon: Lucide.X,
            size: 18,
            minSize: 40,
            onTap: onClose,
            semanticLabel: l10n.dshRailClose,
            tooltip: l10n.dshRailClose,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// The Start page: one card per official tool the connected Host serves.
class _RailStartPage extends StatelessWidget {
  const _RailStartPage({required this.extraEntries, required this.onShowPage});

  final List<HarnessRailExtraEntry> extraEntries;
  final ValueChanged<HarnessRailPage> onShowPage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: [
        // R7's Start page opens with its compass/start glyph above the cards.
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
          child: Row(
            children: [
              Icon(
                Lucide.Compass,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.dshRailStart,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        _RailToolCard(
          key: const Key('dsh-rail-workspace-files'),
          icon: Lucide.FolderOpen,
          title: l10n.dshRailWorkspaceFiles,
          subtitle: l10n.dshRailWorkspaceFilesSubtitle,
          shortcut: l10n.dshRailWorkspaceFilesShortcut,
          onTap: () => onShowPage(HarnessRailPage.workspaceFiles),
        ),
        const SizedBox(height: 10),
        _RailToolCard(
          key: const Key('dsh-rail-new-terminal'),
          icon: Lucide.Terminal,
          title: l10n.dshRailNewTerminal,
          subtitle: l10n.dshRailNewTerminalSubtitle,
          shortcut: l10n.dshRailNewTerminalShortcut,
          onTap: () => onShowPage(HarnessRailPage.terminal),
        ),
        const SizedBox(height: 10),
        _RailToolCard(
          key: const Key('dsh-rail-more-tools'),
          icon: Lucide.LayoutGrid,
          title: l10n.dshRailMoreTools,
          onTap: () => onShowPage(HarnessRailPage.moreTools),
        ),
        if (extraEntries.isNotEmpty) ...[
          const SizedBox(height: 16),
          _RailSectionLabel(text: l10n.dshRailPluginsSection),
          for (final entry in extraEntries) ...[
            const SizedBox(height: 8),
            _RailToolCard(
              icon: entry.icon,
              title: entry.title,
              subtitle: entry.subtitle,
              onTap: entry.onTap,
            ),
          ],
        ],
      ],
    );
  }
}

class _RailToolCard extends StatelessWidget {
  const _RailToolCard({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.shortcut,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: context.appColors.surfaceCardFill,
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (shortcut != null)
            Text(
              shortcut!,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );
  }
}

class _RailSectionLabel extends StatelessWidget {
  const _RailSectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: AppFontWeights.medium,
          color: cs.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// Read-only workspace-file browser: directory listing plus a text/image
/// preview of the selected file.
class _RailWorkspaceFilesPage extends StatefulWidget {
  const _RailWorkspaceFilesPage({
    required this.session,
    required this.workspaceFiles,
  });

  final HarnessSessionSummary? session;
  final HarnessWorkspaceFiles? workspaceFiles;

  @override
  State<_RailWorkspaceFilesPage> createState() =>
      _RailWorkspaceFilesPageState();
}

class _RailWorkspaceFilesPageState extends State<_RailWorkspaceFilesPage> {
  static const Set<String> _imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  };

  String _path = '';
  HarnessWorkspaceFileListing? _listing;
  bool _loading = false;
  HarnessCatalogException? _error;

  /// The file whose preview replaces the listing (null = browsing).
  HarnessWorkspaceFileEntry? _preview;
  HarnessWorkspaceFileText? _previewText;
  Uint8List? _previewBytes;
  bool _previewLoading = false;
  bool _previewUnavailable = false;

  String get _sessionId => widget.session?.sessionId ?? '';

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void didUpdateWidget(covariant _RailWorkspaceFilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session?.sessionId != widget.session?.sessionId) {
      _path = '';
      _listing = null;
      _closePreview();
      _load('');
    }
  }

  Future<void> _load(String path) async {
    final files = widget.workspaceFiles;
    if (files == null || _sessionId.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await files.list(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _listing = listing;
        _loading = false;
      });
    } on HarnessCatalogException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = HarnessCatalogException(cause: error);
        _loading = false;
      });
    }
  }

  void _closePreview() {
    _preview = null;
    _previewText = null;
    _previewBytes = null;
    _previewUnavailable = false;
    _previewLoading = false;
  }

  Future<void> _openPreview(HarnessWorkspaceFileEntry entry) async {
    final files = widget.workspaceFiles;
    if (files == null) return;
    setState(() {
      _preview = entry;
      _previewText = null;
      _previewBytes = null;
      _previewUnavailable = false;
      _previewLoading = true;
    });
    final extension = entry.name.contains('.')
        ? entry.name.split('.').last.toLowerCase()
        : '';
    try {
      if (_imageExtensions.contains(extension)) {
        final bytes = await files.readBytes(entry.path);
        if (!mounted) return;
        setState(() {
          _previewBytes = bytes;
          _previewLoading = false;
        });
        return;
      }
      final text = await files.readText(entry.path);
      if (!mounted) return;
      setState(() {
        _previewText = text;
        _previewLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _previewUnavailable = true;
        _previewLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.session == null) {
      return _RailMessage(
        icon: Lucide.MessageCirclePlus,
        title: l10n.dshFilesNoSession,
      );
    }
    if (widget.workspaceFiles == null) {
      return _RailMessage(
        icon: Lucide.FileQuestion,
        title: l10n.dshFilesUnavailable,
        detail: l10n.dshFilesUnavailableHint,
      );
    }
    if (_preview != null) return _buildPreview(context, l10n);
    return _buildListing(context, l10n);
  }

  Widget _buildListing(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final listing = _listing;
    final entries = listing?.entries ?? const <HarnessWorkspaceFileEntry>[];
    return Column(
      children: [
        if (_path.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: IosIconButton(
                icon: Lucide.ArrowLeft,
                size: 17,
                minSize: 36,
                onTap: _loading ? null : () => _load(listing?.parentPath ?? ''),
                semanticLabel: l10n.dshFilesParentFolder,
              ),
            ),
          ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (_loading && listing == null) {
                return const Center(child: _RailSpinner());
              }
              if (_error != null) {
                return _RailMessage(
                  icon: Lucide.CircleX,
                  title: l10n.workspaceFilesError,
                  action: TextButton(
                    onPressed: () => _load(_path),
                    child: Text(l10n.retry),
                  ),
                );
              }
              if (entries.isEmpty) {
                return _RailMessage(
                  icon: Lucide.FolderOpen,
                  title: l10n.workspaceFilesEmpty,
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 16),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: IosCardPress(
                      borderRadius: BorderRadius.circular(10),
                      baseColor: Colors.transparent,
                      onTap: () => entry.isDirectory
                          ? unawaited(_load(entry.path))
                          : unawaited(_openPreview(entry)),
                      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                      child: Row(
                        children: [
                          Icon(
                            entry.isDirectory ? Lucide.Folder : Lucide.FileText,
                            size: 17,
                            color: entry.isDirectory
                                ? cs.primary
                                : cs.onSurface.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                          if (!entry.isDirectory)
                            Icon(
                              Lucide.ChevronRight,
                              size: 15,
                              color: cs.onSurface.withValues(alpha: 0.4),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;
    final entry = _preview!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: Row(
            children: [
              IosIconButton(
                icon: Lucide.ArrowLeft,
                size: 17,
                minSize: 36,
                onTap: () => setState(_closePreview),
                semanticLabel: l10n.dshFilesBackToFiles,
              ),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(
          height: 0.6,
          thickness: 0.6,
          color: cs.outlineVariant.withValues(alpha: 0.18),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (_previewLoading) {
                return const Center(child: _RailSpinner());
              }
              if (_previewUnavailable) {
                return _RailMessage(
                  icon: Lucide.FileQuestion,
                  title: l10n.dshFilesPreviewUnavailable,
                );
              }
              final bytes = _previewBytes;
              if (bytes != null) {
                return Padding(
                  padding: const EdgeInsets.all(10),
                  child: InteractiveViewer(
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          _RailMessage(
                            icon: Lucide.ImageOff,
                            title: l10n.dshFilesPreviewUnavailable,
                          ),
                    ),
                  ),
                );
              }
              final text = _previewText;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (text?.truncated == true)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Text(
                        l10n.dshFilesTruncated,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      child: SelectableText(
                        text?.text ?? '',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          fontFamily: 'monospace',
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The terminal card's page: the remote terminal is a large surface (VT
/// renderer + mux uplink) and no terminal API is wired in this build, so the
/// entry exists (R7 asks for the card) and the page states the truth instead of
/// faking a shell.
class _RailTerminalPage extends StatelessWidget {
  const _RailTerminalPage({required this.session});

  final HarnessSessionSummary? session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _RailMessage(
      icon: Lucide.Terminal,
      title: session == null
          ? l10n.dshFilesNoSession
          : l10n.dshTerminalUnavailable,
      detail: session == null ? null : l10n.dshTerminalUnavailableHint,
    );
  }
}

/// The remaining rail entries. Official contributions are the workspace-file
/// browser and the terminal card above; plugin panels surface here once the
/// gateway reports them.
class _RailMoreToolsPage extends StatelessWidget {
  const _RailMoreToolsPage({required this.extraEntries});

  final List<HarnessRailExtraEntry> extraEntries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (extraEntries.isEmpty) {
      return _RailMessage(
        icon: Lucide.LayoutGrid,
        title: l10n.dshRailMoreToolsEmpty,
        detail: l10n.dshRailMoreToolsEmptyHint,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: [
        for (final entry in extraEntries) ...[
          _RailToolCard(
            icon: entry.icon,
            title: entry.title,
            subtitle: entry.subtitle,
            onTap: entry.onTap,
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _RailMessage extends StatelessWidget {
  const _RailMessage({
    required this.icon,
    required this.title,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: cs.onSurface.withValues(alpha: 0.35)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: cs.onSurface.withValues(alpha: 0.42),
                  ),
                ),
              ),
            if (action != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: action),
          ],
        ),
      ),
    );
  }
}

class _RailSpinner extends StatelessWidget {
  const _RailSpinner();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 1.8,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      ),
    );
  }
}
