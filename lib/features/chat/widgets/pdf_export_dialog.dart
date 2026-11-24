import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/fonts/google_fonts_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/utils/file_name.dart';
import '../../../shared/utils/save_file_picker.dart';
import '../../../shared/widgets/form_sheet.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../utils/markdown_pdf_emitter.dart';
import '../utils/pdf_export_fonts.dart';
import '../utils/pdf_export_options.dart';
import 'export_image_capture.dart';
import 'export_progress_overlay.dart';
import 'pdf_font_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' show PdfColor;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/providers/settings_provider.dart';
import '../../intelligent_ui/host/ui_export_capture.dart';
import 'package:intl/intl.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../subagent/widgets/subagent_result_divider.dart';
import '../utils/export_document.dart';

/// What one export produced: the document, and the file it was written to.
///
/// The file rather than the bytes, because every surface that comes after the
/// layout — the save picker, the share sheet — takes a path: the platform
/// channels ask the system to copy a file, and handing them a buffer means
/// writing one anyway.
class ExportedPdf {
  const ExportedPdf({required this.file, required this.result});

  /// The temporary file the document was written to, named after the
  /// conversation. It is this export's working copy: what the user keeps is
  /// whatever the save picker copies it to.
  final File file;

  final PdfExportResult result;
}

/// Runs one export and answers with what it produced, or null when it produced
/// nothing — an export that failed, or a page that went away while it ran.
typedef PdfExportRunner =
    Future<ExportedPdf?> Function(
      BuildContext context, {
      required Conversation conversation,
      required List<ChatMessage> messages,
      required PdfExportOptions options,
      GoogleFontsService? googleFonts,
      PdfFontResolver? resolver,
    });

/// Writes an exported PDF where the user says, answering the name it was saved
/// under or null when they closed the picker.
typedef PdfDocumentSaver =
    Future<String?> Function({
      required File file,
      String? fileName,
      String? dialogTitle,
    });

