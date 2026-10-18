import '../../../core/providers/settings_provider.dart';
import '../../../shared/widgets/markdown_with_highlight.dart';
import '../../../utils/utf16_safe_cut.dart';

/// The one-line label a reply citation shows — in the composer's preview row and
/// above a bubble's content (docs/adr/0011).
///
/// The label is the citation's text in the renderer's **display space**: the
/// same walk and the same records the reply's own bubble renders with, so a
/// chip can never show text the renderer would not show. The model-facing
/// citation stays the raw markdown; nothing here is ever sent.
///
/// Presentation transforms belong here and only here: newlines fold to spaces
/// and the result is clipped, because both surfaces are a single line.
String replyCitationLabel(
  String markdown, {
  required SettingsProvider settings,
  bool streaming = false,
}) {
  final source = markdown.trim();
  if (source.isEmpty) return '';
  final document = MarkdownWithCodeHighlight.markdownDocument(
    source,
    settings: settings,
    streaming: streaming,
  );
  final flat = document.displayText.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= replyCitationLabelBudget) return flat;
  // A plain `substring` can split a surrogate pair and leave a lone surrogate
  // behind; the budget is a code-unit count like every other cut in the repo.
  return '${truncateHeadUtf16Safe(flat, replyCitationLabelBudget)}…';
}

/// How much of the citation a one-line label keeps, in code units. The stored
/// citation is untouched: this bounds what a draft carries, not what the model
/// reads.
const int replyCitationLabelBudget = 120;
