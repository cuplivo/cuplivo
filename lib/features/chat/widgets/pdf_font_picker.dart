import 'dart:async';

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../utils/pdf_export_fonts.dart';

/// Asks which face one role should be drawn with.
///
/// The list is the resolver's own vocabulary, so nothing can be picked here that
/// an export would not honour: the machine's embeddable faces, the families the
/// catalogue offers for this role, the built-in font, or the chain itself.
Future<PdfFontChoice?> showPdfFontPicker(
  BuildContext context, {
  required PdfFontRole role,
  required PdfFontChoice current,
  required PdfFontResolver resolver,
}) async {
  final page = _PdfFontPickerPage(
    role: role,
    current: current,
    resolver: resolver,
  );
  if (ResponsiveHelper.isDesktop(context)) {
    return showDialog<PdfFontChoice>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: page,
        ),
      ),
    );
  }
  return Navigator.of(
    context,
  ).push<PdfFontChoice>(MaterialPageRoute<PdfFontChoice>(builder: (_) => page));
}

class _PdfFontPickerPage extends StatefulWidget {
  const _PdfFontPickerPage({
    required this.role,
    required this.current,
    required this.resolver,
  });

  final PdfFontRole role;
  final PdfFontChoice current;
  final PdfFontResolver resolver;

  @override
  State<_PdfFontPickerPage> createState() => _PdfFontPickerPageState();
}

class _PdfFontPickerPageState extends State<_PdfFontPickerPage> {
  List<PdfFontCandidate>? _candidates;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      // Enumerating fonts reads every candidate's header, so it happens here
      // rather than while the dialog that opened this one is being built.
      final candidates = await widget.resolver.candidates(widget.role);
      if (mounted) setState(() => _candidates = candidates);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  String get _title {
    final l10n = AppLocalizations.of(context)!;
    return switch (widget.role) {
      PdfFontRole.body => l10n.pdfExportFontRoleBody,
      PdfFontRole.mono => l10n.pdfExportFontRoleMono,
      PdfFontRole.emoji => l10n.pdfExportFontRoleEmoji,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final candidates = _candidates;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.statsPageClose,
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
          // The failure is checked first: a list that threw never assigns
          // [_candidates], so the "still loading" test would spin for ever and
          // the error state would be unreachable.
          child: _failed
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.pdfExportFontListFailed,
                    style: TextStyle(color: cs.error, fontSize: 13),
                  ),
                )
              : candidates == null
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  children: _grouped(l10n, candidates),
                ),
        ),
      ],
    );
  }

  List<Widget> _grouped(
    AppLocalizations l10n,
    List<PdfFontCandidate> candidates,
  ) {
    final cards = <Widget>[];
    void group(String? header, List<PdfFontCandidate> rows) {
      if (rows.isEmpty) return;
      if (header != null) {
        cards.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
            child: Text(
              header,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        );
      }
      cards.add(_card([for (final row in rows) _row(l10n, row)]));
    }

    group(null, _of<PdfFontAuto>(candidates));
    group(l10n.pdfExportFontGroupSystem, _of<PdfFontSystemFace>(candidates));
    group(l10n.pdfExportFontGroupDownload, _of<PdfFontDownload>(candidates));
    group(l10n.pdfExportFontGroupOther, _of<PdfFontBuiltIn>(candidates));
    return cards;
  }

  List<PdfFontCandidate> _of<T extends PdfFontChoice>(
    List<PdfFontCandidate> candidates,
  ) => [
    for (final candidate in candidates)
      if (candidate.choice is T) candidate,
  ];

  Widget _card(List<Widget> rows) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                indent: 12,
                endIndent: 12,
                color: cs.outlineVariant.withValues(alpha: 0.18),
              ),
            rows[index],
          ],
        ],
      ),
    );
  }

  Widget _row(AppLocalizations l10n, PdfFontCandidate candidate) {
    final cs = Theme.of(context).colorScheme;
    final selected = _sameChoice(candidate.choice, widget.current);
    final note = switch (candidate.note) {
      PdfFontNote.cjk => l10n.pdfExportFontNoteCjk,
      PdfFontNote.colour => l10n.pdfExportFontNoteColour,
      PdfFontNote.monochrome => l10n.pdfExportFontNoteMonochrome,
      null => null,
    };
    final title = switch (candidate.choice) {
      PdfFontAuto() => l10n.pdfExportFontAuto,
      PdfFontBuiltIn() => l10n.pdfExportFontBuiltIn,
      _ => candidate.label ?? '',
    };
    final subtitle = switch (candidate.choice) {
      PdfFontBuiltIn() => l10n.pdfExportFontBuiltInNote,
      PdfFontDownload() => l10n.pdfExportFontDownloadNote,
      _ => note,
    };
    return IosCardPress(
      onTap: () => Navigator.of(context).pop(candidate.choice),
      borderRadius: BorderRadius.zero,
      baseColor: Colors.transparent,
      pressedBlendStrength: 0.08,
      pressedScale: 1.0,
      haptics: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected) Icon(Lucide.Check, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}

/// Whether two choices name the same source.
bool _sameChoice(PdfFontChoice a, PdfFontChoice b) => switch ((a, b)) {
  (PdfFontAuto(), PdfFontAuto()) => true,
  (PdfFontBuiltIn(), PdfFontBuiltIn()) => true,
  (PdfFontSystemFace(path: final left), PdfFontSystemFace(path: final right)) =>
    left == right,
  (PdfFontDownload(family: final left), PdfFontDownload(family: final right)) =>
    left == right,
  _ => false,
};
