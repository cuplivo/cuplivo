import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/fonts/google_fonts_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/widgets/form_sheet.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../utils/markdown_pdf_emitter.dart';
import '../utils/pdf_export_fonts.dart';
import '../utils/pdf_export_options.dart';
import 'message_export_sheet.dart';
import 'pdf_font_picker.dart';

/// Runs one export and answers with what it produced, or null when the user
/// closed the save dialog.
typedef PdfExportRunner =
    Future<PdfExportResult?> Function(
      BuildContext context, {
      required Conversation conversation,
      required List<ChatMessage> messages,
      required PdfExportOptions options,
      GoogleFontsService? googleFonts,
      PdfFontResolver? resolver,
    });

/// Asks what the PDF should contain and which faces it should be drawn with.
///
/// This is the export's one configuration surface: the switches, the three faces,
/// and — after the user asks for it — the check that resolves them. The choices
/// live in [pdfExportSessionOptions] rather than in this widget, because the
/// dialog is rebuilt for every export and the choices are not.
Future<void> showPdfExportDialog(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  required bool showThinkingAndToolCards,
  required bool expandThinkingContent,
  String? appFontPath,
  String? codeFontPath,
  GoogleFontsService? googleFonts,
  PdfFontResolver? resolver,
  PdfExportRunner? run,
}) async {
  // The switch the user just set in the export menu seeds the export's own: that
  // menu is where they said it, this dialog is where they confirm it.
  pdfExportSessionOptions.showThinkingAndToolCards = showThinkingAndToolCards;
  pdfExportSessionOptions.expandThinkingContent = expandThinkingContent;

  // The catalogue a check or the export may download from. It is created here so
  // that what uses it is also what closes it, and a caller that brought its own
  // keeps it.
  final ownsCatalogue = googleFonts == null;
  final catalogue = googleFonts ?? GoogleFontsService();
  final fonts = resolver ?? PdfFontResolver(googleFonts: catalogue);
  try {
    final form = _PdfExportForm(
      conversation: conversation,
      messages: messages,
      appFontPath: appFontPath,
      codeFontPath: codeFontPath,
      resolver: fonts,
      run: run ?? _runExport,
      googleFonts: catalogue,
    );

    if (ResponsiveHelper.isDesktop(context)) {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          elevation: 12,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: form,
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
          ),
          child: form.withHandle(),
        ),
      ),
    );
  } finally {
    if (ownsCatalogue) catalogue.close();
  }
}

Future<PdfExportResult?> _runExport(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  required PdfExportOptions options,
  GoogleFontsService? googleFonts,
  PdfFontResolver? resolver,
}) => exportChatMessagesPdf(
  context,
  conversation: conversation,
  messages: messages,
  options: options,
  googleFonts: googleFonts,
  resolver: resolver,
);

class _PdfExportForm extends StatefulWidget {
  const _PdfExportForm({
    required this.conversation,
    required this.messages,
    required this.resolver,
    required this.run,
    required this.googleFonts,
    this.appFontPath,
    this.codeFontPath,
    this.handle = false,
  });

  final Conversation conversation;
  final List<ChatMessage> messages;
  final PdfFontResolver resolver;
  final PdfExportRunner run;
  final GoogleFontsService? googleFonts;
  final String? appFontPath;
  final String? codeFontPath;
  final bool handle;

  _PdfExportForm withHandle() => _PdfExportForm(
    conversation: conversation,
    messages: messages,
    resolver: resolver,
    run: run,
    googleFonts: googleFonts,
    appFontPath: appFontPath,
    codeFontPath: codeFontPath,
    handle: true,
  );

  @override
  State<_PdfExportForm> createState() => _PdfExportFormState();
}

class _PdfExportFormState extends State<_PdfExportForm> {
  final PdfExportOptions _options = pdfExportSessionOptions;

