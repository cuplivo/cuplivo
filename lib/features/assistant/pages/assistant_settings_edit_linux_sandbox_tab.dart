part of 'assistant_settings_edit_page.dart';

class _LinuxSandboxTab extends StatelessWidget {
  const _LinuxSandboxTab({required this.assistantId});
  final String assistantId;

  String? _platformBanner(AppLocalizations l10n) {
    // Real runtimes: Windows (WSL), Android (PRoot), Linux desktop.
    if (Platform.isWindows || Platform.isAndroid || Platform.isLinux) {
      return null;
    }
    return l10n.linuxSandboxPlatformUnsupported;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.getById(assistantId);
    if (assistant == null) return const SizedBox.shrink();

    final sandboxProvider = context.watch<LinuxSandboxProvider>();
    final sandboxes = sandboxProvider.sandboxes;
    final enabled = assistant.sandboxEnabled;
    final selectedId = assistant.sandboxId;
    final selectedSandbox = selectedId == null
        ? null
        : sandboxProvider.getById(selectedId);
    final selectedExists = selectedSandbox != null;
    final missingSelected =
        selectedId != null && selectedId.isNotEmpty && !selectedExists;
    final selectedNotReady =
        enabled &&
        selectedSandbox != null &&
        selectedSandbox.status != LinuxSandboxStatus.ready;
    final platformBanner = _platformBanner(l10n);

    Future<void> setEnabled(bool value) async {
      if (!value) {
        await context.read<AssistantProvider>().updateAssistant(
          assistant.copyWith(sandboxEnabled: false, clearSandboxId: true),
        );
        return;
      }
      final firstId = sandboxes.isNotEmpty ? sandboxes.first.id : null;
      final idToUse = selectedExists ? selectedId : firstId;
      // Do not enable with a null sandboxId when the list is empty.
      if (idToUse == null) {
        await context.read<AssistantProvider>().updateAssistant(
          assistant.copyWith(sandboxEnabled: false, clearSandboxId: true),
        );
        return;
      }
      await context.read<AssistantProvider>().updateAssistant(
        assistant.copyWith(sandboxEnabled: true, sandboxId: idToUse),
      );
    }

    Future<void> pickSandbox(String id) async {
      await context.read<AssistantProvider>().updateAssistant(
        assistant.copyWith(sandboxEnabled: true, sandboxId: id),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        if (platformBanner != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
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
                    platformBanner,
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
          const SizedBox(height: 12),
        ],
        _iosSectionCard(
          children: [
            _TactileRow(
              onTap: () => setEnabled(!enabled),
              builder: (pressed) {
                final baseColor = cs.onSurface.withValues(alpha: 0.9);
                return _AnimatedPressColor(
                  pressed: pressed,
                  base: baseColor,
                  builder: (color) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 36,
                            child: Icon(
                              Lucide.Box,
                              size: 20,
                              color: enabled ? cs.primary : color,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.assistantEditLinuxSandboxEnable,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: AppFontWeights.semibold,
                                    color: color,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  l10n.assistantEditLinuxSandboxEnableSubtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurface.withValues(alpha: 0.62),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IosSwitch(value: enabled, onChanged: setEnabled),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
        if (missingSelected) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              l10n.assistantEditLinuxSandboxMissing,
              style: TextStyle(fontSize: 13, color: cs.onErrorContainer),
            ),
          ),
        ],
        if (selectedNotReady) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: cs.tertiaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              l10n.assistantEditLinuxSandboxNotReady,
              style: TextStyle(fontSize: 13, color: cs.onTertiaryContainer),
            ),
          ),
        ],
        if (enabled) ...[
          const SizedBox(height: 12),
          if (sandboxes.isEmpty)
            _iosSectionCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    l10n.assistantEditLinuxSandboxNone,
                    style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: IosTileButton(
                    icon: Lucide.Plus,
                    label: l10n.assistantEditLinuxSandboxManageCta,
                    backgroundColor: cs.primary,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LinuxSandboxListPage(),
                        ),
                      );
                    },
                  ),
                ),
              ],
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                l10n.assistantEditLinuxSandboxPick,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
            _iosSectionCard(
              children: [
                for (var i = 0; i < sandboxes.length; i++) ...[
                  if (i > 0) _iosDivider(context),
                  _SandboxPickRow(
                    name: sandboxes[i].name,
                    selected: selectedId == sandboxes[i].id,
                    onTap: () => pickSandbox(sandboxes[i].id),
                  ),
                ],
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _SandboxPickRow extends StatelessWidget {
  const _SandboxPickRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: onTap,
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(
                      Lucide.Box,
                      size: 20,
                      color: selected ? cs.primary : color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        color: color,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? cs.primary
                            : cs.onSurface.withValues(alpha: 0.28),
                        width: 1.6,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: selected
                        ? Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              shape: BoxShape.circle,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
