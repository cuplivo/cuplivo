part of 'assistant_settings_edit_page.dart';

class _SkillsTab extends StatefulWidget {
  const _SkillsTab({required this.assistantId});
  final String assistantId;

  @override
  State<_SkillsTab> createState() => _SkillsTabState();
}

class _SkillsTabState extends State<_SkillsTab> {
  List<SkillMetadata> _skills = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final skills = await SkillManager.listSkills();
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.getById(widget.assistantId);
    if (assistant == null) return const SizedBox.shrink();

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_skills.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l10n.skillsEmptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _iosSectionCard(
          children: [
            _SkillsMasterRow(
              enabledCount: _skills
                  .where((s) => assistant.skillIds.contains(s.name))
                  .length,
              total: _skills.length,
              allEnabled:
                  _skills.isNotEmpty &&
                  _skills.every((s) => assistant.skillIds.contains(s.name)),
              onChanged: (value) {
                final ids = value
                    ? _skills.map((s) => s.name).toSet()
                    : <String>{};
                context.read<AssistantProvider>().updateAssistant(
                  assistant.copyWith(skillIds: ids.toList(growable: false)),
                );
              },
            ),
            _iosDivider(context),
            for (final (group, skills) in groupSkillsByCategory(_skills)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                child: Text(
                  group ?? l10n.skillsUncategorizedGroup,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: AppFontWeights.semibold,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              for (int i = 0; i < skills.length; i++) ...[
                if (i > 0) _iosDivider(context),
                _SkillRow(
                  name: skills[i].name,
                  description: skills[i].description,
                  enabled: assistant.skillIds.contains(skills[i].name),
                  onChanged: (value) {
                    final ids = assistant.skillIds.toSet();
                    if (value) {
                      ids.add(skills[i].name);
                    } else {
                      ids.remove(skills[i].name);
                    }
                    context.read<AssistantProvider>().updateAssistant(
                      assistant.copyWith(skillIds: ids.toList(growable: false)),
                    );
                  },
                ),
              ],
            ],
          ],
        ),
      ],
    );
  }
}

class _SkillsMasterRow extends StatelessWidget {
  const _SkillsMasterRow({
    required this.enabledCount,
    required this.total,
    required this.allEnabled,
    required this.onChanged,
  });

  final int enabledCount;
  final int total;
  final bool allEnabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: () => onChanged(!allEnabled),
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(Lucide.Sparkles, size: 20, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.skillsEnableAll,
                          style: TextStyle(fontSize: 15, color: color),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.skillsEnabledCount(enabledCount, total),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IosSwitch(value: allEnabled, onChanged: onChanged),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({
    required this.name,
    required this.description,
    required this.enabled,
    required this.onChanged,
  });

  final String name;
  final String description;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: () => onChanged(!enabled),
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(
                      Lucide.BookOpen,
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
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: color,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                        if (description.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.25,
                              color: cs.onSurface.withValues(alpha: 0.62),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  IosSwitch(value: enabled, onChanged: onChanged),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