  /// What the faces are, as far as this point asked. Null until the first
  /// resolution comes back.
  PdfExportFonts? _fonts;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // Opened with what is already on disk: resolving must not start a download
    // behind a dialog that has not been asked for one yet.
    unawaited(_resolve(allowDownload: false));
  }

  Future<void> _resolve({required bool allowDownload}) async {
    setState(() => _checking = true);
    try {
      final fonts = await widget.resolver.resolve(
        body: _options.body,
        mono: _options.mono,
        emoji: _options.emoji,
        appFontPath: widget.appFontPath,
        codeFontPath: widget.codeFontPath,
        allowDownload: allowDownload,
      );
      if (mounted) setState(() => _fonts = fonts);
    } catch (_) {
      // A resolution that fails leaves the rows saying nothing rather than the
      // whole dialog failing: the export will try again, and the overlay covers
      // the wait then.
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _pick(PdfFontRole role) async {
    final current = switch (role) {
      PdfFontRole.body => _options.body,
      PdfFontRole.mono => _options.mono,
      PdfFontRole.emoji => _options.emoji,
    };
    final choice = await showPdfFontPicker(
      context,
      role: role,
      current: current,
      resolver: widget.resolver,
    );
    if (choice == null || !mounted) return;
    setState(() {
      switch (role) {
        case PdfFontRole.body:
          _options.body = choice;
        case PdfFontRole.mono:
          _options.mono = choice;
        case PdfFontRole.emoji:
          _options.emoji = choice;
      }
    });
    // A chosen face that needs the network is downloaded on the check, not here,
    // so picking one never blocks the dialog.
    unawaited(_resolve(allowDownload: false));
  }

  Future<void> _export() async {
    // The configuration goes first, so the overlay and the save dialog are not
    // stacked behind it.
    final parent = context;
    Navigator.of(context).maybePop();
    final result = await widget.run(
      parent,
      conversation: widget.conversation,
      messages: widget.messages,
      options: _options,
      googleFonts: widget.googleFonts,
      resolver: widget.resolver,
    );
    if (result == null || !parent.mounted) return;
    await showPdfExportResultDialog(parent, result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 420,
        maxWidth: 560,
        maxHeight: 640,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: context.appColors.surfaceCard,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.handle)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.pdfExportDialogTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.pdfExportDialogCancel,
                        icon: const Icon(Lucide.X, size: 18),
                        color: cs.onSurface,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(
                height: 1,
                thickness: 0.5,
                color: cs.outlineVariant.withValues(alpha: 0.12),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  children: [
                    IosSectionHeader(text: l10n.pdfExportDialogSectionContent),
                    SectionCard(
                      dividers: true,
                      children: [
                        IosSwitchRow(
                          label:
                              l10n.messageExportSheetShowThinkingAndToolCards,
                          value: _options.showThinkingAndToolCards,
                          onChanged: (value) => setState(() {
                            _options.showThinkingAndToolCards = value;
                            if (!value) _options.expandThinkingContent = false;
                          }),
                        ),
                        _SwitchRow(
                          label: l10n.messageExportSheetShowThinkingContent,
                          value: _options.expandThinkingContent,
                          enabled: _options.showThinkingAndToolCards,
                          onChanged: (value) => setState(
                            () => _options.expandThinkingContent = value,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    IosSectionHeader(text: l10n.pdfExportDialogSectionFonts),
                    SectionCard(
                      dividers: true,
                      children: [
                        IosNavRow(
                          icon: Lucide.Type,
                          label: l10n.pdfExportFontRoleBody,
                          subtitle: _fontDetail(l10n, PdfFontRole.body),
                          onTap: () => _pick(PdfFontRole.body),
                        ),
                        IosNavRow(
                          icon: Lucide.Code,
                          label: l10n.pdfExportFontRoleMono,
                          subtitle: _fontDetail(l10n, PdfFontRole.mono),
                          onTap: () => _pick(PdfFontRole.mono),
                        ),
                        IosNavRow(
                          icon: Lucide.Smile,
                          label: l10n.pdfExportFontRoleEmoji,
                          subtitle: _fontDetail(l10n, PdfFontRole.emoji),
                          onTap: () => _pick(PdfFontRole.emoji),
                        ),
                        IosNavRow(
                          icon: Lucide.RefreshCw,
                          label: _checking
                              ? l10n.pdfExportFontChecking
                              : l10n.pdfExportFontCheck,
                          trailing: _checking
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                          onTap: _checking
                              ? null
                              : () => _resolve(allowDownload: true),
                        ),
                      ],
                    ),
                    if (_missingCjkFace)
                      IosSectionFooter(text: l10n.pdfExportFontMissing),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: FormSheetActions(
                  cancelLabel: l10n.pdfExportDialogCancel,
                  confirmLabel: l10n.pdfExportDialogExport,
                  onCancel: () => Navigator.of(context).maybePop(),
                  onConfirm: _export,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether the body face is the built-in one, which prints CJK as blanks.
  bool get _missingCjkFace {
    final fonts = _fonts;
    if (fonts == null) return false;
    return fonts.statusOf(PdfFontRole.body).source == PdfFontSource.builtIn;
  }

  /// What a role resolved to, in the row's second line.
  String _fontDetail(AppLocalizations l10n, PdfFontRole role) {
    final fonts = _fonts;
    if (fonts == null) return '';
    final status = fonts.statusOf(role);
    if (status.fallback != null) return l10n.pdfExportFontUnusable;
    final name = status.name;
    return switch (status.source) {
      PdfFontSource.builtIn => l10n.pdfExportFontBuiltIn,
      PdfFontSource.none => l10n.pdfExportFontNone,
      _ when status.pending => l10n.pdfExportFontNeedsDownload,
      _ => switch (role) {
        PdfFontRole.emoji when name != null =>
          status.colour
              ? '$name · ${l10n.pdfExportFontNoteColour}'
              : '$name · ${l10n.pdfExportFontNoteMonochrome}',
        _ => name ?? '',
      },
    };
  }
}

/// A switch row whose switch can be off because the option above it is off.
///
/// [IosSwitchRow] takes a non-null callback, so it cannot express that; this is
/// the same row with the disabled tint the export menu uses.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: enabled
                    ? cs.onSurface.withValues(alpha: 0.9)
                    : cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
          IosSwitch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeColor: cs.primary,
          ),
        ],
      ),
    );
  }
}

/// Says what came out, and what could not be drawn.
///
/// An export that fell back is not a failure, but it is not the same document as
/// one that did not: the numbers a reader can check are the pages, the size, and
/// how many things were set as their source text instead of as a drawing.
Future<void> showPdfExportResultDialog(
  BuildContext context,
  PdfExportResult result,
) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  final degraded = <String>[
    if (result.degradedMath.isNotEmpty)
      l10n.pdfExportResultDegradedMath(result.degradedMath.length),
    if (result.degradedDiagrams.isNotEmpty)
      l10n.pdfExportResultDegradedDiagram(result.degradedDiagrams.length),
    if (result.undrawnImages.isNotEmpty)
      l10n.pdfExportResultDegradedImage(result.undrawnImages.length),
  ];
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: context.appColors.surfaceCard,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Text(
                    l10n.pdfExportResultTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    l10n.pdfExportResultSummary(
                      result.pages,
                      _formatBytes(result.bytes.length),
                    ),
                    style: TextStyle(
                      fontSize: 15,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
                if (degraded.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withValues(
                          alpha: 0.4,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.pdfExportResultDegraded(degraded.length),
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 4),
                          for (final line in degraded)
                            Text(
                              line,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.4,
                                color: cs.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).maybePop(),
                    child: Text(l10n.pdfExportResultDone),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
