import 'pdf_export_fonts.dart';

/// What one PDF export is asked to do.
///
/// These are choices about an export rather than preferences about the app: a
/// conversation exported twice should not ask for the same three faces again,
/// and nothing here belongs in the settings file. The thinking toggles are seeded
/// by whichever export menu opened the dialog — the switch the user just saw —
/// while the font choices are only ever made here.
class PdfExportOptions {
  PdfExportOptions({
    this.showThinkingAndToolCards = false,
    this.expandThinkingContent = false,
  });

  bool showThinkingAndToolCards;
  bool expandThinkingContent;

  /// Whether the app's own font settings have been offered as this session's
  /// defaults yet.
  ///
  /// The faces below are seeded from those settings the first time the dialog is
  /// opened, and a user who chose something else keeps it: the export is asked for
  /// once and answers with what it read on screen, and asking again must not undo
  /// the answer.
  bool seededFromSettings = false;

  PdfFontChoice body = const PdfFontAuto();
  PdfFontChoice mono = const PdfFontAuto();
  PdfFontChoice emoji = const PdfFontAuto();
}

/// The session's options.
///
/// One object rather than state on the dialog because the dialog is rebuilt per
/// export and the choices are not: that is the whole point of remembering them.
PdfExportOptions pdfExportSessionOptions = PdfExportOptions();
