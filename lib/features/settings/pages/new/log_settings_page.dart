import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../l10n/app_localizations.dart';
import '../../widgets/ios_settings_widgets.dart';

class LogSettingsPage extends StatelessWidget {
  const LogSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final requestLog = context.select<SettingsProvider, bool>(
      (s) => s.requestLogEnabled,
    );
    final mcpLog = context.select<SettingsProvider, bool>(
      (s) => s.mcpLogEnabled,
    );
    final ttsLog = context.select<SettingsProvider, bool>(
      (s) => s.ttsLogEnabled,
    );
    final searchLog = context.select<SettingsProvider, bool>(
      (s) => s.searchLogEnabled,
    );
    final flutterLog = context.select<SettingsProvider, bool>(
      (s) => s.flutterLogEnabled,
    );
    final sp = context.read<SettingsProvider>();

    return IosSettingsPage(
      title: l10n.newSettingsLogSettingsTitle,
      subtitle: l10n.newSettingsLogSettingsSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsSwitchRow(
              label: l10n.requestLogSettingTitle,
              value: requestLog,
              onChanged: (v) => sp.setRequestLogEnabled(v),
            ),
            IosSettingsDivider(context),
            IosSettingsSwitchRow(
              label: l10n.logSettingsMcpEnabled,
              value: mcpLog,
              onChanged: (v) => sp.setMcpLogEnabled(v),
            ),
            IosSettingsDivider(context),
            IosSettingsSwitchRow(
              label: l10n.logSettingsTtsEnabled,
              value: ttsLog,
              onChanged: (v) => sp.setTtsLogEnabled(v),
            ),
            IosSettingsDivider(context),
            IosSettingsSwitchRow(
              label: l10n.logSettingsSearchEnabled,
              value: searchLog,
              onChanged: (v) => sp.setSearchLogEnabled(v),
            ),
            IosSettingsDivider(context),
            IosSettingsSwitchRow(
              label: l10n.flutterLogSettingTitle,
              value: flutterLog,
              onChanged: (v) => sp.setFlutterLogEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
