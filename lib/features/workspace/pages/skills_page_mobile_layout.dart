import 'package:Cuplivo/core/services/haptics.dart';
import 'package:Cuplivo/features/workspace/widgets/skills/skill_import.dart';
import 'package:Cuplivo/features/workspace/widgets/skills/skill_labels.dart';
import 'package:Cuplivo/features/workspace/widgets/skills/skills_pane.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:flutter/material.dart';

class SkillsPageMobileLayout extends StatelessWidget {
  const SkillsPageMobileLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () {
              Haptics.light();
              Navigator.of(context).maybePop();
            },
          ),
        ),
        title: Text(l10n.skillsTitle),
        actions: const [
          SkillsImportPlusButton(key: SkillsKeys.import),
          SizedBox(width: 12),
        ],
      ),
      body: const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SkillsPane(showHeader: false),
      ),
    );
  }
}
