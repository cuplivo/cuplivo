import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../models/linux_sandbox.dart';
import '../providers/linux_sandbox_provider.dart';
import 'linux_sandbox_detail_page.dart';

class LinuxSandboxCreatePage extends StatefulWidget {
  const LinuxSandboxCreatePage({super.key});

  @override
  State<LinuxSandboxCreatePage> createState() => _LinuxSandboxCreatePageState();
}

class _LinuxSandboxCreatePageState extends State<LinuxSandboxCreatePage> {
  final _nameController = TextEditingController();
  bool _baseEnv = true;
  bool _creating = false;
  double? _installProgress;
  String? _installStage;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating) return;
    final l10n = AppLocalizations.of(context)!;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showAppSnackBar(
        context,
        message: l10n.linuxSandboxCreateNameRequired,
        type: NotificationType.warning,
      );
      return;
    }
    setState(() => _creating = true);
    try {
      final provider = context.read<LinuxSandboxProvider>();
      final sandbox = await provider.create(
        name: name,
        enabledEnvPacks: _baseEnv
            ? const [LinuxSandbox.baseEnvPackId]
            : const <String>[],
      );
      if (_baseEnv) {
        final result = await provider.installBaseEnv(
          sandbox.id,
          onProgress: (progress, stage) {
            if (!mounted) return;
            setState(() {
              _installProgress = progress;
              _installStage = stage;
            });
          },
        );
        if (!result.ok && mounted) {
          setState(() => _creating = false);
          showAppSnackBar(
            context,
            message: result.errorMessage ?? l10n.linuxSandboxInstallFailed,
            type: NotificationType.error,
          );
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => LinuxSandboxDetailPage(sandboxId: sandbox.id),
            ),
          );
          return;
        }
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => LinuxSandboxDetailPage(sandboxId: sandbox.id),
        ),
      );
    } catch (e, st) {
      debugPrint('LinuxSandboxCreatePage: create failed: $e\n$st');
      if (!mounted) return;
      setState(() => _creating = false);
      showAppSnackBar(
        context,
        message: l10n.linuxSandboxCreateFailed,
        type: NotificationType.error,
      );
    }
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
        title: Text(l10n.linuxSandboxCreateTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _sectionCard(
            isDark: isDark,
            cs: cs,
            child: IosFormTextField(
              label: l10n.linuxSandboxCreateNameLabel,
              controller: _nameController,
              hintText: l10n.linuxSandboxCreateNameHint,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              l10n.linuxSandboxCreateInstallSection,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
          _sectionCard(
            isDark: isDark,
            cs: cs,
            child: Column(
              children: [
                _InstallOptionRow(
                  title: l10n.linuxSandboxCreateBaseEnvTitle,
                  subtitle: l10n.linuxSandboxCreateBaseEnvSubtitle,
                  enabled: true,
                  selected: _baseEnv,
                  onTap: () => setState(() => _baseEnv = !_baseEnv),
                ),
                Divider(
                  height: 1,
                  thickness: 0.6,
                  indent: 16,
                  endIndent: 16,
                  color: cs.outlineVariant.withValues(alpha: 0.18),
                ),
                _InstallOptionRow(
                  title: l10n.linuxSandboxCreatePythonTitle,
                  subtitle: l10n.linuxSandboxCreateComingLater,
                  enabled: false,
                  selected: false,
                  onTap: null,
                ),
                Divider(
                  height: 1,
                  thickness: 0.6,
                  indent: 16,
                  endIndent: 16,
                  color: cs.outlineVariant.withValues(alpha: 0.18),
                ),
                _InstallOptionRow(
                  title: l10n.linuxSandboxCreateJavaTitle,
                  subtitle: l10n.linuxSandboxCreateComingLater,
                  enabled: false,
                  selected: false,
                  onTap: null,
                ),
              ],
            ),
          ),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 12),
            Text(
              l10n.linuxSandboxAndroidDownloadNote,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
          if (Platform.isWindows) ...[
            const SizedBox(height: 12),
            Text(
              l10n.linuxSandboxWindowsWslInstallNote,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
          if (_creating) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _installProgress),
            if (_installStage != null) ...[
              const SizedBox(height: 8),
              Text(
                l10n.linuxSandboxInstallProgress(
                  _localizeCreateInstallStage(l10n, _installStage!),
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
          const SizedBox(height: 24),
          IosTileButton(
            icon: Lucide.Plus,
            label: l10n.linuxSandboxCreateAction,
            backgroundColor: cs.primary,
            enabled: !_creating && _nameController.text.trim().isNotEmpty,
            onTap: _create,
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required bool isDark,
    required ColorScheme cs,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

String _localizeCreateInstallStage(AppLocalizations l10n, String stage) {
  switch (stage) {
    case 'download':
      return l10n.linuxSandboxWslDownloadingRootfs;
    case 'import':
    case 'wsl_import':
      return l10n.linuxSandboxWslImportingDistro;
    default:
      return stage;
  }
}

class _InstallOptionRow extends StatelessWidget {
  const _InstallOptionRow({
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool enabled;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurface.withValues(alpha: enabled ? 0.92 : 0.42);
    return IosCardPress(
      borderRadius: BorderRadius.zero,
      baseColor: Colors.transparent,
      haptics: enabled,
      onTap: enabled ? onTap : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: cs.onSurface.withValues(
                      alpha: enabled ? 0.58 : 0.38,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Opacity(
            opacity: enabled ? 1 : 0.4,
            child: IosCheckbox(
              value: selected,
              onChanged: enabled && onTap != null ? (_) => onTap!() : null,
            ),
          ),
        ],
      ),
    );
  }
}
