import 'package:flutter/material.dart';
import '../core/models/chat_message.dart';
import '../core/utils/quick_instruction_presentation.dart';
import '../l10n/app_localizations.dart';
import '../icons/lucide_adapter.dart';
import '../shared/widgets/snackbar.dart';
import 'package:flutter/services.dart';
import '../theme/app_font_weights.dart';
import '../theme/app_semantic_colors.dart';

Future<void> showSelectCopyDesktopDialog(
  BuildContext context, {
  required ChatMessage message,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _SelectCopyDesktopDialog(message: message),
  );
}

class _SelectCopyDesktopDialog extends StatefulWidget {
  const _SelectCopyDesktopDialog({required this.message});
  final ChatMessage message;

  @override
  State<_SelectCopyDesktopDialog> createState() =>
      _SelectCopyDesktopDialogState();
}

class _SelectCopyDesktopDialogState extends State<_SelectCopyDesktopDialog> {
  // The Scrollbar and the SingleChildScrollView must share an explicit
  // controller (`primary: false`) instead of binding to the route-level
  // PrimaryScrollController: boundary auto-scroll drives the position at
  // high frequency, which can transiently leave the route primary with no
  // attached position and trip the Scrollbar's debug assertion.
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _copyAll(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(
      ClipboardData(text: quickInstructionDecoratedContent(widget.message)),
    );
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      message: l10n.selectCopyPageCopiedAll,
      type: NotificationType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 420,
          maxWidth: 720,
          maxHeight: 640,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: cs.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        l10n.selectCopyPageTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => _copyAll(context),
                        icon: Icon(Lucide.Copy, size: 18, color: cs.primary),
                        label: Text(
                          l10n.selectCopyPageCopyAll,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.mcpPageClose,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: Icon(
                          Lucide.X,
                          size: 18,
                          color: cs.onSurface.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.appColors.surfaceFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.18),
                          width: 0.6,
                        ),
                      ),
                      child: SelectionArea(
                        child: Scrollbar(
                          controller: _scrollController,
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            primary: false,
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              quickInstructionDecoratedContent(widget.message),
                              style: TextStyle(fontSize: 15, height: 1.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
