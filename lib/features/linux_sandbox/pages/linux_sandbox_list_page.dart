import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../models/linux_sandbox.dart';
import '../providers/linux_sandbox_provider.dart';
import '../services/android_linux_sandbox_channel.dart';
import 'linux_sandbox_create_page.dart';
import 'linux_sandbox_detail_page.dart';

class LinuxSandboxListPage extends StatefulWidget {
  const LinuxSandboxListPage({super.key});

  @override
  State<LinuxSandboxListPage> createState() => _LinuxSandboxListPageState();
}

class _LinuxSandboxListPageState extends State<LinuxSandboxListPage> {
  Future<String>? _androidAbiFuture;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _androidAbiFuture = AndroidLinuxSandboxChannel().getSupportedAbi();
    }
  }

  String? _platformBanner(AppLocalizations l10n, {String? androidAbi}) {
    if (Platform.isWindows || Platform.isLinux) return null;
    if (Platform.isAndroid) {
      if (androidAbi == null) return null;
      if (androidAbi == 'unsupported') {
        return l10n.linuxSandboxAndroidUnsupported;
      }
      return null;
    }
    return l10n.linuxSandboxPlatformUnsupported;
  }

  Future<void> _confirmDelete(
    BuildContext context,
    LinuxSandbox sandbox,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.linuxSandboxDeleteConfirmTitle),
        content: Text(l10n.linuxSandboxDeleteConfirmMessage(sandbox.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: Text(l10n.linuxSandboxDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<LinuxSandboxProvider>().delete(
        sandbox.id,
        context.read<AssistantProvider>(),
      );
    } catch (e, st) {
      debugPrint('LinuxSandboxListPage: delete failed: $e\n$st');
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.linuxSandboxDeleteFailed,
        type: NotificationType.error,
      );
    }
  }

  void _openCreate(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LinuxSandboxCreatePage()));
  }

  void _openDetail(BuildContext context, String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LinuxSandboxDetailPage(sandboxId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<LinuxSandboxProvider>();
    final sandboxes = provider.sandboxes;

    if (Platform.isAndroid && _androidAbiFuture != null) {
      return FutureBuilder<String>(
        future: _androidAbiFuture,
        builder: (context, snapshot) {
          final banner = _platformBanner(l10n, androidAbi: snapshot.data);
          return _buildBody(
            context,
            l10n: l10n,
            cs: cs,
            isDark: isDark,
            provider: provider,
            sandboxes: sandboxes,
            banner: banner,
          );
        },
      );
    }

    return _buildBody(
      context,
      l10n: l10n,
      cs: cs,
      isDark: isDark,
      provider: provider,
      sandboxes: sandboxes,
      banner: _platformBanner(l10n),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required AppLocalizations l10n,
    required ColorScheme cs,
    required bool isDark,
    required LinuxSandboxProvider provider,
    required List<LinuxSandbox> sandboxes,
    required String? banner,
  }) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: canPop,
        leading: canPop
            ? Tooltip(
                message: l10n.settingsPageBackButton,
                child: IosIconButton(
                  icon: Lucide.ChevronLeft,
                  size: 22,
                  minSize: 44,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              )
            : null,
        title: Text(l10n.linuxSandboxListTitle),
      ),
      body: !provider.loaded
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (banner != null)
                      Material(
                        color: cs.errorContainer.withValues(alpha: 0.55),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Lucide.MessageCircleWarning,
                                size: 16,
                                color: cs.onErrorContainer,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  banner,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.35,
                                    color: cs.onErrorContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: sandboxes.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Text(
                                  l10n.linuxSandboxListEmpty,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: cs.onSurface.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                88,
                              ),
                              itemCount: sandboxes.length,
                              itemBuilder: (context, index) {
                                final sandbox = sandboxes[index];
                                final enabledCount = sandbox.tools.values
                                    .where((t) => t.enabled)
                                    .length;
                                final total = sandbox.tools.length;
                                final showWslHint =
                                    Platform.isWindows &&
                                    (sandbox.status ==
                                            LinuxSandboxStatus.broken ||
                                        provider.wslResumeSandboxId ==
                                            sandbox.id);
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (showWslHint)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: Material(
                                            color: cs.tertiaryContainer
                                                .withValues(alpha: 0.55),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    12,
                                                    8,
                                                    12,
                                                    8,
                                                  ),
                                              child: Text(
                                                provider.wslResumeSandboxId ==
                                                        sandbox.id
                                                    ? l10n.linuxSandboxWslResumeAfterReboot
                                                    : l10n.linuxSandboxWindowsWslBrokenHint,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  height: 1.35,
                                                  color: cs.onTertiaryContainer,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      IosCardPress(
                                        borderRadius: BorderRadius.circular(14),
                                        baseColor: isDark
                                            ? Colors.white10
                                            : Colors.white.withValues(
                                                alpha: 0.96,
                                              ),
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
                                        onTap: () =>
                                            _openDetail(context, sandbox.id),
                                        onLongPress: () =>
                                            _confirmDelete(context, sandbox),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 42,
                                              height: 42,
                                              decoration: BoxDecoration(
                                                color: isDark
                                                    ? Colors.white10
                                                    : const Color(0xFFF2F3F5),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                              alignment: Alignment.center,
                                              child: Icon(
                                                Lucide.Box,
                                                size: 20,
                                                color: cs.primary,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    sandbox.name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontWeight: AppFontWeights
                                                          .emphasis,
                                                      color: cs.onSurface,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    l10n.linuxSandboxToolsCount(
                                                      enabledCount,
                                                      total,
                                                    ),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: cs.onSurface
                                                          .withValues(
                                                            alpha: 0.6,
                                                          ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Wrap(
                                                    spacing: 6,
                                                    runSpacing: 4,
                                                    children: [
                                                      _ListChip(
                                                        label: _listStatusLabel(
                                                          l10n,
                                                          sandbox.status,
                                                        ),
                                                        color: _listStatusColor(
                                                          cs,
                                                          sandbox.status,
                                                        ),
                                                      ),
                                                      _ListChip(
                                                        label: _listModeLabel(
                                                          l10n,
                                                          sandbox.runtimeMode,
                                                        ),
                                                        color: cs.onSurface
                                                            .withValues(
                                                              alpha: 0.55,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IosIconButton(
                                              icon: Lucide.Trash2,
                                              size: 18,
                                              color: cs.error,
                                              onTap: () => _confirmDelete(
                                                context,
                                                sandbox,
                                              ),
                                            ),
                                            Icon(
                                              Lucide.ChevronRight,
                                              size: 16,
                                              color: cs.onSurface.withValues(
                                                alpha: 0.45,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
                Positioned(
                  right: 16,
                  bottom: 16 + MediaQuery.paddingOf(context).bottom,
                  child: _CreateFab(
                    label: l10n.linuxSandboxCreateAction,
                    onTap: () => _openCreate(context),
                  ),
                ),
              ],
            ),
    );
  }
}

String _listStatusLabel(AppLocalizations l10n, LinuxSandboxStatus status) {
  switch (status) {
    case LinuxSandboxStatus.disabled:
      return l10n.linuxSandboxStatusDisabled;
    case LinuxSandboxStatus.notReady:
      return l10n.linuxSandboxStatusNotReady;
    case LinuxSandboxStatus.installing:
      return l10n.linuxSandboxStatusInstalling;
    case LinuxSandboxStatus.ready:
      return l10n.linuxSandboxStatusReady;
    case LinuxSandboxStatus.broken:
      return l10n.linuxSandboxStatusBroken;
  }
}

String _listModeLabel(AppLocalizations l10n, LinuxSandboxRuntimeMode mode) {
  switch (mode) {
    case LinuxSandboxRuntimeMode.localJail:
      return l10n.linuxSandboxRuntimeModeLocalJail;
    case LinuxSandboxRuntimeMode.wsl:
      return l10n.linuxSandboxRuntimeModeWsl;
    case LinuxSandboxRuntimeMode.nativeLinux:
      return l10n.linuxSandboxRuntimeModeNativeLinux;
    case LinuxSandboxRuntimeMode.proot:
      return l10n.linuxSandboxRuntimeModeProot;
    case LinuxSandboxRuntimeMode.unsupported:
    case LinuxSandboxRuntimeMode.unknown:
      return l10n.linuxSandboxRuntimeModeUnknown;
  }
}

Color _listStatusColor(ColorScheme cs, LinuxSandboxStatus status) {
  switch (status) {
    case LinuxSandboxStatus.ready:
      return cs.primary;
    case LinuxSandboxStatus.installing:
      return cs.tertiary;
    case LinuxSandboxStatus.broken:
      return cs.error;
    case LinuxSandboxStatus.disabled:
    case LinuxSandboxStatus.notReady:
      return cs.onSurface.withValues(alpha: 0.55);
  }
}

class _ListChip extends StatelessWidget {
  const _ListChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _CreateFab extends StatefulWidget {
  const _CreateFab({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_CreateFab> createState() => _CreateFabState();
}

class _CreateFabState extends State<_CreateFab> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          Haptics.light();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: cs.primary.withValues(alpha: 0.28),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(Lucide.Plus, color: cs.onPrimary, size: 24),
          ),
        ),
      ),
    );
  }
}