/// Hands an exported PDF to the platform's share sheet, answering whether it was
/// shared. [origin] is the anchor iPad needs to place the popover.
typedef PdfDocumentSharer = Future<bool> Function(File file, {Rect? origin});

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
  String? appFontFamily,
  String? codeFontFamily,
  GoogleFontsService? googleFonts,
  PdfFontResolver? resolver,
  PdfExportRunner? run,
  // The catalogue's own lifetime is what the dialog is responsible for, so a test
  // that has to observe the close cannot pass one in: an injected service is the
  // caller's and is deliberately left open.
  @visibleForTesting GoogleFontsService Function()? createCatalogue,
}) async {
  // The switch the user just set in the export menu seeds the export's own: that
  // menu is where they said it, this dialog is where they confirm it.
  pdfExportSessionOptions.showThinkingAndToolCards = showThinkingAndToolCards;
  pdfExportSessionOptions.expandThinkingContent = expandThinkingContent;

  // The catalogue a check or the export may download from. It is created here so
  // that what uses it is also what closes it, and a caller that brought its own
  // keeps it.
  final ownsCatalogue = googleFonts == null;
  final catalogue = _CatalogueLease(
    googleFonts ?? createCatalogue?.call() ?? GoogleFontsService(),
    owned: ownsCatalogue,
  );
  final fonts = resolver ?? PdfFontResolver(googleFonts: catalogue.service);
  try {
    final form = _PdfExportForm(
      // The surface the export belongs to. The dialog asks the question; the
      // export — its progress card and its result panel — outlives the dialog,
      // so it is started from the page rather than from a route that is about to
      // be disposed (see [_PdfExportFormState._export]).
      page: context,
      conversation: conversation,
      messages: messages,
      appFontPath: appFontPath,
      codeFontPath: codeFontPath,
      appFontFamily: appFontFamily,
      codeFontFamily: codeFontFamily,
      resolver: fonts,
      run: run ?? _runExport,
      catalogue: catalogue,
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
    // An export that started has claimed it and closes it when it is done; a
    // dialog that is simply being dismissed owns the last reference.
    catalogue.release();
  }
}

/// Lays the selected messages out as a PDF page, and writes it where it can be
/// handed to the platform.
///
/// The fork's own funnel (page palette, per-message document blocks, raster
/// pre-pass) did not survive the re-base; this is the path the emitter alone
/// can serve: the same [PdfExportRequest] the layout takes, built from the
/// messages the caller selected. A PDF is a light page whatever the theme is,
/// so a dark theme contributes a light scheme derived from its seed.
///
/// The whole export runs behind [runWithExportProgressOverlay]: laying a long
/// conversation out is seconds of work — more when the first CJK font has to be
/// downloaded — and the dialog that asked for it has already left the screen, so
/// without the card the app looks idle for exactly as long.
///
/// Saving is *not* part of this: the bytes go to a temporary file and the result
/// surface offers them. A user who changes their mind about where the file goes
/// has not exported anything a second time.
Future<ExportedPdf?> exportChatMessagesPdf(
  BuildContext context, {
  required Conversation conversation,
  required List<ChatMessage> messages,
  UiExportCapture? uiCaptures,
  PdfExportOptions? options,
  GoogleFontsService? googleFonts,
  PdfFontResolver? resolver,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  final choice = options ?? pdfExportSessionOptions;
  final scheme = Theme.of(context).colorScheme.brightness == Brightness.dark
      ? ColorScheme.fromSeed(
          seedColor: Theme.of(context).colorScheme.primary,
          brightness: Brightness.light,
        )
      : Theme.of(context).colorScheme;
  final chat = context.read<ChatService>();
  try {
    return await runWithExportProgressOverlay<ExportedPdf?>(
      context,
      (progress) async {
        final captures =
            uiCaptures ?? await captureUiExportMessages(context, messages);
        final operations = await chat.loadContextOperations(conversation.id);
        final title = conversation.title.trim().isNotEmpty
            ? conversation.title
            : l10n.messageExportSheetDefaultTitle;
        final document = await buildExportDocument(
          title: title,
          messages: captures.messages,
          roleNameOf: (message) => message.role == 'user'
              ? l10n.messageExportSheetUser
              : l10n.messageExportSheetAssistant,
          formatTime: DateFormat(
            l10n.messageExportSheetDateTimeWithSecondsPattern,
          ).format,
          includeThinking:
              choice.showThinkingAndToolCards && choice.expandThinkingContent,
          includeTools: choice.showThinkingAndToolCards,
          uiTextByMessage: captures.projections,
          operations: operations,
          readImageBytes: readExportImageBytes,
          // A delegation's result is a divider in the timeline, so it is one here
          // too: printing it as the user's own message is the one thing an export
          // must not do with a row the user never wrote.
          subagentResultLabelOf: (part) =>
              SubagentResultDivider.labelOf(l10n, part),
        );
        if (!context.mounted) return null;
        final fonts =
            await (resolver ?? PdfFontResolver(googleFonts: googleFonts))
                .resolve(
                  body: choice.body,
                  mono: choice.mono,
                  emoji: choice.emoji,
                  appFontPath: settings.appFontLocalPath,
                  codeFontPath: settings.codeFontLocalPath,
                );
        final result = await compute(
          buildConversationPdf,
          PdfExportRequest(
            title: document.title,
            messages: document.messages,
            thinkingLabel: l10n.messageExportThinkingContentLabel,
            accent: PdfColor.fromInt(scheme.primary.toARGB32()),
            muted: PdfColor.fromInt(scheme.onSurfaceVariant.toARGB32()),
            userLabel: l10n.messageExportSheetUser,
            bodyFont: fonts.body,
            monoFont: fonts.mono,
            emojiFont: fonts.emoji,
            enableMathRendering: settings.enableMathRendering,
            enableDollarLatex: settings.enableDollarLatex,
          ),
        );
        if (!context.mounted) return null;
        return ExportedPdf(
          file: await writeExportedPdfToTemporaryFile(document.title, result),
          result: result,
        );
      },
      initial: ExportImageProgress(
        ExportImageStage.preparing,
        label: l10n.messageExportSheetExporting,
      ),
    );
  } catch (e) {
    if (!context.mounted) return null;
    showAppSnackBar(
      context,
      message: l10n.messageExportSheetExportFailed('$e'),
      type: NotificationType.error,
    );
    return null;
  }
}

/// Writes [result]'s bytes beside the app's other exports, named after
/// [title].
///
/// The name matters more than it looks: iOS's export picker shows the file's
/// name and cannot change it, so a timestamped file is a timestamped file all
/// the way into the user's Files app. A title that is nothing but separators
/// falls back to the timestamp the app's other exports use.
Future<File> writeExportedPdfToTemporaryFile(
  String title,
  PdfExportResult result,
) async {
  final directory = await getTemporaryDirectory();
  final name = safeFileName(
    title,
    fallback: 'chat-export-${DateTime.now().millisecondsSinceEpoch}',
  );
  final file = File(p.join(directory.path, '$name.pdf'));
  await file.writeAsBytes(result.bytes, flush: true);
  return file;
}

Future<ExportedPdf?> _runExport(
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

/// The catalogue a dialog created, and whose job it is to close it.
///
/// The service has to outlive the dialog that opened it: the export runs from the
/// page *after* this route has left the screen, so closing the catalogue when the
/// route pops closes it before the first download. Instead the dialog releases it
/// on the way out — unless an export has claimed it first, and then the export
/// closes it when it is really finished with it.
class _CatalogueLease {
  _CatalogueLease(this.service, {required this.owned});

  final GoogleFontsService service;

  /// Whether this dialog created the service. A catalogue a caller brought is
  /// the caller's to keep open and to close.
  final bool owned;

  bool _claimed = false;

  /// An export is starting, and will close the catalogue itself.
  void claim() => _claimed = true;

  /// Closes it unless an export has taken it over.
  void release() {
    if (owned && !_claimed) service.close();
  }

  /// Closes it, once. Safe after [release] has already decided not to.
  void close() {
    if (owned) service.close();
  }
}

class _PdfExportForm extends StatefulWidget {
  const _PdfExportForm({
    required this.page,
    required this.conversation,
    required this.messages,
    required this.resolver,
    required this.run,
    required this.catalogue,
    this.appFontPath,
    this.codeFontPath,
    this.appFontFamily,
    this.codeFontFamily,
    this.handle = false,
  });

  /// The page this export belongs to, and the context its own surfaces — the
  /// progress overlay and the result dialog — are raised from.
  final BuildContext page;

  final Conversation conversation;
  final List<ChatMessage> messages;
  final PdfFontResolver resolver;
  final PdfExportRunner run;

  /// The catalogue the export downloads from, and the rule for closing it.
  final _CatalogueLease catalogue;

  final String? appFontPath;
  final String? codeFontPath;

  /// What the app draws with, by the name its own font picker gave. Used once,
  /// the first time a dialog is opened, to seed the faces — see
  /// [PdfExportOptions.seededFromSettings].
  final String? appFontFamily;
  final String? codeFontFamily;

  final bool handle;

  _PdfExportForm withHandle() => _PdfExportForm(
    page: page,
    conversation: conversation,
    messages: messages,
    resolver: resolver,
    run: run,
    catalogue: catalogue,
    appFontPath: appFontPath,
    codeFontPath: codeFontPath,
    appFontFamily: appFontFamily,
    codeFontFamily: codeFontFamily,
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
    unawaited(_seedFromSettings());
  }

  /// Offers the app's own faces the first time a dialog is opened in a session.
  ///
  /// The page is meant to look like the app's screen, so the export starts with
  /// the faces that screen was drawn with rather than with whatever the resolver
  /// would reach for on its own. A user who picks another face keeps it: this
  /// fills the roles that are still [PdfFontAuto], and only once.
  Future<void> _seedFromSettings() async {
    final options = _options;
    if (options.seededFromSettings) return;
    final body = await widget.resolver.preferred(
      PdfFontRole.body,
      family: widget.appFontFamily,
    );
    final mono = await widget.resolver.preferred(
      PdfFontRole.mono,
      family: widget.codeFontFamily,
    );
    options.seededFromSettings = true;
    if (!mounted) return;
    if ((body == null || options.body is! PdfFontAuto) &&
        (mono == null || options.mono is! PdfFontAuto)) {
      return;
    }
    setState(() {
      if (body != null && options.body is PdfFontAuto) options.body = body;
      if (mono != null && options.mono is PdfFontAuto) options.mono = mono;
    });
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
    // The configuration goes first, and it *finishes* going first: the progress
    // card and the result panel are what a reader should be looking at, and a
    // dialog still sliding out behind them reads as one that never closed.
    //
    // Everything the export needs is read before the surface goes, because this
    // state is disposed as soon as its route has finished leaving — and the export
    // is launched from the page, so a conversation that takes seconds to lay out
    // still reports what it produced.
    final page = widget.page;
    final run = widget.run;
    final options = _options;
    final conversation = widget.conversation;
    final messages = widget.messages;
    final catalogue = widget.catalogue;
    final resolver = widget.resolver;
    // Claimed before the pop: the pop is what runs the dialog's own `finally`, and
    // closing the catalogue there is exactly what used to leave the export
    // downloading from a closed service. From here the export is what keeps it
    // alive, and it is closed below however this method leaves.
    catalogue.claim();
    try {
      final route = ModalRoute.of(context);
      // `showDialog` puts this route on the root navigator, and it is this
      // configuration's own: `pop` closes it, `maybePop` would merely ask.
      Navigator.of(context, rootNavigator: true).pop();
      // Not "closing": gone. `TransitionRoute.completed` completes once the exit
      // transition has run and the route's overlay entries are out of the tree,
      // which is the moment the page is the only surface on screen again.
      if (route != null) await route.completed;

      // The page the dialog was asked from is not the route it asked on: closing
      // this one does not close that, and a page that went away while the dialog
      // was up has nothing left to export into.
      if (!page.mounted) return;
      final result = await run(
        page,
        conversation: conversation,
        messages: messages,
        options: options,
        googleFonts: catalogue.service,
        resolver: resolver,
      );
      if (result == null || !page.mounted) return;
      await showPdfExportResult(page, result);
    } finally {
      catalogue.close();
    }
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

/// Offers the document that just came out: what it is, and what to do with it.
///
/// The same decision on both sides of the app — keep the file, or send it on —
/// so it is the same panel: a sheet on a phone, a dialog on a desktop.
///
/// Nothing has been saved yet when this opens. That is the point of separating
/// the two steps: the layout is the expensive part and it is already done, so a
/// user who closes the picker has still not waited for a second export.
///
/// The panel is also the working copy's last owner: the file it offers lives in
/// the temporary directory, and once the panel is gone nothing can reach it
/// again. A save has already been copied to the place the user chose and a
/// dismissed panel leaves nothing that still needs the bytes, so both discard
/// it. A shared file is the one exception — the app it was handed to reads the
/// path after the share sheet returns, which is why the workspace's own temp
/// export is kept for the same reason.
Future<void> showPdfExportResult(
  BuildContext context,
  ExportedPdf export, {
  PdfDocumentSaver save = saveHostFileWithPicker,
  PdfDocumentSharer share = sharePdfDocument,
}) async {
  final shared = ResponsiveHelper.isDesktop(context)
      ? await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (_) => _PdfExportResult(
            export: export,
            desktop: true,
            save: save,
            share: share,
          ),
        )
      : await showFormSheet<bool>(
          context,
          builder: (_) => _PdfExportResult(
            export: export,
            desktop: false,
            save: save,
            share: share,
          ),
        );
  // Not awaited: the panel is closed, and a caller waiting on a filesystem call
  // would hold its own cleanup open for a file that only has to disappear.
  if (shared != true) unawaited(_discardQuietly(export.file));
}

/// Removes an export's working copy.
///
/// A temporary directory is the OS's to reclaim, so a cleanup that fails is not
/// an export that failed: swallowing it keeps a finished document finished.
Future<void> _discardQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

/// Hands [file] to the platform's share sheet.
///
/// [origin] is where the sheet should point on an iPad, which is the one platform
/// that draws it as a popover attached to whatever asked.
Future<bool> sharePdfDocument(File file, {Rect? origin}) async {
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf')],
      fileNameOverrides: [p.basename(file.path)],
      sharePositionOrigin: origin,
    ),
  );
  return result.status == ShareResultStatus.success;
}

/// Where a popover may attach, in global coordinates.
///
/// iPad draws the share sheet as a popover anchored to whatever asked for it, so
/// an origin is required even when there is nothing to measure — the middle of
/// the screen is what the image preview falls back to for the same reason.
Rect _shareOriginOf(BuildContext context) {
  try {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
  } catch (_) {}
  final size = MediaQuery.sizeOf(context);
  return Rect.fromCenter(
    center: Offset(size.width / 2, size.height / 2),
    width: 1,
    height: 1,
  );
}

/// The result panel: one body, two chromes, and one save/share implementation.
class _PdfExportResult extends StatefulWidget {
  const _PdfExportResult({
    required this.export,
    required this.desktop,
    required this.save,
    required this.share,
  });

  final ExportedPdf export;
  final bool desktop;
  final PdfDocumentSaver save;
  final PdfDocumentSharer share;

  @override
  State<_PdfExportResult> createState() => _PdfExportResultState();
}

class _PdfExportResultState extends State<_PdfExportResult> {
  bool _saving = false;

  /// Whether the share sheet is already being presented: a second tap while it
  /// is up would ask the platform for a second one.
  bool _sharing = false;

  /// Asks where the file goes, and closes the panel only once it is written.
  ///
  /// A cancelled picker leaves the panel up: the document is still in hand, and
  /// the next thing the user may want is the share sheet instead.
  Future<void> _save() async {
    if (_saving || _sharing) return;
    setState(() => _saving = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      final saved = await widget.save(
        file: widget.export.file,
        fileName: p.basename(widget.export.file.path),
        dialogTitle: l10n.pdfExportResultSave,
      );
      if (!mounted) return;
      if (saved == null) {
        setState(() => _saving = false);
        return;
      }
      // The desktop picker answers with the destination path; every other export
      // says only the name it was written under.
      // The snackbar is the page's, so it outlives this route — shown first, for
      // the same reason the image preview shows its own before closing.
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportedAs(p.basename(saved)),
        type: NotificationType.success,
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final origin = _shareOriginOf(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      final shared = await widget.share(widget.export.file, origin: origin);
      if (!mounted) return;
      setState(() => _sharing = false);
      if (!shared) return;
      // Answers whether the file was handed over, which is what keeps the panel
      // from discarding a copy someone else is still reading.
      Navigator.of(context).maybePop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sharing = false);
      showAppSnackBar(
        context,
        message: l10n.messageExportSheetExportFailed('$e'),
        type: NotificationType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.desktop ? _buildDialog(context) : _buildSheet(context);

  Widget _buildDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 320,
          maxWidth: 460,
          maxHeight: 560,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: context.appColors.surfaceCard,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.pdfExportResultTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.settingsPageShare,
                        icon: const Icon(Lucide.Share, size: 18),
                        color: cs.onSurface,
                        onPressed: _share,
                      ),
                      IconButton(
                        tooltip: l10n.sideDrawerCancel,
                        icon: const Icon(Lucide.X, size: 18),
                        color: cs.onSurface,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 0.5,
                  color: cs.outlineVariant.withValues(alpha: 0.12),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: _PdfExportResultBody(export: widget.export),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: FormSheetActions(
                    cancelLabel: l10n.pdfExportResultDone,
                    confirmLabel: l10n.pdfExportResultSave,
                    onCancel: () => Navigator.of(context).maybePop(),
                    onConfirm: _save,
                    busy: _saving,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FormSheet(
      title: l10n.pdfExportResultTitle,
      actions: Row(
        children: [
          _SheetIconButton(
            icon: Lucide.Share,
            semanticLabel: l10n.settingsPageShare,
            onTap: _saving ? null : _share,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _SheetPrimaryButton(
              icon: Lucide.Download,
              label: l10n.pdfExportResultSave,
              busy: _saving,
              onTap: _save,
            ),
          ),
        ],
      ),
      children: [_PdfExportResultBody(export: widget.export)],
    );
  }
}

/// What the document is: how many pages, how heavy, and what it could not draw.
///
/// An export that fell back is not a failure, but it is not the same document as
/// one that did not — so the numbers a reader can check stay on the panel, next
/// to the file they describe.
class _PdfExportResultBody extends StatelessWidget {
  const _PdfExportResultBody({required this.export});

  final ExportedPdf export;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final result = export.result;
    final degraded = <String>[
      if (result.degradedMath.isNotEmpty)
        l10n.pdfExportResultDegradedMath(result.degradedMath.length),
      if (result.degradedDiagrams.isNotEmpty)
        l10n.pdfExportResultDegradedDiagram(result.degradedDiagrams.length),
      if (result.undrawnImages.isNotEmpty)
        l10n.pdfExportResultDegradedImage(result.undrawnImages.length),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.pdfExportResultSummary(
            result.pages,
            _formatBytes(result.bytes.length),
          ),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: AppFontWeights.semibold),
        ),
        const SizedBox(height: 4),
        Text(
          p.basename(export.file.path),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
        if (degraded.isNotEmpty) ...[
          const SizedBox(height: 16),
          SectionCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.pdfExportResultDegraded(degraded.length),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                  for (final line in degraded)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              Lucide.CircleAlert,
                              size: 13,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              line,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.35,
                                color: cs.onSurface.withValues(alpha: 0.65),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The square secondary action beside the primary one, the same 48-point shape
/// the image preview's share button has.
class _SheetIconButton extends StatelessWidget {
  const _SheetIconButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 48,
      height: 48,
      child: IosCardPress(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        baseColor: context.appColors.surfaceCard,
        pressedBlendStrength: Theme.of(context).brightness == Brightness.dark
            ? 0.14
            : 0.10,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outline.withValues(alpha: 0.25)),
          ),
          child: Center(
            child: Icon(
              icon,
              size: 20,
              color: cs.onSurface.withValues(alpha: 0.9),
              semanticLabel: semanticLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// The wide primary action: filled, 48 points, its label replaced by a spinner
/// while the save picker is up.
class _SheetPrimaryButton extends StatelessWidget {
  const _SheetPrimaryButton({
    required this.icon,
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: IosCardPress(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        baseColor: cs.primary,
        pressedBlendStrength: Theme.of(context).brightness == Brightness.dark
            ? 0.14
            : 0.12,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: busy
                ? SizedBox(
                    key: const ValueKey('saving'),
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onPrimary,
                    ),
                  )
                : Row(
                    key: const ValueKey('ready'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: cs.onPrimary),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          color: cs.onPrimary,
                          fontWeight: AppFontWeights.semibold,
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

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
