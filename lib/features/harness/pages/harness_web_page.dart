import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../widgets/harness_web_view.dart';

/// The remote DeepSeek Harness, embedded.
///
/// The page is deliberately thin: the instance runs its own WebUI, which owns
/// everything below the bar. Cuplivo adds only the return bar and the platform
/// fallbacks inside [HarnessWebView], so the remote product and this app cannot
/// drift into two half-copies of one screen.
class HarnessWebPage extends StatelessWidget {
  const HarnessWebPage({super.key, required this.assistantId});

  final String assistantId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final assistant = context.watch<AssistantProvider>().getById(assistantId);
    final url = assistant?.harnessUrl?.trim() ?? '';
    if (assistant == null || url.isEmpty) {
      // Deleted underneath the page (or opened with no link): there is nothing
      // to show. Leave on the next frame rather than keep a dead page on top.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    return Scaffold(
      key: const Key('harness-web-page'),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leading: IosIconButton(
          key: const Key('harness-return-button'),
          icon: Lucide.ArrowLeft,
          size: 22,
          minSize: 44,
          tooltip: l10n.settingsPageBackButton,
          semanticLabel: l10n.settingsPageBackButton,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 2,
        title: Text(
          assistant.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 16, fontWeight: AppFontWeights.medium),
        ),
      ),
      body: HarnessWebView(url: url),
    );
  }
}
