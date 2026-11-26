import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/models/model_spec.dart';
import '../../../../core/services/decision/decision_dialect.dart';
import '../../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/ios_form_text_field.dart';
import '../../../../shared/widgets/ios_tactile.dart';
import '../../../../shared/widgets/segmented_tabs.dart';
import '../../../../shared/widgets/snackbar.dart';
import 'model_spec_form_controller.dart';
import 'spec_field_header.dart';
import 'model_avatar_field.dart';

class BasicSection extends StatelessWidget {
  const BasicSection({
    super.key,
    required this.controller,
    this.desktop = false,
  });

  final bool desktop;

  final ModelSpecFormController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spec = controller.spec;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ModelAvatarField(controller: controller, desktop: desktop),
            SpecFieldHeader(
              label: l10n.modelDetailSheetModelIdLabel,
              source: controller.isApiModelIdOverridden
                  ? SpecSource.override
                  : SpecSource.fallback,
              overridden: controller.isApiModelIdOverridden && controller.isNew,
              onReset: controller.isNew ? controller.resetApiModelId : null,
            ),
            if (controller.isNew)
              IosFormTextField(
                label: '',
                controller: controller.apiModelIdController,
                hintText: l10n.modelDetailSheetModelIdHint,
                inlineLabel: false,
                onChanged: controller.setApiModelId,
              )
            else
              _ReadOnlyIdField(controller: controller),
            const SizedBox(height: 8),
            SpecFieldHeader(
              label: l10n.modelDetailSheetModelNameLabel,
              source: controller.isDisplayNameOverridden
                  ? SpecSource.override
                  : SpecSource.fallback,
              overridden: controller.isDisplayNameOverridden,
              onReset: controller.resetDisplayName,
            ),
            IosFormTextField(
              label: '',
              controller: controller.displayNameController,
              inlineLabel: false,
              onChanged: controller.setDisplayName,
            ),
            const SizedBox(height: 8),
            SpecFieldHeader(
              label: l10n.modelDetailSheetModelTypeLabel,
              source: controller.sourceOf(ModelSpecField.type),
              overridden: controller.isOverridden(ModelSpecField.type),
              onReset: () => controller.reset(ModelSpecField.type),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SegmentedTabs(
                shrinkLabels: true,
                tabs: [
                  SegmentedTab(label: l10n.modelDetailSheetChatType),
                  SegmentedTab(label: l10n.modelDetailSheetEmbeddingType),
                  SegmentedTab(label: l10n.modelSpecFormImageType),
                  SegmentedTab(label: l10n.modelDetailSheetDecisionType),
                ],
                index: spec.type == ModelType.embedding
                    ? 1
                    : spec.type == ModelType.image
                    ? 2
                    : spec.type == ModelType.decision
                    ? 3
                    : 0,
                onChanged: (index) {
                  controller.setType(switch (index) {
                    1 => ModelType.embedding,
                    2 => ModelType.image,
                    3 => ModelType.decision,
                    _ => ModelType.chat,
                  });
                },
              ),
            ),
            // A decision model speaks one of two incompatible protocols, and
            // the endpoint's host name cannot tell which: the user says it.
            if (spec.type == ModelType.decision) ...[
              SpecFieldHeader(
                label: l10n.modelDetailSheetDecisionDialectLabel,
                overridden: false,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: SegmentedTabs(
                  tabs: const [
                    SegmentedTab(label: 'System One'),
                    SegmentedTab(label: 'OpenAI'),
                  ],
                  index: controller.decisionDialect == DecisionDialect.openAi
                      ? 1
                      : 0,
                  onChanged: (index) => controller.setDecisionDialect(
                    index == 1
                        ? DecisionDialect.openAi
                        : DecisionDialect.systemOne,
                  ),
                ),
              ),
              SpecFieldHeader(
                label: l10n.modelDetailSheetDecisionUrlLabel,
                overridden: false,
                trailing: IconButton(
                  key: const ValueKey('decision-url-help'),
                  icon: Icon(
                    Lucide.info,
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  tooltip: l10n.modelDetailSheetDecisionUrlLabel,
                  onPressed: () => _showDecisionUrlHelp(context, controller),
                ),
              ),
              IosFormTextField(
                label: '',
                controller: controller.decisionUrlController,
                hintText: l10n.modelDetailSheetDecisionUrlHint,
                inlineLabel: false,
                keyboardType: TextInputType.url,
                onChanged: controller.setDecisionUrl,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The ⓘ behind 决策地址: why the field exists, and the three paths people
/// actually need. A row writes a **path**, not a whole URL, so the same button
/// keeps working when the same gateway is reached under another host.
Future<void> _showDecisionUrlHelp(
  BuildContext context,
  ModelSpecFormController controller,
) {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  final host = controller.providerHost;

  final rows = <({String label, String path, bool current})>[
    (
      label: 'OpenRouter',
      path: '/api/alpha/decisions',
      current: host.endsWith('openrouter.ai'),
    ),
    (
      label: 'TypeSafe',
      path: '/v1/systemone',
      current: host.endsWith('typesafe.ai'),
    ),
    (
      label: l10n.modelDetailSheetDecisionUrlBailian,
      path: '/compatible-mode/v1/systemone',
      current: host.endsWith('aliyuncs.com'),
    ),
  ]..sort((a, b) => (b.current ? 1 : 0).compareTo(a.current ? 1 : 0));

  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  l10n.modelDetailSheetDecisionUrlLabel,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  l10n.modelDetailSheetDecisionUrlHelp,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            row.label,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (row.current) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                l10n.modelDetailSheetDecisionUrlCurrent,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          ],
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              controller.decisionUrlController.text = row.path;
                              controller.setDecisionUrl(row.path);
                              Navigator.of(ctx).pop();
                            },
                            child: Text(l10n.modelDetailSheetDecisionUrlFill),
                          ),
                        ],
                      ),
                      Text(
                        row.path,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReadOnlyIdField extends StatelessWidget {
  const _ReadOnlyIdField({required this.controller});

  final ModelSpecFormController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: IosFormTextField(
              label: '',
              controller: controller.apiModelIdController,
              enabled: false,
              inlineLabel: false,
              outerPadding: EdgeInsets.zero,
            ),
          ),
          IosIconButton(
            icon: Lucide.Copy,
            size: 18,
            minSize: 40,
            tooltip: l10n.shareProviderSheetCopyButton,
            semanticLabel: l10n.shareProviderSheetCopyButton,
            color: cs.onSurface.withValues(alpha: 0.8),
            onTap: () {
              final text = controller.apiModelIdController.text.trim();
              if (text.isEmpty) return;
              Clipboard.setData(ClipboardData(text: text));
              showAppSnackBar(
                context,
                message: l10n.shareProviderSheetCopiedMessage,
                type: NotificationType.success,
              );
            },
          ),
        ],
      ),
    );
  }
}
